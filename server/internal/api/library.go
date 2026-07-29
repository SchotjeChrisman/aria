package api

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"aria/internal/analyze"
	"aria/internal/genres"
	"aria/internal/repo"
	"aria/internal/scanner"
)

func init() { register(RegisterLibrary) }

// onDemandEnricher is the network-backed surface library.go needs beyond
// Deps.Enricher (compile-time asserted against *enrich.Enricher in enrich.go
// — a signature drift must not silently degrade to cache-only reads). Each
// method returns cache-shaped raw JSON; nil or literal "null" means "looked
// up, nothing found". When the enricher doesn't implement it, handlers fall
// back to enrich_cache reads only.
type onDemandEnricher interface {
	// Person mirrors enrich.js person(): enriches unknown names on demand,
	// refreshes stale discographies, then returns the artist cache entry.
	Person(ctx context.Context, name string) (json.RawMessage, error)
	// AlbumInfo mirrors enrich.js albumInfo(): label/date from MB, blurb from
	// Wikipedia, cached forever including misses.
	AlbumInfo(ctx context.Context, albumID string, tracks []repo.Track) (json.RawMessage, error)
	// Lyrics mirrors enrich.js lyrics(): LRCLIB search, duration-matched,
	// cached forever including misses. Shape {"synced":..,"plain":..} or null.
	Lyrics(ctx context.Context, t repo.Track) (json.RawMessage, error)
}

// latinNamer is the display-name substitution map (raw stored name -> Latin
// spelling). Optional: without it names are served exactly as stored.
type latinNamer interface {
	LatinNames(ctx context.Context) (map[string]string, error)
}

// nameResolver maps a Latin display name back to the raw name everything is
// keyed by. Optional: without it a name is used exactly as the client sent it.
type nameResolver interface {
	ResolveName(ctx context.Context, name string) string
}

// rawName undoes the display Latinisation for a name arriving in a URL. The
// client only ever sees the Latin spelling, so every lookup keyed by an artist
// or composer name — edits, the composer cache — has to come back through here
// or it silently misses the row it is looking for.
func rawName(ctx context.Context, d *Deps, name string) string {
	if nr, ok := d.Enricher.(nameResolver); ok {
		return nr.ResolveName(ctx, name)
	}
	return name
}

// notFound (Express-style 404) lives in tags.go and is shared package-wide.

// writeRawJSON writes pre-encoded JSON (cache blobs served verbatim).
func writeRawJSON(w http.ResponseWriter, code int, doc json.RawMessage) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	w.Write(doc)
}

// truthy is JS truthiness for decoded JSON values. emptyArrayCounts selects
// between `out[k]` (albumInfo: [] is truthy) and the artist check
// `a[k] && (!Array.isArray(a[k]) || a[k].length)` ([] is not content).
func truthy(v any, emptyArrayCounts bool) bool {
	switch x := v.(type) {
	case nil:
		return false
	case bool:
		return x
	case float64:
		return x != 0
	case string:
		return x != ""
	case []any:
		return emptyArrayCounts || len(x) > 0
	default:
		return true // objects
	}
}

func anyTruthy(m map[string]any, emptyArrayCounts bool) bool {
	for _, v := range m {
		if truthy(v, emptyArrayCounts) {
			return true
		}
	}
	return false
}

// overlay copies every key of a JSON object doc onto m (JS spread semantics).
func overlay(m map[string]any, doc json.RawMessage) {
	var o map[string]any
	if json.Unmarshal(doc, &o) == nil {
		for k, v := range o {
			m[k] = v
		}
	}
}

// ---- releaseType (derived, never persisted; port of server.js releaseType) --

var (
	liveRE = regexp.MustCompile(`(?i)\blive (at|in|from|on)\b|\(live[)\s\]]|\[live\]|\blive!?$|\bunplugged\b|\bin concert\b`)
	vaRE   = regexp.MustCompile(`(?i)^various artists?$|^va$`)
	epRE   = regexp.MustCompile(`(?i)\bEP\b|\bE\.P\.\b`)
)

func str(v any) string {
	s, _ := v.(string)
	return s
}

