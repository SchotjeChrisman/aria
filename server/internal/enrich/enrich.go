// Enricher: the background metadata-infusion orchestrator ported from
// enrich.js. One incremental pass per Run: per-album MusicBrainz credits +
// missing art, artist bios/photos/similar, discography refreshes, classical
// composers, the credited-people long tail, and lazy portrait upgrades.
// Everything persists in the enrich_cache table via *repo.Enrich.
package enrich

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"maps"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"aria/internal/repo"
)

// ---- enrich_cache kinds and document shapes --------------------------------

const (
	KindAlbum     = "album"     // albumId -> {v,done,mbid,art?}   (legacy db.albums)
	KindTrack     = "track"     // trackId -> credit overlay       (legacy db.tracks)
	KindArtist    = "artist"    // name -> ArtistEntry             (legacy db.artists)
	KindComposer  = "composer"  // name -> ComposerEntry           (legacy db.composers)
	KindLyrics    = "lyrics"    // trackId -> Lyrics or null       (legacy db.lyricsV2)
	KindAlbumInfo = "albumInfo" // albumId -> info map or null     (legacy db.albumInfo)
)

// v2 added per-performer credits; bump to re-pull albums.
const albumV = 2

type albumCache struct {
	V    int     `json:"v"`
	Done bool    `json:"done"`
	Mbid *string `json:"mbid"`
	Art  bool    `json:"art,omitempty"`
}

type Performer struct {
	Name string `json:"name"`
	Role string `json:"role"`
}

// TrackCredits is the per-track MB credit overlay; only set fields override tags.
type TrackCredits struct {
	Composer   string      `json:"composer,omitempty"`
	Conductor  string      `json:"conductor,omitempty"`
	Orchestra  string      `json:"orchestra,omitempty"`
	Performers []Performer `json:"performers,omitempty"`
}

func mergeCredits(old, n TrackCredits) TrackCredits {
	if n.Composer != "" {
		old.Composer = n.Composer
	}
	if n.Conductor != "" {
		old.Conductor = n.Conductor
	}
	if n.Orchestra != "" {
		old.Orchestra = n.Orchestra
	}
	if n.Performers != nil {
		old.Performers = n.Performers
	}
	return old
}

func (c TrackCredits) empty() bool {
	return c.Composer == "" && c.Conductor == "" && c.Orchestra == "" && c.Performers == nil
}

// ArtistEntry mirrors legacy db.artists values. Pointer slices model the
// absent-vs-set distinctions the legacy code relies on: Similar nil = never
// enriched, Members nil = cached before band rels existed (backfilled lazily).
type ArtistEntry struct {
	Type          string             `json:"type,omitempty"`
	Area          string             `json:"area,omitempty"`
	Born          string             `json:"born,omitempty"`
	Died          string             `json:"died,omitempty"`
	Members       *[]string          `json:"members,omitempty"`
	Bands         *[]string          `json:"bands,omitempty"`
	Bio           string             `json:"bio,omitempty"`
	URL           string             `json:"url,omitempty"`
	Image         string             `json:"image,omitempty"`
	ImgSrc        string             `json:"imgSrc,omitempty"` // wikipedia|deezer
	Similar       *[]SimilarArtist   `json:"similar,omitempty"`
	Discography   *[]DiscographyItem `json:"discography,omitempty"`
	DiscographyAt string             `json:"discographyAt,omitempty"`
	ImgCheckedAt  string             `json:"imgCheckedAt,omitempty"` // face upgrade tried once ever
}

type ComposerEntry struct {
	FullName string  `json:"fullName,omitempty"`
	Epoch    string  `json:"epoch,omitempty"`
	Portrait string  `json:"portrait,omitempty"`
	Born     *string `json:"born,omitempty"` // year only
	Died     *string `json:"died,omitempty"`
	Bio      string  `json:"bio,omitempty"`
	URL      string  `json:"url,omitempty"`
}

type ArtistDiscography struct {
	Artist string            `json:"artist"`
	Items  []DiscographyItem `json:"items"`
}

type ArtistCandidate struct {
	Mbid           string  `json:"mbid"`
	Name           string  `json:"name"`
	Type           *string `json:"type"`
	Area           *string `json:"area"`
	Disambiguation *string `json:"disambiguation"`
	Score          *int    `json:"score"`
}

type AlbumCandidate struct {
	Mbid    string  `json:"mbid"`
	Title   string  `json:"title"`
	Artist  *string `json:"artist"`
	Date    *string `json:"date"`
	Country *string `json:"country"`
	Tracks  *int    `json:"tracks"`
	Score   *int    `json:"score"`
}

// ---- Enricher ---------------------------------------------------------------

type Enricher struct {
	tracks  *repo.Tracks
	cache   *repo.Enrich
	dataDir string
	log     func(string)

	pc   *politeClient // binary fetches (Cover Art Archive, Deezer cover files)
	mb   *MB
	dz   *Deezer
	wiki *Wikipedia
	oo   *OpenOpus
	lrc  *LRCLib

	mu      sync.Mutex
	running bool
	phase   string
	done    int
	total   int
	warming map[string]bool
}

func New(tracks *repo.Tracks, cache *repo.Enrich, dataDir string) *Enricher {
	os.MkdirAll(filepath.Join(dataDir, "art"), 0o755)
	return &Enricher{
		tracks: tracks, cache: cache, dataDir: dataDir,
		pc: newPoliteClient(), mb: NewMB(),
		dz: NewDeezer(), wiki: NewWikipedia(), oo: NewOpenOpus(), lrc: NewLRCLib(),
		log:     func(m string) { log.Printf("enrich: %s", m) },
		phase:   "idle",
		warming: map[string]bool{},
	}
}

func (e *Enricher) Status() any {
	e.mu.Lock()
	defer e.mu.Unlock()
	return map[string]any{"phase": e.phase, "done": e.done, "total": e.total, "running": e.running}
}

func (e *Enricher) setPhase(phase string, total int) {
	e.mu.Lock()
	e.phase, e.total, e.done = phase, total, 0
	e.mu.Unlock()
}

func (e *Enricher) step() {
	e.mu.Lock()
	e.done++
	e.mu.Unlock()
}

var (
	classicalRe = regexp.MustCompile(`(?i)classical|opera|baroque|romantic`)
	albumRe     = regexp.MustCompile(`(?i)album`)
	qidRe       = regexp.MustCompile(`Q\d+`)
)