// releaseType derives Album/EP/Single/Live/Compilation for one album's merged
// tracks. cachedInfo is the raw albumInfo cache entry (may be nil or "null").
// First match wins — order mirrors the legacy function exactly.
func releaseType(albumTracks []map[string]any, cachedInfo json.RawMessage) string {
	var info struct {
		MBType      *string  `json:"mbType"`
		MBSecondary []string `json:"mbSecondary"`
	}
	if cachedInfo != nil {
		json.Unmarshal(cachedInfo, &info)
	}
	for _, s := range info.MBSecondary {
		if s == "Compilation" {
			return "Compilation"
		}
	}
	for _, s := range info.MBSecondary {
		if s == "Live" {
			return "Live"
		}
	}
	if info.MBType != nil {
		switch *info.MBType {
		case "Single", "EP", "Album":
			return *info.MBType
		}
	}
	if len(albumTracks) == 0 {
		return "Album"
	}
	if vaRE.MatchString(str(albumTracks[0]["albumArtist"])) {
		return "Compilation"
	}
	title := str(albumTracks[0]["album"])
	if liveRE.MatchString(title) {
		return "Live"
	}
	if epRE.MatchString(title) {
		return "EP"
	}
	n := len(albumTracks)
	var dur float64
	for _, t := range albumTracks {
		if d, ok := t["duration"].(float64); ok {
			dur += d
		}
	}
	if n <= 3 && dur <= 900 {
		return "Single"
	}
	if n <= 6 && dur <= 1800 {
		return "EP"
	}
	return "Album"
}

// ---- /api/tracks response (port of server.js tracksResponse) ---------------

// ptrVal collapses a nullable struct field to its JSON-shaped map value.
func ptrVal[T any](p *T) any {
	if p == nil {
		return nil
	}
	return *p
}

// mergedTracks returns the full /api/tracks payload, served from the Deps
// cache when clean and rebuilt via buildMergedTracks otherwise. Callers must
// treat the returned maps as read-only — they are shared across requests.
func mergedTracks(ctx context.Context, d *Deps) ([]map[string]any, error) {
	d.tracksMu.Lock()
	if v := d.tracksView; v != nil {
		d.tracksMu.Unlock()
		return v, nil
	}
	gen := d.tracksGen
	d.tracksMu.Unlock()

	// build outside tracksMu so warm readers never queue behind a rebuild;
	// buildMu single-flights concurrent cold readers
	d.buildMu.Lock()
	defer d.buildMu.Unlock()
	d.tracksMu.Lock()
	if v := d.tracksView; v != nil { // another builder finished while we waited
		d.tracksMu.Unlock()
		return v, nil
	}
	gen = d.tracksGen
	d.tracksMu.Unlock()

	merged, err := buildMergedTracks(ctx, d)
	if err != nil {
		return nil, err
	}
	d.tracksMu.Lock()
	if d.tracksGen == gen { // don't publish a view built before an invalidation
		d.tracksView = merged
	}
	d.tracksMu.Unlock()
	return merged, nil
}

// mergedTracksGz returns the full /api/tracks payload as pre-gzipped JSON,
// cached per generation. At 100k tracks, reflection-encoding the map view is
// seconds of CPU per request — this pays it once per invalidation instead.
func mergedTracksGz(ctx context.Context, d *Deps) ([]byte, error) {
	d.tracksMu.Lock()
	if d.tracksGz != nil {
		gz := d.tracksGz
		d.tracksMu.Unlock()
		return gz, nil
	}
	d.tracksMu.Unlock()

	d.gzMu.Lock() // heavy cold path: one encoder at a time
	defer d.gzMu.Unlock()
	d.tracksMu.Lock()
	if d.tracksGz != nil {
		gz := d.tracksGz
		d.tracksMu.Unlock()
		return gz, nil
	}
	gen := d.tracksGen
	d.tracksMu.Unlock()

	out, err := mergedTracks(ctx, d)
	if err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	gw, _ := gzip.NewWriterLevel(&buf, gzip.BestSpeed)
	if err := json.NewEncoder(gw).Encode(out); err != nil {
		return nil, err
	}
	if err := gw.Close(); err != nil {
		return nil, err
	}
	b := buf.Bytes()
	d.tracksMu.Lock()
	if d.tracksGen == gen {
		d.tracksGz = b
	}
	d.tracksMu.Unlock()
	return b, nil
}