// Run is one incremental enrichment pass (single-flight; a second call while
// running is a no-op). Cancel ctx to stop between items.
func (e *Enricher) Run(ctx context.Context) error {
	e.mu.Lock()
	if e.running {
		e.mu.Unlock()
		return nil
	}
	e.running = true
	e.mu.Unlock()
	defer func() {
		e.mu.Lock()
		e.running, e.phase = false, "idle"
		e.mu.Unlock()
	}()

	tracks, err := e.tracks.ListAll(ctx)
	if err != nil {
		return err
	}

	// phase 1+2: per-album MB lookup -> track credit overlays + missing art
	var albumIDs []string
	byAlbum := map[string][]repo.Track{}
	for _, t := range tracks {
		if _, ok := byAlbum[t.AlbumID]; !ok {
			albumIDs = append(albumIDs, t.AlbumID)
		}
		byAlbum[t.AlbumID] = append(byAlbum[t.AlbumID], t)
	}
	cachedAlbums, err := e.cache.ListKind(ctx, KindAlbum)
	if err != nil {
		return err
	}
	var todoAlbums []string
	for _, id := range albumIDs {
		var a albumCache
		if raw, ok := cachedAlbums[id]; ok && json.Unmarshal(raw, &a) == nil && a.V >= albumV {
			continue
		}
		todoAlbums = append(todoAlbums, id)
	}
	e.setPhase("albums", len(todoAlbums))
	for _, id := range todoAlbums {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err := e.enrichAlbum(ctx, id, byAlbum[id]); err != nil {
			e.log("album " + byAlbum[id][0].Album + ": " + err.Error())
		}
		e.step()
	}

	// phase 3: album-artist bios/photos/similar
	var artistNames []string
	artistMbid := map[string]string{}
	for _, t := range tracks {
		if _, ok := artistMbid[t.AlbumArtist]; !ok {
			artistNames = append(artistNames, t.AlbumArtist)
			artistMbid[t.AlbumArtist] = strOf(t.MBAlbumArtistID)
		}
	}
	var todoArtists []string
	for _, n := range artistNames {
		if needsSimilar(e.artistGet(ctx, n)) {
			todoArtists = append(todoArtists, n)
		}
	}
	e.setPhase("artists", len(todoArtists))
	for _, n := range todoArtists {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		e.enrichArtist(ctx, n, artistMbid[n])
		e.step()
	}

	// keep album-artist discographies < 7 days old (cap 40/run for politeness)
	var todoDisc []string
	for _, n := range artistNames {
		if a := e.artistGet(ctx, n); a != nil && staleDisc(a) {
			todoDisc = append(todoDisc, n)
			if len(todoDisc) == 40 {
				break
			}
		}
	}
	e.setPhase("discographies", len(todoDisc))
	for _, n := range todoDisc {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if a := e.artistGet(ctx, n); a != nil {
			e.refreshDiscography(ctx, n, a)
		}
		e.step()
	}

	// phase 4: classical composers (from credit-merged tracks)
	creds, err := e.Credits(ctx)
	if err != nil {
		return err
	}
	merged := func(tag *string, cred string) string {
		if cred != "" {
			return cred
		}
		return strOf(tag)
	}
	var compNames []string
	seenComp := map[string]bool{}
	for _, t := range tracks {
		comp := merged(t.Composer, creds[t.ID].Composer)
		if comp == "" || seenComp[comp] {
			continue
		}
		if t.Work != nil || classicalRe.MatchString(strOf(t.Genre)) {
			seenComp[comp] = true
			compNames = append(compNames, comp)
		}
	}
	var todoComp []string
	for _, n := range compNames {
		if _, ok, _ := e.cache.Get(ctx, KindComposer, n); !ok {
			todoComp = append(todoComp, n)
		}
	}
	e.setPhase("composers", len(todoComp))
	for _, n := range todoComp {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		e.enrichComposer(ctx, n)
		e.step()
	}

	// phase 5: every credited human gets a face & bio (long tail, runs last)
	var everyone []string
	seen := map[string]bool{}
	add := func(n string) {
		if n != "" && !seen[n] {
			seen[n] = true
			everyone = append(everyone, n)
		}
	}
	for _, t := range tracks {
		c := creds[t.ID]
		add(t.Artist)
		add(merged(t.Composer, c.Composer))
		add(merged(t.Conductor, c.Conductor))
		add(c.Orchestra)
		for _, p := range c.Performers {
			add(p.Name)
		}
	}
	var todoPeople []string
	for _, n := range everyone {
		if needsSimilar(e.artistGet(ctx, n)) {
			todoPeople = append(todoPeople, n)
		}
	}
	e.setPhase("people", len(todoPeople))
	for _, n := range todoPeople {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		e.enrichArtist(ctx, n, "")
		e.step()
	}

	// final phase: lazily upgrade non-wiki portraits to Wikipedia's; each
	// entry tried once ever, cap 25/run
	arts, err := e.cache.ListKind(ctx, KindArtist)
	if err != nil {
		return err
	}
	var todoFaces []string
	for _, n := range slices.Sorted(maps.Keys(arts)) {
		var a ArtistEntry
		if json.Unmarshal(arts[n], &a) != nil {
			continue
		}
		if a.Image != "" && a.ImgSrc != "wikipedia" && a.ImgCheckedAt == "" {
			todoFaces = append(todoFaces, n)
			if len(todoFaces) == 25 {
				break
			}
		}
	}
	e.setPhase("faces", len(todoFaces))
	for _, n := range todoFaces {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if a := e.artistGet(ctx, n); a != nil {
			if img := e.wikiImage(ctx, n); img != "" {
				a.Image, a.ImgSrc = img, "wikipedia"
			}
			a.ImgCheckedAt = nowISO() // success, miss or error: never retried
			e.artistPut(ctx, n, a)
		}
		e.step()
	}

	e.log("enrichment pass complete")
	return nil
}

// ---- albums ----------------------------------------------------------------