// buildMergedTracks builds the full /api/tracks payload: file tags merged with
// enrichment credits (enrich_cache kind "track"), hasArt widened by
// enrichment-fetched art (kind "album"), album edits fanned onto tracks,
// track edits overlaid (edits beat file tags AND enrichment), path stripped,
// plus derived releaseType, canonical genres and user tag names. Shared with
// playlists/stats route files — smart rules evaluate against this shape.
func buildMergedTracks(ctx context.Context, d *Deps) ([]map[string]any, error) {
	ts, err := d.Tracks.ListAll(ctx)
	if err != nil {
		return nil, err
	}
	enrichTrack, err := d.EnrichCache.ListKind(ctx, "track")
	if err != nil {
		return nil, err
	}
	enrichAlbum, err := d.EnrichCache.ListKind(ctx, "album")
	if err != nil {
		return nil, err
	}
	albumInfos, err := d.EnrichCache.ListKind(ctx, "albumInfo")
	if err != nil {
		return nil, err
	}
	sources, err := d.EnrichCache.ListKind(ctx, "sources")
	if err != nil {
		return nil, err
	}
	editTrack, err := d.Edits.ListKind(ctx, "track")
	if err != nil {
		return nil, err
	}
	editAlbumRaw, err := d.Edits.ListKind(ctx, "album")
	if err != nil {
		return nil, err
	}
	tags, err := d.Tags.List(ctx)
	if err != nil {
		return nil, err
	}
	// Measured loudness. Gains are derived here rather than stored so the
	// ReplayGain reference level stays a decision instead of being frozen into
	// every row; the album aggregate is arithmetic over the tracks already in
	// hand (durations and album ids included), so it needs no second query and
	// no album_audio table.
	audio, err := d.Audio.ListAll(ctx)
	if err != nil {
		return nil, err
	}
	byAlbumLoud := map[string][]analyze.AlbumTrack{}
	for _, t := range ts {
		a, ok := audio[t.ID]
		if !ok {
			continue
		}
		var dur float64
		if t.Duration != nil {
			dur = *t.Duration
		}
		byAlbumLoud[t.AlbumID] = append(byAlbumLoud[t.AlbumID], analyze.AlbumTrack{
			LUFS: a.IntegratedLUFS, PeakDBFS: a.TruePeakDBFS, Duration: dur,
		})
	}
	albumGain := make(map[string]*float64, len(byAlbumLoud))
	albumPeak := make(map[string]*float64, len(byAlbumLoud))
	for id, ats := range byAlbumLoud {
		albumGain[id], albumPeak[id] = analyze.AlbumGain(ats), analyze.AlbumPeak(ats)
	}

	editAlbum := make(map[string]map[string]any, len(editAlbumRaw))
	for k, raw := range editAlbumRaw {
		var m map[string]any
		if json.Unmarshal(raw, &m) == nil {
			editAlbum[k] = m
		}
	}
	// album enrichment entries carry the art flag and the classical display
	// policy (a release-level performer, and the composers split off the
	// artist credit)
	artByAlbum := map[string]bool{}
	displayByAlbum := map[string]string{}
	composersByAlbum := map[string][]string{}
	// corrections from a confirmed MusicBrainz match, fanned onto the album's
	// tracks. Built as a map rather than fanned field-by-field so an absent
	// correction is simply an absent key — an empty string here must not blank
	// a file tag.
	fixByAlbum := map[string]map[string]any{}
	for k, raw := range enrichAlbum {
		var e struct {
			Art           bool     `json:"art"`
			DisplayArtist string   `json:"displayArtist"`
			Composers     []string `json:"composers"`
			Album         string   `json:"album"`
			AlbumArtist   string   `json:"albumArtist"`
			Year          int      `json:"year"`
		}
		if json.Unmarshal(raw, &e) != nil {
			continue
		}
		if e.Art {
			artByAlbum[k] = true
		}
		displayByAlbum[k] = e.DisplayArtist
		composersByAlbum[k] = e.Composers
		fix := map[string]any{}
		if e.Album != "" {
			fix["album"] = e.Album
		}
		if e.AlbumArtist != "" {
			fix["albumArtist"] = e.AlbumArtist
		}
		if e.Year > 0 {
			fix["year"] = e.Year
		}
		if len(fix) > 0 {
			fixByAlbum[k] = fix
		}
	}
	// "the rule is a setting, not a hardcode"; unset means on
	classical := true
	if v, err := d.Settings.Get(ctx, "classicalDisplayArtist"); err == nil && v == "0" {
		classical = false
	}
	// raw name -> Latin display name; empty when the enricher isn't wired
	var latin map[string]string
	if ln, ok := d.Enricher.(latinNamer); ok {
		if latin, err = ln.LatinNames(ctx); err != nil {
			return nil, err
		}
	}

	// Enrichment-derived genres per album: MusicBrainz's community-voted genre
	// tags plus Discogs' genres and styles, canonicalised through the same
	// closed taxonomy the file tags go through.
	srcGenres := make(map[string][]string, len(sources))
	for id, raw := range sources {
		// keys mirror enrich.sourcesCache; decoded structurally rather than
		// imported so api keeps no compile dependency on the cache shape
		var s struct {
			MBGenres []string `json:"mbGenres"`
			Genres   []string `json:"dgGenres"`
			Styles   []string `json:"dgStyles"`
		}
		if json.Unmarshal(raw, &s) != nil {
			continue
		}
		if g := genres.SplitAll(slices.Concat(s.MBGenres, s.Genres, s.Styles)); len(g) > 0 {
			srcGenres[id] = g
		}
	}

	// album edits that flow onto the album's tracks (label/blurb etc stay album-level)
	albumFan := []string{"album", "albumArtist", "genre", "year", "artVersion"}

	merged := make([]map[string]any, 0, len(ts))
	for _, t := range ts {
		au := audio[t.ID] // zero value when unanalysed: every gain stays null
		// built straight from struct fields ("path" intentionally omitted);
		// keys mirror the repo.Track json tags
		m := map[string]any{
			"id": t.ID, "addedAt": t.AddedAt, "title": t.Title, "artist": t.Artist,
			"albumArtist": t.AlbumArtist, "album": t.Album, "albumId": t.AlbumID,
			"trackNo": ptrVal(t.TrackNo), "discNo": ptrVal(t.DiscNo), "year": ptrVal(t.Year),
			"genre": ptrVal(t.Genre), "composer": ptrVal(t.Composer), "conductor": ptrVal(t.Conductor),
			"work": ptrVal(t.Work), "movement": ptrVal(t.Movement),
			"mbAlbumId": ptrVal(t.MBAlbumID), "mbRecordingId": ptrVal(t.MBRecordingID),
			"mbAlbumArtistId": ptrVal(t.MBAlbumArtistID),
			"duration":        ptrVal(t.Duration), "format": t.Format,
			"sampleRate": ptrVal(t.SampleRate), "bitsPerSample": ptrVal(t.BitsPerSample),
			"channels": ptrVal(t.Channels), "lossless": t.Lossless, "hasArt": t.HasArt,
			"favourite": t.Favourite,
			// null until the analysis pass has seen the file — and null is the
			// only safe unknown here: a client that guessed 0 dB would be
			// applying DSP on no evidence.
			"trackGainDb": ptrVal(analyze.TrackGain(au.IntegratedLUFS)),
			"albumGainDb": ptrVal(albumGain[t.AlbumID]),
			// ponytail: no client reads the peaks yet — aria_api's Track parses
			// only the two gains. They are served anyway so the peak-aware
			// boost eq.dart's appliedGain() ponytail describes needs no server
			// change, only a client one; the measurement itself is the hours.
			"trackPeak": ptrVal(analyze.TrackPeak(au.TruePeakDBFS)),
			"albumPeak": ptrVal(albumPeak[t.AlbumID]),
			// The rest of what the decoder saw, unconverted: the loudness and
			// range in their own units and the transcode flag. These are what
			// the quality smart-playlist predicates and the health view read —
			// the columns migration 008 measured and nothing consumed.
			//
			// Null means unanalysed, and stays null: a missing measurement must
			// fail a `> -14 LUFS` rule rather than pass it as 0.
			"loudnessLufs":   ptrVal(au.IntegratedLUFS),
			"dynamicRangeLu": ptrVal(au.LRA),
			// The one non-null default, because it cannot be otherwise: `false`
			// on an unanalysed track means "nothing has contradicted the
			// container yet", not "verified genuine".
			"suspect": au.Suspect,
		}
		if raw, ok := enrichTrack[t.ID]; ok {
			overlay(m, raw) // composer/conductor/orchestra/performers corrections
		}
		if t.HasArt || artByAlbum[t.AlbumID] {
			m["hasArt"] = true
		}
		// Album/artist/year corrections from the confirmed release. Before the
		// classical display policy (a more specific derived rule about the same
		// field) and before the edit fan-out, which is the entire implementation
		// of "a manual edit always beats an automatic correction": the layers
		// are file tags -> derived track blob -> derived album blob -> album
		// edits -> track edits, and later simply wins. No provenance check, no
		// per-field ownership, nothing for a future pass to get wrong.
		for k, v := range fixByAlbum[t.AlbumID] {
			m[k] = v
		}
		// classical display policy, before the edit fan-out so a user edit wins
		if classical {
			if da := displayByAlbum[t.AlbumID]; da != "" {
				m["albumArtist"] = da
			}
			if cs := composersByAlbum[t.AlbumID]; len(cs) > 0 && str(m["composer"]) == "" {
				m["composer"] = strings.Join(cs, ", ")
			}
		}
		if ae := editAlbum[t.AlbumID]; ae != nil {
			for _, f := range albumFan {
				if v, ok := ae[f]; ok {
					m[f] = v
				}
			}
		}
		if raw, ok := editTrack[t.ID]; ok {
			overlay(m, raw)
		}
		merged = append(merged, m)
	}

	// releaseType per album, from the merged (edited) tracks
	byAlbum := map[string][]map[string]any{}
	for _, m := range merged {
		id := str(m["albumId"])
		byAlbum[id] = append(byAlbum[id], m)
	}
	types := make(map[string]string, len(byAlbum))
	for id, albumTs := range byAlbum {
		if rt, ok := editAlbum[id]["releaseType"].(string); ok {
			types[id] = rt
			continue
		}
		types[id] = releaseType(albumTs, albumInfos[id])
	}

	// tag membership by direct track tag, via the track's album, or via its
	// artist names; each item carries its tag's whole ancestor chain so parent
	// tags match too
	tagByID := make(map[string]*repo.Tag, len(tags))
	for i := range tags {
		tagByID[tags[i].ID] = &tags[i]
	}
	chain := func(t *repo.Tag) []string {
		var names []string
		seen := map[string]bool{}
		for x := t; x != nil && !seen[x.ID]; {
			seen[x.ID] = true
			names = append(names, x.Name)
			if x.Parent == nil {
				break
			}
			x = tagByID[*x.Parent]
		}
		return names
	}
	tagBy := map[string]map[string][]string{"track": {}, "album": {}, "artist": {}}
	for i := range tags {
		names := chain(&tags[i])
		for _, it := range tags[i].Items {
			if m, ok := tagBy[it.Kind]; ok {
				m[it.Key] = append(m[it.Key], names...)
			}
		}
	}

	for _, m := range merged {
		m["releaseType"] = types[str(m["albumId"])]
		// The file's own tag stays first and stays authoritative — `genre`, the
		// raw string, is untouched, so display and the edits overlay are
		// unaffected and a user edit to `genre` still wins outright. The
		// enrichment genres are additive to the DERIVED array only.
		//
		// Union rather than fill-when-empty, deliberately: an album tagged
		// "Rock" whose release group is voted alternative rock / art rock
		// should be findable under all three, and the closed tree plus
		// head-word inference is what keeps that from polluting the browse.
		// The one-line downgrade if it proves noisy is `if len(g) == 0 {`
		// around the merge.
		g := genres.Split(str(m["genre"]))
		if add := srcGenres[str(m["albumId"])]; len(add) > 0 {
			// clone first: Split memoises its result in a sync.Map, so
			// appending in place would scribble into another track's array
			g = slices.Clone(g)
			for _, x := range add {
				if !slices.Contains(g, x) {
					g = append(g, x)
				}
			}
		}
		m["genres"] = g
		names := []string{}
		seen := map[string]bool{}
		// artist tags match on both spellings: rows written before Latinisation
		// are keyed by the raw name, and anything the client creates from here on
		// can only be keyed by the Latin display name it was served
		for _, list := range [][]string{
			tagBy["track"][str(m["id"])], tagBy["album"][str(m["albumId"])],
			tagBy["artist"][str(m["artist"])], tagBy["artist"][latin[str(m["artist"])]],
			tagBy["artist"][str(m["albumArtist"])], tagBy["artist"][latin[str(m["albumArtist"])]],
		} {
			for _, n := range list {
				if !seen[n] {
					seen[n] = true
					names = append(names, n)
				}
			}
		}
		m["tags"] = names
	}

	// Latin display substitution runs last: tag membership (above) and the
	// releaseType grouping match on the raw stored names, and rewriting them
	// earlier would silently drop every latinised artist out of its user tags.
	for _, m := range merged {
		latinize(m, latin)
	}
	return merged, nil
}