func (e *Enricher) enrichAlbum(ctx context.Context, albumID string, ts []repo.Track) error {
	var a albumCache
	found := e.cacheGet(ctx, KindAlbum, albumID, &a)
	if found && a.V >= albumV {
		return nil
	}
	mbid := ""
	if found && a.Mbid != nil {
		mbid = *a.Mbid
	}
	if mbid == "" {
		for _, t := range ts {
			if t.MBAlbumID != nil && *t.MBAlbumID != "" {
				mbid = *t.MBAlbumID
				break
			}
		}
	}
	if mbid == "" && !found { // don't re-search albums that already came up empty
		if rels := e.mb.searchReleases(ctx, ts[0].Album, ts[0].AlbumArtist, 1); len(rels) > 0 {
			mbid = rels[0].ID
		}
	}
	a.V, a.Done = albumV, true
	a.Mbid = nullable(mbid)
	if err := e.put(ctx, KindAlbum, albumID, a); err != nil {
		return err
	}
	if mbid == "" {
		return nil
	}

	if rel := e.mb.release(ctx, mbid, "recordings+recording-level-rels+work-rels+work-level-rels+artist-rels"); rel != nil {
		byRec := creditsByRecording(rel)
		for _, t := range ts {
			if t.MBRecordingID == nil {
				continue
			}
			c, ok := byRec[*t.MBRecordingID]
			if !ok {
				continue
			}
			var old TrackCredits
			e.cacheGet(ctx, KindTrack, t.ID, &old)
			if err := e.put(ctx, KindTrack, t.ID, mergeCredits(old, c)); err != nil {
				return err
			}
		}
	}

	artPath := filepath.Join(e.dataDir, "art", albumID+".jpg")
	if _, err := os.Stat(artPath); !ts[0].HasArt && err != nil {
		img := e.getBinary(ctx, "https://coverartarchive.org/release/"+mbid+"/front-500")
		if img == nil {
			if u, err := e.dz.AlbumCoverURL(ctx, ts[0].AlbumArtist, ts[0].Album); err == nil && u != "" {
				img = e.getBinary(ctx, u)
			}
		}
		if img != nil {
			if err := os.WriteFile(artPath, img, 0o644); err != nil {
				e.log("art write " + albumID + ": " + err.Error())
			} else {
				a.Art = true
				return e.put(ctx, KindAlbum, albumID, a)
			}
		}
	}
	return nil
}

// getBinary is the polite raw-bytes GET (art files); nil on any failure.
func (e *Enricher) getBinary(ctx context.Context, rawURL string) []byte {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil
	}
	for tries := 3; ; tries-- {
		if sleepCtx(ctx, e.pc.reserve(u.Host)) != nil {
			return nil
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
		if err != nil {
			return nil
		}
		req.Header.Set("User-Agent", userAgent)
		res, err := e.pc.hc.Do(req)
		if err != nil {
			return nil
		}
		if (res.StatusCode == http.StatusServiceUnavailable || res.StatusCode == http.StatusTooManyRequests) && tries > 1 {
			res.Body.Close()
			if sleepCtx(ctx, e.pc.retryWait) != nil {
				return nil
			}
			continue
		}
		defer res.Body.Close()
		if res.StatusCode < 200 || res.StatusCode > 299 {
			return nil
		}
		b, err := io.ReadAll(io.LimitReader(res.Body, 16<<20))
		if err != nil {
			return nil
		}
		return b
	}
}

// ---- artists ---------------------------------------------------------------

func needsSimilar(a *ArtistEntry) bool { return a == nil || a.Similar == nil }

// discographyAt unset == old-shape or never fetched == stale
func staleDisc(a *ArtistEntry) bool {
	t, err := time.Parse(time.RFC3339, a.DiscographyAt)
	return a.DiscographyAt == "" || err != nil || time.Since(t) > 7*24*time.Hour
}

// similarOrEmpty reproduces legacy deezerSimilar: any failure is [] and gets
// cached forever.
func (e *Enricher) similarOrEmpty(ctx context.Context, name string) []SimilarArtist {
	sim, err := e.dz.Similar(ctx, name)
	if err != nil || sim == nil {
		return []SimilarArtist{}
	}
	return sim
}

func (e *Enricher) enrichArtist(ctx context.Context, name, mbid string) {
	existing := e.artistGet(ctx, name)
	if existing != nil && existing.Similar != nil {
		return
	}
	if existing != nil { // existing entry: only (re)fetch similar
		sim := e.similarOrEmpty(ctx, name)
		existing.Similar = &sim
		e.artistPut(ctx, name, existing)
		return
	}
	ent := &ArtistEntry{Members: &[]string{}, Bands: &[]string{}}
	if mbid == "" {
		mbid = e.mb.searchArtistMBID(ctx, name)
	}
	if mbid != "" {
		if ar := e.mb.artist(ctx, mbid, "url-rels+artist-rels"); ar != nil {
			ent.Type = ar.Type
			if ar.Area != nil {
				ent.Area = ar.Area.Name
			}
			if ar.LifeSpan != nil {
				ent.Born, ent.Died = ar.LifeSpan.Begin, ar.LifeSpan.End
			}
			readBandRels(ar.Relations, ent.Members, ent.Bands)
			if title := e.wikiTitle(ctx, ar.Relations); title != "" {
				if s := e.summary(ctx, title); s != nil {
					if s.Extract != "" {
						ent.Bio, ent.URL = s.Extract, s.PageURL
					}
					// wiki portrait preferred (original size beats Deezer's often-outdated shots)
					if img := s.Image(); img != "" {
						ent.Image, ent.ImgSrc = img, "wikipedia"
					}
				}
			}
		}
	}
	if ent.Image == "" {
		if a, err := e.dz.SearchArtist(ctx, name); err == nil && a != nil &&
			strings.EqualFold(a.Name, name) && a.PictureXL != "" {
			ent.Image, ent.ImgSrc = a.PictureXL, "deezer"
		}
	}
	sim := e.similarOrEmpty(ctx, name)
	ent.Similar = &sim
	if disc, err := e.dz.Discography(ctx, name); err == nil { // err = fetch failed; leave stale so it retries
		ent.Discography = &disc
		ent.DiscographyAt = nowISO()
	}
	e.artistPut(ctx, name, ent)
}

func (e *Enricher) refreshDiscography(ctx context.Context, name string, ent *ArtistEntry) {
	disc, err := e.dz.Discography(ctx, name)
	if err != nil {
		return // transient failure: keep old cache + timestamp, retry next run
	}
	ent.Discography = &disc
	ent.DiscographyAt = nowISO()
	e.artistPut(ctx, name, ent)
}

// MB "member of band" rels: backward = this artist is a group, other end is a
// member; forward = this artist is a person, other end is a band they belong(ed) to
func readBandRels(rels []mbRelation, members, bands *[]string) {
	for _, r := range rels {
		if r.Type != "member of band" || r.Artist == nil {
			continue
		}
		list := bands
		if r.Direction == "backward" {
			list = members
		}
		if !slices.Contains(*list, r.Artist.Name) {
			*list = append(*list, r.Artist.Name)
		}
	}
}

// lazy backfill for artists cached before band rels existed (no mbid stored — re-search)
func (e *Enricher) backfillBandRels(ctx context.Context, name string, ent *ArtistEntry) {
	ent.Members, ent.Bands = &[]string{}, &[]string{} // set first: even an MB miss is "tried, none"
	if mbid := e.mb.searchArtistMBID(ctx, name); mbid != "" {
		if ar := e.mb.artist(ctx, mbid, "artist-rels"); ar != nil {
			readBandRels(ar.Relations, ent.Members, ent.Bands)
		}
	}
	e.artistPut(ctx, name, ent)
}

// summary is the soft-failure wrapper: network errors read as "no page".
func (e *Enricher) summary(ctx context.Context, title string) *Summary {
	s, err := e.wiki.Summary(ctx, title)
	if err != nil {
		return nil
	}
	return s
}

// MB url-rels -> enwiki page title (direct wikipedia rel, else via Wikidata
// sitelinks). The title may still be percent-encoded; Wikipedia.Summary decodes.
func (e *Enricher) wikiTitle(ctx context.Context, rels []mbRelation) string {
	for _, r := range rels {
		if r.Type == "wikipedia" && r.URL != nil {
			if _, after, ok := strings.Cut(r.URL.Resource, "/wiki/"); ok {
				return after
			}
		}
	}
	for _, r := range rels {
		if r.Type == "wikidata" && r.URL != nil {
			if qid := qidRe.FindString(r.URL.Resource); qid != "" {
				title, _ := e.wiki.SitelinkTitle(ctx, qid)
				return title
			}
		}
	}
	return ""
}

// Wikipedia portrait only (used by the lazy face-upgrade phase for old Deezer images)
func (e *Enricher) wikiImage(ctx context.Context, name string) string {
	mbid := e.mb.searchArtistMBID(ctx, name)
	if mbid == "" {
		return ""
	}
	ar := e.mb.artist(ctx, mbid, "url-rels")
	if ar == nil {
		return ""
	}
	title := e.wikiTitle(ctx, ar.Relations)
	if title == "" {
		return ""
	}
	s := e.summary(ctx, title)
	if s == nil {
		return ""
	}
	return s.Image()
}

// ---- composers ---------------------------------------------------------------

func (e *Enricher) enrichComposer(ctx context.Context, name string) {
	var entry ComposerEntry
	if oo, err := e.oo.SearchComposer(ctx, name); err == nil && oo != nil {
		entry.FullName = oo.FullName
		entry.Epoch = oo.Epoch
		entry.Portrait = oo.Portrait
		entry.Born = oo.Born
		entry.Died = oo.Died
	}
	title := firstOf(entry.FullName, name)
	if s := e.summary(ctx, title); s != nil && s.Extract != "" && s.Type != "disambiguation" {
		entry.Bio = s.Extract
		entry.Portrait = firstOf(entry.Portrait, s.Thumbnail)
		entry.URL = s.PageURL
	}
	e.put(ctx, KindComposer, name, entry)
}