// rawSpellings inverts the display map: lowercased Latin name -> the lowercased
// original script it replaced. Smart-playlist rules are free text, so they can
// only be matched by trying both spellings — a rule written before Latinisation
// names the raw form, one written after names the Latin form.
//
// ponytail: soft-fails to nil (rules then match the Latin spelling only). The
// caller has already built the merged views through the same LatinNames call,
// so a failure here means it just failed there too and the request is dead
// anyway. Thread the error through if that stops being true.
func rawSpellings(ctx context.Context, d *Deps) map[string]string {
	ln, ok := d.Enricher.(latinNamer)
	if !ok {
		return nil
	}
	latin, err := ln.LatinNames(ctx)
	if err != nil {
		return nil
	}
	out := make(map[string]string, len(latin))
	for k, v := range latin {
		if lk, lv := strings.ToLower(k), strings.ToLower(v); lk != lv {
			out[lv] = lk
		}
	}
	return out
}

// latinize rewrites the credited-name fields of one merged track to their
// Latin spelling. Display only — the original script stays in the DB, the
// enrich cache and the files; a name with no mapping is left exactly as it is.
func latinize(m map[string]any, latin map[string]string) {
	if len(latin) == 0 {
		return
	}
	for _, k := range []string{"artist", "albumArtist", "composer", "conductor", "orchestra"} {
		if v, ok := latin[str(m[k])]; ok {
			m[k] = v
		}
	}
	ps, _ := m["performers"].([]any)
	for _, p := range ps {
		pm, ok := p.(map[string]any)
		if !ok {
			continue
		}
		if v, ok := latin[str(pm["name"])]; ok {
			pm["name"] = v
		}
	}
}