// ---- on-demand API surface ---------------------------------------------------

// Person enriches an unknown credited name on demand (~3-6s first time), then
// serves from cache with lazy discography/band-rel refreshes. nil = MB never
// heard of it AND we have nothing cached.
func (e *Enricher) Person(ctx context.Context, name string) (json.RawMessage, error) {
	if needsSimilar(e.artistGet(ctx, name)) {
		e.enrichArtist(ctx, name, "")
	}
	ent := e.artistGet(ctx, name)
	if ent == nil {
		return nil, nil
	}
	if staleDisc(ent) { // pre-discography entries, old-shape items, or just >7 days old
		e.refreshDiscography(ctx, name, ent)
	}
	if ent.Members == nil { // cached before band rels existed
		e.backfillBandRels(ctx, name, ent)
	}
	return json.Marshal(ent)
}

// Artist is the sync cache read (never blocks on network); nil when uncached.
func (e *Enricher) Artist(ctx context.Context, name string) (json.RawMessage, error) {
	raw, ok, err := e.cache.Get(ctx, KindArtist, name)
	if err != nil || !ok || string(raw) == "null" {
		return nil, err
	}
	return raw, nil
}

// Composer is the sync cache read; nil when uncached (a cached "{}" is a hit).
func (e *Enricher) Composer(ctx context.Context, name string) (json.RawMessage, error) {
	raw, ok, err := e.cache.Get(ctx, KindComposer, name)
	if err != nil || !ok || string(raw) == "null" {
		return nil, err
	}
	return raw, nil
}

// Lyrics fetches on demand from LRCLIB, cached forever including misses
// (network failures too, matching legacy). Returns the cache-shaped raw JSON
// {"synced":..,"plain":..} or the literal "null" — the signature must match
// api's onDemandEnricher (compile-time asserted in api/enrich.go).
func (e *Enricher) Lyrics(ctx context.Context, t repo.Track) (json.RawMessage, error) {
	if raw, ok, err := e.cache.Get(ctx, KindLyrics, t.ID); err != nil {
		return nil, err
	} else if ok {
		return raw, nil
	}
	dur := 0.0
	if t.Duration != nil {
		dur = *t.Duration
	}
	out, err := e.lrc.Lyrics(ctx, t.Title, t.Artist, dur)
	if err != nil {
		out = nil
	}
	if err := e.put(ctx, KindLyrics, t.ID, out); err != nil {
		return nil, err
	}
	return json.Marshal(out)
}

// Credits returns all cached per-track credit overlays (API merge layer input).
func (e *Enricher) Credits(ctx context.Context) (map[string]TrackCredits, error) {
	raws, err := e.cache.ListKind(ctx, KindTrack)
	if err != nil {
		return nil, err
	}
	out := make(map[string]TrackCredits, len(raws))
	for id, raw := range raws {
		var c TrackCredits
		if json.Unmarshal(raw, &c) == nil && !c.empty() {
			out[id] = c
		}
	}
	return out, nil
}

// CreditsFor is the single-track overlay (scrobble path); zero value when none.
func (e *Enricher) CreditsFor(ctx context.Context, trackID string) (TrackCredits, error) {
	var c TrackCredits
	raw, ok, err := e.cache.Get(ctx, KindTrack, trackID)
	if err == nil && ok {
		json.Unmarshal(raw, &c)
	}
	return c, err
}

// ArtAlbums lists albumIds whose art was fetched by enrichment (hasArt overlay).
func (e *Enricher) ArtAlbums(ctx context.Context) (map[string]bool, error) {
	raws, err := e.cache.ListKind(ctx, KindAlbum)
	if err != nil {
		return nil, err
	}
	out := map[string]bool{}
	for id, raw := range raws {
		var a albumCache
		if json.Unmarshal(raw, &a) == nil && a.Art {
			out[id] = true
		}
	}
	return out, nil
}

// People is the bulk name -> portrait map for avatar rendering (artists beat composers).
func (e *Enricher) People(ctx context.Context) (map[string]string, error) {
	out := map[string]string{}
	comps, err := e.cache.ListKind(ctx, KindComposer)
	if err != nil {
		return nil, err
	}
	for n, raw := range comps {
		var c ComposerEntry
		if json.Unmarshal(raw, &c) == nil && c.Portrait != "" {
			out[n] = c.Portrait
		}
	}
	arts, err := e.cache.ListKind(ctx, KindArtist)
	if err != nil {
		return nil, err
	}
	for n, raw := range arts {
		var a ArtistEntry
		if json.Unmarshal(raw, &a) == nil && a.Image != "" {
			out[n] = a.Image
		}
	}
	return out, nil
}

// Discographies is the sync snapshot of all cached discographies —
// /api/newreleases reads this, no network.
func (e *Enricher) Discographies(ctx context.Context) ([]ArtistDiscography, error) {
	raws, err := e.cache.ListKind(ctx, KindArtist)
	if err != nil {
		return nil, err
	}
	out := []ArtistDiscography{}
	for _, n := range slices.Sorted(maps.Keys(raws)) {
		var a ArtistEntry
		if json.Unmarshal(raws[n], &a) == nil && a.Discography != nil && len(*a.Discography) > 0 {
			out = append(out, ArtistDiscography{Artist: n, Items: *a.Discography})
		}
	}
	return out, nil
}

// Warm is the fire-and-forget warm-up of visible names (viewport-driven
// browsing depth); returns how many were queued.
func (e *Enricher) Warm(names []string) int {
	ctx := context.Background()
	var todo []string
	for _, n := range names {
		if needsSimilar(e.artistGet(ctx, n)) {
			todo = append(todo, n)
		}
	}
	e.mu.Lock()
	kept := todo[:0]
	for _, n := range todo {
		if !e.warming[n] {
			e.warming[n] = true
			kept = append(kept, n)
		}
	}
	e.mu.Unlock()
	if len(kept) > 0 {
		go func() {
			for _, n := range kept {
				e.enrichArtist(ctx, n, "")
				e.mu.Lock()
				delete(e.warming, n)
				e.mu.Unlock()
			}
		}()
	}
	return len(kept)
}

// AlbumInfo is on-demand album page depth: label/date from MB, blurb from
// Wikipedia. Cached forever including the literal "null" miss.
func (e *Enricher) AlbumInfo(ctx context.Context, albumID string, ts []repo.Track) (json.RawMessage, error) {
	if raw, ok, err := e.cache.Get(ctx, KindAlbumInfo, albumID); err != nil || ok {
		return raw, err
	}
	out := map[string]any{}
	var a albumCache
	if e.cacheGet(ctx, KindAlbum, albumID, &a) && a.Mbid != nil {
		if rel := e.mb.release(ctx, *a.Mbid, "labels+release-groups"); rel != nil {
			var label any
			if len(rel.LabelInfo) > 0 && rel.LabelInfo[0].Label != nil && rel.LabelInfo[0].Label.Name != "" {
				label = rel.LabelInfo[0].Label.Name
			}
			out["label"] = label
			out["date"] = orNull(rel.Date)
			out["country"] = orNull(rel.Country)
			var mbType any
			sec := []string{}
			if rel.ReleaseGroup != nil {
				if rel.ReleaseGroup.PrimaryType != "" {
					mbType = rel.ReleaseGroup.PrimaryType
				}
				if rel.ReleaseGroup.SecondaryTypes != nil {
					sec = rel.ReleaseGroup.SecondaryTypes
				}
			}
			out["mbType"] = mbType
			out["mbSecondary"] = sec
		}
	}
	t := ts[0]
	for _, title := range []string{t.Album + " (" + t.AlbumArtist + " album)", t.Album + " (album)", t.Album} {
		s := e.summary(ctx, title)
		if s == nil || s.Extract == "" || s.Type == "disambiguation" {
			continue
		}
		if !albumRe.MatchString(firstOf(s.Description, s.Extract)) {
			continue
		}
		out["blurb"] = s.Extract
		out["url"] = orNull(s.PageURL)
		break
	}
	// JS truthiness: null/"" are empty, arrays (even []) are content
	nonEmpty := false
	for _, v := range out {
		switch x := v.(type) {
		case nil:
		case string:
			if x != "" {
				nonEmpty = true
			}
		default:
			nonEmpty = true
		}
	}
	var doc any
	if nonEmpty {
		doc = out
	}
	if err := e.put(ctx, KindAlbumInfo, albumID, doc); err != nil {
		return nil, err
	}
	raw, _ := json.Marshal(doc)
	return raw, nil
}

// AlbumInfoCached is the sync, no-network read; raw may be the literal "null".
func (e *Enricher) AlbumInfoCached(ctx context.Context, albumID string) (json.RawMessage, bool, error) {
	return e.cache.Get(ctx, KindAlbumInfo, albumID)
}

// ---- re-identify: MB candidate lists + cache-busting re-enrichment ----------