// asOnDemand returns the enricher's on-demand surface, if wired.
func asOnDemand(d *Deps) (onDemandEnricher, bool) {
	od, ok := d.Enricher.(onDemandEnricher)
	return od, ok
}

// RegisterLibrary mounts status/scan/tracks/genres and the on-demand
// enrichment reads (album info, artist, composer, lyrics). Already
// self-registered via init() — api.New(deps) includes it; do not also call
// this manually or the mux will panic on duplicate patterns.
func RegisterLibrary(mux *http.ServeMux, d *Deps) {
	mux.HandleFunc("GET /api/status", func(w http.ResponseWriter, r *http.Request) {
		n, err := d.Tracks.Count(r.Context())
		if err != nil {
			httpError(w, http.StatusInternalServerError, "db error")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"tracks": n, "musicDir": d.Cfg.MusicDir, "version": d.Version,
			"transcode": d.CanTranscode, "analyze": d.Analyzer != nil,
			"fingerprint": d.Fingerprinter != nil,
		})
	})

	// synchronous like the legacy server; the scanner publishes SSE progress
	// on the hub itself. App-lifetime context: a client disconnect must not
	// abort a half-done scan, but SIGTERM must.
	mux.HandleFunc("POST /api/scan", func(w http.ResponseWriter, r *http.Request) {
		if d.Scanner == nil {
			httpError(w, http.StatusInternalServerError, "scan failed")
			return
		}
		n, err := d.Scanner.Scan(d.bgCtx())
		if err != nil {
			if errors.Is(err, scanner.ErrScanRunning) {
				httpError(w, http.StatusConflict, "scan already running")
				return
			}
			log.Printf("scan failed: %v", err)
			httpError(w, http.StatusInternalServerError, "scan failed")
			return
		}
		d.InvalidateTracks()
		if d.Enricher != nil || d.Analyzer != nil || d.Fingerprinter != nil {
			// One GoBg, chained: enrichment is network-bound and quick,
			// fingerprinting is minutes, the analysis pass is hours of decoding.
			// Running them in sequence is also what guarantees neither job is
			// ever concurrent with itself on the scan path, and keeps three
			// disk-heavy passes off each other.
			d.GoBg(func(ctx context.Context) {
				// FIRST, not merely before the analyzer. Matching is a phase of
				// the enricher, and its strongest candidate source is the release
				// groups AcoustID voted for — which do not exist until this pass
				// has run. Behind the enricher, the first scan of a library would
				// decide every album on text search alone, and a `matched`
				// decision is never revisited (retryAfter is empty for matched),
				// so that first weak answer would be permanent. 64 ms/file buys
				// the evidence the decision is supposed to rest on.
				// Nothing it writes reaches /api/tracks, hence no invalidate.
				if d.Fingerprinter != nil {
					if err := d.Fingerprinter.Run(ctx); err != nil {
						log.Printf("fingerprint: %v", err)
					}
				}
				if d.Enricher != nil {
					if err := d.Enricher.Run(ctx); err != nil {
						log.Printf("enrich: %v", err)
					}
					d.InvalidateTracks() // enrichment feeds credits/hasArt into the merge
				}
				if d.Analyzer != nil {
					if err := d.Analyzer.Run(ctx); err != nil {
						log.Printf("analyze: %v", err)
					}
					d.InvalidateTracks() // loudness feeds trackGainDb/albumGainDb
				}
			})
		}
		writeJSON(w, http.StatusOK, map[string]int{"tracks": n})
	})

	mux.HandleFunc("GET /api/tracks", func(w http.ResponseWriter, r *http.Request) {
		limit, offset := -1, 0
		if s := r.URL.Query().Get("limit"); s != "" {
			n, err := strconv.Atoi(s)
			if err != nil || n < 1 {
				httpError(w, http.StatusBadRequest, "invalid limit")
				return
			}
			limit = n
		}
		if s := r.URL.Query().Get("offset"); s != "" {
			n, err := strconv.Atoi(s)
			if err != nil || n < 0 {
				httpError(w, http.StatusBadRequest, "invalid offset")
				return
			}
			offset = n
		}
		// the common case — whole library, gzip-capable client — serves the
		// pre-encoded cache; the gzip middleware passes it through untouched
		if limit == -1 && offset == 0 && strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
			gz, err := mergedTracksGz(r.Context(), d)
			if err != nil {
				httpError(w, http.StatusInternalServerError, "db error")
				return
			}
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Content-Encoding", "gzip")
			w.Header().Set("Content-Length", strconv.Itoa(len(gz)))
			w.Write(gz)
			return
		}
		out, err := mergedTracks(r.Context(), d)
		if err != nil {
			httpError(w, http.StatusInternalServerError, "db error")
			return
		}
		// releaseType needs whole albums, so slicing happens after the merge
		if offset > len(out) {
			offset = len(out)
		}
		out = out[offset:]
		if limit >= 0 && limit < len(out) {
			out = out[:limit]
		}
		writeJSON(w, http.StatusOK, out)
	})

	// Independent favourite flag: PUT {favourite: bool}. Mirrors the tag-item
	// mutation pattern — set, invalidate the merged view, echo the new state.
	mux.HandleFunc("PUT /api/tracks/{id}/favourite", func(w http.ResponseWriter, r *http.Request) {
		t, err := d.Tracks.ByID(r.Context(), r.PathValue("id"))
		if err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if t == nil {
			notFound(w)
			return
		}
		body, ok := bodyMap(w, r)
		if !ok {
			return
		}
		fav, _ := body["favourite"].(bool)
		if err := d.Tracks.SetFavourite(r.Context(), t.ID, fav); err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		d.InvalidateTracks()
		writeJSON(w, http.StatusOK, map[string]any{"favourite": fav})
	})

	mux.HandleFunc("GET /api/genres", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"tree": genres.Tree})
	})

	// album edits served via /info (the rest fan onto tracks instead)
	albumInfoEdits := []string{"label", "date", "country", "catno", "blurb"}
	mux.HandleFunc("GET /api/album/{albumId}/info", func(w http.ResponseWriter, r *http.Request) {
		albumID := r.PathValue("albumId")
		ts, err := d.Tracks.ByAlbum(r.Context(), albumID)
		if err != nil || len(ts) == 0 {
			notFound(w)
			return
		}
		var doc json.RawMessage
		if od, ok := asOnDemand(d); ok {
			if doc, err = od.AlbumInfo(r.Context(), albumID, ts); err != nil {
				notFound(w) // legacy catch -> 404
				return
			}
		} else {
			doc, _, _ = d.EnrichCache.Get(r.Context(), "albumInfo", albumID)
		}
		out := map[string]any{}
		if doc != nil {
			json.Unmarshal(doc, &out) // literal "null" leaves it empty
			if out == nil {
				out = map[string]any{}
			}
		}
		if raw, err := d.Edits.Get(r.Context(), "album", albumID); err == nil && raw != nil {
			var ae map[string]any
			if json.Unmarshal(raw, &ae) == nil {
				for _, f := range albumInfoEdits {
					if v, ok := ae[f]; ok {
						out[f] = v
					}
				}
			}
		}
		if !anyTruthy(out, true) {
			notFound(w)
			return
		}
		writeJSON(w, http.StatusOK, out)
	})

	// bounds synchronous on-demand Person() calls so a burst of artist-page
	// requests can't pile up goroutines behind the polite MB rate limit
	personSem := make(chan struct{}, 4)
	mux.HandleFunc("GET /api/artist/{name}", func(w http.ResponseWriter, r *http.Request) {
		// the app navigates with the Latin display name; everything here — the
		// cache entry, the edit row — is keyed by the original script
		name := rawName(r.Context(), d, r.PathValue("name"))
		var doc json.RawMessage
		var err error
		if od, ok := asOnDemand(d); ok {
			select {
			case personSem <- struct{}{}:
			case <-r.Context().Done():
				return
			}
			// enriches unknown names on demand (~3-6s first time)
			doc, err = od.Person(r.Context(), name)
			<-personSem
			if err != nil {
				notFound(w)
				return
			}
		} else {
			doc, _, _ = d.EnrichCache.Get(r.Context(), "artist", name)
		}
		var p map[string]any
		if doc != nil {
			json.Unmarshal(doc, &p)
		}
		// DB edits beat enrichment, and make even MB-unknown names real
		if raw, err := d.Edits.Get(r.Context(), "artist", name); err == nil && raw != nil {
			if p == nil {
				p = map[string]any{}
			}
			overlay(p, raw)
		}
		// empty arrays (similar/members/bands) are not content — a name MB
		// never heard of stays 404
		if p == nil || !anyTruthy(p, false) {
			notFound(w)
			return
		}
		writeJSON(w, http.StatusOK, p)
	})

	// sync cache only — never blocks on network. The composer cache is keyed by
	// the raw name too, so a Latinised composer needs resolving first or the
	// page 404s and loses its whole hero card.
	mux.HandleFunc("GET /api/composer/{name}", func(w http.ResponseWriter, r *http.Request) {
		doc, found, err := d.EnrichCache.Get(r.Context(), "composer", rawName(r.Context(), d, r.PathValue("name")))
		if err != nil || !found || string(doc) == "null" {
			notFound(w)
			return
		}
		writeRawJSON(w, http.StatusOK, doc)
	})

	mux.HandleFunc("GET /api/lyrics/{id}", func(w http.ResponseWriter, r *http.Request) {
		t, err := d.Tracks.ByID(r.Context(), r.PathValue("id"))
		if err != nil || t == nil {
			notFound(w)
			return
		}
		var doc json.RawMessage
		if od, ok := asOnDemand(d); ok {
			if doc, err = od.Lyrics(r.Context(), *t); err != nil {
				notFound(w)
				return
			}
		} else {
			doc, _, _ = d.EnrichCache.Get(r.Context(), "lyrics", t.ID)
		}
		var l struct {
			Synced *string `json:"synced"`
			Plain  *string `json:"plain"`
		}
		if doc == nil || json.Unmarshal(doc, &l) != nil {
			notFound(w)
			return
		}
		if (l.Synced == nil || *l.Synced == "") && (l.Plain == nil || *l.Plain == "") {
			notFound(w)
			return
		}
		writeRawJSON(w, http.StatusOK, doc)
	})
}