func (e *Enricher) IdentifyArtist(ctx context.Context, name string) ([]ArtistCandidate, error) {
	as := e.mb.searchArtists(ctx, name, 8)
	out := make([]ArtistCandidate, 0, len(as))
	for _, a := range as {
		var area *string
		if a.Area != nil {
			area = nullable(a.Area.Name)
		}
		out = append(out, ArtistCandidate{
			Mbid: a.ID, Name: a.Name, Type: nullable(a.Type), Area: area,
			Disambiguation: nullable(a.Disambiguation), Score: a.Score,
		})
	}
	return out, nil
}

// ReidentifyArtist fully re-enriches, optionally pinned to the chosen MB
// artist. nil = re-enrichment yielded nothing (API sends {}).
func (e *Enricher) ReidentifyArtist(ctx context.Context, name, mbid string) (json.RawMessage, error) {
	if err := e.cache.Delete(ctx, KindArtist, name); err != nil {
		return nil, err
	}
	e.enrichArtist(ctx, name, mbid)
	ent := e.artistGet(ctx, name)
	if ent == nil {
		return nil, nil
	}
	return json.Marshal(ent)
}

func (e *Enricher) IdentifyAlbum(ctx context.Context, ts []repo.Track) ([]AlbumCandidate, error) {
	rels := e.mb.searchReleases(ctx, ts[0].Album, ts[0].AlbumArtist, 8)
	out := make([]AlbumCandidate, 0, len(rels))
	for _, x := range rels {
		var b strings.Builder
		for _, c := range x.ArtistCredit {
			n := c.Name
			if n == "" {
				n = c.Artist.Name
			}
			b.WriteString(n + c.JoinPhrase)
		}
		out = append(out, AlbumCandidate{
			Mbid: x.ID, Title: x.Title, Artist: nullable(b.String()),
			Date: nullable(x.Date), Country: nullable(x.Country), Tracks: x.TrackCount, Score: x.Score,
		})
	}
	return out, nil
}

func (e *Enricher) ReidentifyAlbum(ctx context.Context, albumID string, ts []repo.Track, mbid string) (json.RawMessage, error) {
	for _, t := range ts { // stale credits from the old match
		if err := e.cache.Delete(ctx, KindTrack, t.ID); err != nil {
			return nil, err
		}
	}
	if err := e.cache.Delete(ctx, KindAlbumInfo, albumID); err != nil {
		return nil, err
	}
	if mbid != "" { // no v marker: enrichAlbum re-pulls this release
		if err := e.put(ctx, KindAlbum, albumID, map[string]string{"mbid": mbid}); err != nil {
			return nil, err
		}
	} else if err := e.cache.Delete(ctx, KindAlbum, albumID); err != nil { // fresh search (embedded mbAlbumId wins if tagged)
		return nil, err
	}
	if err := e.enrichAlbum(ctx, albumID, ts); err != nil {
		return nil, err
	}
	// existing cover art file is kept; delete DATA_DIR/art/<albumId>.jpg to force re-fetch
	return e.AlbumInfo(ctx, albumID, ts) // repopulates label/date/type
}

// ---- cache plumbing ----------------------------------------------------------

func (e *Enricher) cacheGet(ctx context.Context, kind, key string, v any) bool {
	raw, ok, err := e.cache.Get(ctx, kind, key)
	if err != nil {
		e.log("cache get " + kind + "/" + key + ": " + err.Error())
	}
	return ok && json.Unmarshal(raw, v) == nil && string(raw) != "null"
}

func (e *Enricher) put(ctx context.Context, kind, key string, v any) error {
	doc, err := json.Marshal(v)
	if err != nil {
		return err
	}
	if err := e.cache.Put(ctx, kind, key, doc, nowISO()); err != nil {
		e.log("cache put " + kind + "/" + key + ": " + err.Error())
		return err
	}
	return nil
}

func (e *Enricher) artistGet(ctx context.Context, name string) *ArtistEntry {
	var a ArtistEntry
	if !e.cacheGet(ctx, KindArtist, name, &a) {
		return nil
	}
	return &a
}

func (e *Enricher) artistPut(ctx context.Context, name string, a *ArtistEntry) {
	e.put(ctx, KindArtist, name, a)
}

// ---- small helpers -----------------------------------------------------------

// orNull maps "" to JSON null inside map[string]any docs.
func orNull(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func strOf(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func firstOf(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

// nowISO matches JS Date.toISOString (staleness comparisons parse RFC3339).
func nowISO() string { return time.Now().UTC().Format("2006-01-02T15:04:05.000Z") }
