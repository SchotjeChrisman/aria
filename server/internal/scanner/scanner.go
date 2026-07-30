// Package scanner walks MUSIC_DIR, parses tags concurrently via go-taglib,
// and upserts the tracks table incrementally (unchanged mtime+size = skip).
package scanner

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"go.senan.xyz/taglib"

	"aria/internal/repo"
)

// The gate on what gets indexed at all. Deliberately a subset of the 37
// extensions TagLib dispatches on: every entry here must ALSO be decodable by
// the ffmpeg the high/low tiers shell out to, or serveTranscoded 500s on a row
// the library happily shows. That rules out .dff/.dsdiff (TagLib tags it,
// ffmpeg has no DSDIFF demuxer — only dsf), the tracker modules (.mod/.it/.xm
// need libopenmpt, absent from the pinned static-ffmpeg), .m4p (FairPlay),
// .mp4/.m4v/.3g2 (video would be indexed as tracks, and we ship no ffprobe to
// tell them apart) and .mka/.caf/.w64 (TagLib mis-sniffs them into zero-length
// ghost rows). Adding here is safe for existing installs: a previously
// ineligible file has no tracks row, so the mtime+size skip in Scan() misses
// and it is parsed on the next scan — no migration, no forced full rescan.
var exts = map[string]bool{
	".flac": true, ".mp3": true, ".m4a": true, ".ogg": true, ".opus": true,
	".wav": true, ".aiff": true, ".ape": true, ".wv": true, ".dsf": true,
	// .aif is the commoner spelling of .aiff (and what Apple tools write);
	// .aifc/.afc are AIFF-C, which may hold COMPRESSED audio — hence the
	// InnerCodec check in isLossless, not a blanket "aiff is lossless".
	".aif": true, ".aifc": true, ".afc": true,
	// .oga is Ogg with any payload: vorbis, opus, or FLAC. taglib reports Ogg
	// FLAC as format "flac" (it reuses FLAC::Properties and is indistinguishable),
	// so lossless already comes out right without a new clause.
	".oga": true, ".spx": true,
	// ponytail: .m4b turns a 14-hour audiobook into one track in one album —
	// chapter atoms are not modeled. Keep audiobooks out of MUSIC_DIR, or model
	// chapters if that ever matters.
	".m4b": true,
	".wma": true, ".tta": true, ".shn": true, ".mpc": true,
}

// taglib format names that are lossless whatever the payload. The three
// containers that can hold either live in isLossless instead.
var losslessFmt = map[string]bool{
	"flac": true, "ape": true, "wavpack": true, "dsf": true,
	"tta": true, "shorten": true,
}

// isLossless: the container name settles it for most formats, but four carry
// either kind of payload and taglib exposes exactly the signal to tell them
// apart (taglib.cpp extract_format_codec_depth). wav/aiff were previously
// trusted on the container alone, which marked ADPCM wav and compressed
// AIFF-C as lossless; InnerCodec is set to "pcm" only for wFormatTag 1/3 and
// AIFF compression NONE/sowt. Gating on "pcm" does not regress hi-res or
// multichannel WAVE_FORMAT_EXTENSIBLE — taglib still reports pcm for those.
func isLossless(format, codec string) bool {
	switch format {
	case "mp4":
		return codec == "alac"
	case "asf":
		return codec == "wma9lossless" // wma1/wma2/wma9pro are lossy
	case "wav", "aiff":
		return codec == "pcm"
	}
	return losslessFmt[format]
}

// "Work: Movement" / "Work - Movement" where the movement starts with a roman
// or arabic numeral. Same pattern as scanner.js; explicit tags win when present.
var workRE = regexp.MustCompile(`^(.+)(?::|\s[-–—])\s+((?:[IVXLCDM]+|No\.?\s*\d+|\d+)[.):]\s*.+)$`)

// A disc subfolder must carry a numeral. That single requirement is what keeps
// "Disc" (a band), "Discography", "Disco", "CD Singles", "Disc Jockey",
// "Vinyl Days" and "Cassette Tapes" from folding. The roman numerals are an
// explicit whitelist, not [ivxlcdm]{1,4}, which would match "Disc Mix".
//
// The leading word is the folder's disc LABEL. cd/disc/disk cover hand-made
// libraries; the rest are MusicBrainz medium formats, which is what a
// MusicBrainz-aware tagger writes instead ("Digital Media 01", "Hybrid SACD 2").
// Unrecognised, every one of those folders becomes its own album and a boxed set
// fragments into one album per disc — the single largest source of phantom
// albums in a Picard-organised library.
//
// ponytail: a fixed word list, not "any word followed by a number" — the latter
// swallows an album genuinely called "Apollo 11". The robust rule (are this
// folder's SIBLINGS named the same way?) needs cross-folder context, and
// albumIdentity is deliberately a pure function of one path so migration 007's
// remap can recompute ids from stored columns without re-walking the library.
// Ceiling: formats not listed here (`7" Vinyl`, localised names) still split.
// Upgrade: hand the sibling listing to the scanner and fold on the shape.
var discSegRE = regexp.MustCompile(`(?i)^(?:digital media|hybrid sacd|reel-to-reel|dvd-audio|dvd-video|dualdisc|minidisc|cassette|blu-ray|shm-cd|vinyl|sacd|hdcd|dvd|cd|disc|disk)[ _.\-]*(\d{1,3}|i{1,3}|iv|v|vi{1,3}|ix|x|one|two|three|four|five|six|seven|eight|nine|ten)(?:[ _.\-–—(\[].*)?$`)

// Trailing disc marker on an ALBUM tag: folding the directory achieves nothing
// if the tags say "Album (Disc 1)" / "Album (Disc 2)", because the album key
// would re-split what the directory just merged.
var discSuffixRE = regexp.MustCompile(`(?i)[ _.,\-–—]*[(\[]?\s*(?:cd|disc|disk)[ _.\-]*(?:\d{1,3}|i{1,3}|iv|v|vi{1,3}|ix|x|one|two|three|four|five|six|seven|eight|nine|ten)\s*[)\]]?\s*$`)

var discWords = map[string]int{
	"i": 1, "ii": 2, "iii": 3, "iv": 4, "v": 5, "vi": 6, "vii": 7, "viii": 8, "ix": 9, "x": 10,
	"one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
	"six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
}

const batchSize = 500

// unknownAlbum is the placeholder for a missing ALBUM tag. albumIdentity has to
// recognise it: it is the absence of the only tiebreak, not a title.
const unknownAlbum = "Unknown Album"

// ErrScanRunning is returned by Scan when another scan holds the run lock;
// the API maps it to 409.
var ErrScanRunning = errors.New("scan already running")

type Scanner struct {
	musicDir, dataDir string
	tracks            *repo.Tracks
	albums            *repo.Albums
	onProgress        func(done, total int) // nil ok; fed to the SSE hub by main

	runMu sync.Mutex // serializes scans

	mu       sync.Mutex
	scanning bool
	done     int
	total    int
	parsed   int // files actually parsed last scan (skips excluded); read by tests
}

func New(musicDir, dataDir string, tracks *repo.Tracks, albums *repo.Albums, onProgress func(done, total int)) *Scanner {
	return &Scanner{musicDir: musicDir, dataDir: dataDir, tracks: tracks, albums: albums, onProgress: onProgress}
}

// Status reports {"scanning":bool,"done":int,"total":int}.
func (s *Scanner) Status() any {
	s.mu.Lock()
	defer s.mu.Unlock()
	return struct {
		Scanning bool `json:"scanning"`
		Done     int  `json:"done"`
		Total    int  `json:"total"`
	}{s.scanning, s.done, s.total}
}

// LastParsed is how many files the most recent scan actually re-read, as
// opposed to skipped on unchanged mtime+size. Zero after a scan means the
// library is byte-for-byte what it was, which is what lets the periodic scan
// decide whether the enrich/fingerprint/analyse chain has anything to chew on.
// Read it straight after Scan returns: it is overwritten by the next scan.
func (s *Scanner) LastParsed() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.parsed
}

// Busy reports whether a scan is in flight. The loudness-analysis job reads it
// to stay off the disk while the scanner is walking it.
func (s *Scanner) Busy() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.scanning
}

type fileEntry struct {
	abs, rel    string
	mtime, size int64
}

// Scan walks the library, re-parses new/changed files across NumCPU workers,
// deletes rows for vanished files, rebuilds albums, and returns the track count.
func (s *Scanner) Scan(ctx context.Context) (int, error) {
	if !s.runMu.TryLock() {
		return 0, ErrScanRunning
	}
	defer s.runMu.Unlock()

	artDir := filepath.Join(s.dataDir, "art")
	if err := os.MkdirAll(artDir, 0o755); err != nil {
		return 0, err
	}

	files, walkErrs := s.walk()
	prev, err := s.tracks.ListPathInfo(ctx)
	if err != nil {
		return 0, err
	}
	// a vanished mount must never wipe the library: refuse to run when the
	// walk errored or found nothing while the DB still has tracks
	if len(prev) > 0 && (walkErrs > 0 || len(files) == 0) {
		if len(files) == 0 {
			return 0, fmt.Errorf("scan aborted: %s yielded no files (%d walk errors) but the library has %d tracks — is the music dir mounted?", s.musicDir, walkErrs, len(prev))
		}
		log.Printf("scan: %d walk errors — skipping deletion of vanished files this pass", walkErrs)
	}
	deleteOK := walkErrs == 0
	byPath := make(map[string]repo.PathInfo, len(prev))
	for _, p := range prev {
		byPath[p.Path] = p
	}

	s.mu.Lock()
	s.scanning, s.done, s.total, s.parsed = true, 0, len(files), 0
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		s.scanning = false
		s.mu.Unlock()
	}()

	// albums whose art already exists on disk (previous scans) count as seen,
	// so art is extracted at most once per album ever, not once per scan.
	artSeen := map[string]bool{}
	if ents, err := os.ReadDir(artDir); err == nil {
		for _, e := range ents {
			if id, ok := strings.CutSuffix(e.Name(), ".jpg"); ok {
				artSeen[id] = true
			}
		}
	}

	scanAt := time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
	var (
		keep     []string
		wg       sync.WaitGroup
		resMu    sync.Mutex // guards parsed + kept + artSeen during the pool
		parsed   []repo.Track
		unparsed []string // ids of already-indexed files this pass could not read
		jobs     = make(chan fileEntry)
		workers  = runtime.NumCPU()
	)
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for fe := range jobs {
				t, ok := s.parseOne(fe, scanAt, artDir, artSeen, &resMu)
				resMu.Lock()
				if ok {
					parsed = append(parsed, t)
				} else if p, indexed := byPath[fe.rel]; indexed {
					// a file that read fine last pass and not this one (NFS
					// hiccup, a half-finished copy, a permission change) must not
					// take its row — and with it favourite, addedAt and every
					// plays join — down with it
					unparsed = append(unparsed, p.ID)
				}
				resMu.Unlock()
				s.progress()
			}
		}()
	}
	for _, fe := range files {
		if ctx.Err() != nil {
			break
		}
		if p, ok := byPath[fe.rel]; ok && p.Mtime == fe.mtime && p.Size == fe.size {
			keep = append(keep, p.ID) // unchanged: keep the row, skip the parse
			s.progress()
			continue
		}
		jobs <- fe
	}
	close(jobs)
	wg.Wait()
	if err := ctx.Err(); err != nil {
		return 0, err
	}

	// second pass so early tracks of an album whose art came from a later track
	// still get hasArt=true. Skipped rows keep their stored value; an album that
	// gains art from a new file self-corrects on the next changed-file rescan.
	for i := range parsed {
		parsed[i].HasArt = artSeen[parsed[i].AlbumID]
		keep = append(keep, parsed[i].ID)
	}
	keep = append(keep, unparsed...)
	for start := 0; start < len(parsed); start += batchSize {
		end := min(start+batchSize, len(parsed))
		if err := s.tracks.UpsertAll(ctx, parsed[start:end]); err != nil {
			return 0, err
		}
	}
	if deleteOK {
		if _, err := s.tracks.DeleteNotIn(ctx, keep); err != nil {
			return 0, err
		}
	}
	if err := s.albums.Rebuild(ctx); err != nil {
		return 0, err
	}
	s.mu.Lock()
	s.parsed = len(parsed)
	s.mu.Unlock()
	return len(keep), nil
}

func (s *Scanner) progress() {
	s.mu.Lock()
	s.done++
	done, total, cb := s.done, s.total, s.onProgress
	s.mu.Unlock()
	// throttled: one SSE frame per 25 files (plus the final one), not per file
	if cb != nil && (done%25 == 0 || done == total) {
		cb(done, total)
	}
}

func (s *Scanner) walk() (out []fileEntry, errs int) {
	filepath.WalkDir(s.musicDir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			log.Printf("scan: skip %s: %v", p, err)
			errs++
			return nil
		}
		if d.IsDir() || !exts[strings.ToLower(filepath.Ext(p))] {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			log.Printf("scan: skip %s: %v", p, err)
			return nil
		}
		rel, err := filepath.Rel(s.musicDir, p)
		if err != nil {
			return nil
		}
		out = append(out, fileEntry{abs: p, rel: rel, mtime: info.ModTime().Unix(), size: info.Size()})
		return nil
	})
	return out, errs
}

func (s *Scanner) parseOne(fe fileEntry, scanAt, artDir string, artSeen map[string]bool, artMu *sync.Mutex) (repo.Track, bool) {
	tags, err := taglib.ReadTags(fe.abs)
	if err != nil {
		log.Printf("scan: skip %s: %v", fe.abs, err)
		return repo.Track{}, false
	}
	props, err := taglib.ReadProperties(fe.abs)
	if err != nil {
		log.Printf("scan: skip %s: %v", fe.abs, err)
		return repo.Track{}, false
	}

	artist := or(first(tags, taglib.Artist), "Unknown Artist")
	// ALBUM ARTIST is the TXXX spelling some taggers use; first() takes varargs.
	// COMPILATION and the TXXX fallback only fix the displayed albumArtist (and
	// the query the enricher sends to MusicBrainz) — identity is directory-derived.
	albumArtist := first(tags, taglib.AlbumArtist, "ALBUM ARTIST")
	if albumArtist == "" && truthy(first(tags, taglib.Compilation)) {
		albumArtist = "Various Artists"
	}
	albumArtist = or(albumArtist, artist)
	album := or(first(tags, taglib.Album), unknownAlbum)
	albumID, discFromDir := albumIdentity(fe.rel, album, albumArtist)
	title := or(first(tags, taglib.Title), fe.rel)

	discNo := leadInt(first(tags, taglib.DiscNumber))
	if discNo == nil && discFromDir > 0 {
		discNo = &discFromDir // untagged multi-disc set: the CD1/CD2 folder said it
	}

	work := first(tags, taglib.Work, taglib.Grouping)
	movement := first(tags, taglib.MovementName, "MOVEMENT")
	if work == "" || movement == "" {
		if m := workRE.FindStringSubmatch(title); m != nil {
			work = or(work, strings.TrimSpace(m[1]))
			movement = or(movement, strings.TrimSpace(m[2]))
		}
	}

	if len(props.Images) > 0 {
		s.extractArt(fe.abs, albumID, artDir, artSeen, artMu)
	}

	format := strings.ToUpper(props.Format)
	if format == "" {
		format = strings.ToUpper(strings.TrimPrefix(filepath.Ext(fe.abs), "."))
	}

	return repo.Track{
		ID:              sha1Hex(fe.rel),
		Path:            fe.rel,
		Mtime:           fe.mtime,
		Size:            fe.size,
		AddedAt:         scanAt, // existing rows keep their addedAt (UpsertAll)
		Title:           title,
		Artist:          artist,
		AlbumArtist:     albumArtist,
		Album:           album,
		AlbumID:         albumID,
		TrackNo:         leadInt(first(tags, taglib.TrackNumber)),
		DiscNo:          discNo,
		Year:            yearOf(first(tags, taglib.Date, taglib.OriginalDate)),
		Genre:           strPtr(first(tags, taglib.Genre)),
		Composer:        strPtr(first(tags, taglib.Composer)),
		Conductor:       strPtr(first(tags, taglib.Conductor)),
		Work:            strPtr(work),
		Movement:        strPtr(movement),
		MBAlbumID:       strPtr(first(tags, taglib.MusicBrainzAlbumID)),
		MBRecordingID:   strPtr(first(tags, taglib.MusicBrainzTrackID)),
		MBAlbumArtistID: strPtr(first(tags, taglib.MusicBrainzAlbumArtistID)),
		Duration:        durPtr(props.Length),
		Format:          format,
		SampleRate:      intPtr(int(props.SampleRate)),
		BitsPerSample:   intPtr(int(props.BitDepth)),
		Channels:        intPtr(int(props.Channels)),
		Lossless:        isLossless(props.Format, props.InnerCodec),
		HasArt:          false, // set in the post-pool pass
	}, true
}

// extractArt writes the embedded front cover to artDir/<albumId>.jpg once per
// album (legacy always used .jpg regardless of image bytes; clients sniff).
func (s *Scanner) extractArt(abs, albumID, artDir string, artSeen map[string]bool, artMu *sync.Mutex) {
	artMu.Lock()
	if artSeen[albumID] {
		artMu.Unlock()
		return
	}
	artSeen[albumID] = true // claim before the slow read so no other worker duplicates it
	artMu.Unlock()

	img, err := taglib.ReadImage(abs)
	if err == nil && len(img) > 0 {
		err = os.WriteFile(filepath.Join(artDir, albumID+".jpg"), img, 0o644)
	}
	if err != nil || len(img) == 0 {
		artMu.Lock()
		delete(artSeen, albumID)
		artMu.Unlock()
		if err != nil {
			log.Printf("scan: skip art %s: %v", albumID, err)
		}
	}
}

// albumIdentity derives the album id from where the file lives, with the ALBUM
// tag only as a tiebreak for several albums dumped in one folder. Pure function
// of (rel path, this file's own tags) — never of its neighbours, because the
// scanner skips unchanged files and a directory-wide rule would only ever see
// the parsed subset, so adding one file could silently re-key a whole folder.
// Returns the id and the disc number recovered from a CD1/Disc 2 folder (0 = none).
func albumIdentity(rel, album, albumArtist string) (id string, discFromDir int) {
	dir := filepath.ToSlash(filepath.Dir(rel))
	if dir == "." {
		dir = ""
	}
	if dir != "" {
		// fold at most once, and only when a parent segment survives — so
		// MUSIC_DIR/CD1/*.flac keeps its own group rather than dumping into the
		// root pool. ponytail: one level; recurse if a real library ever nests
		// disc folders.
		if m := discSegRE.FindStringSubmatch(path.Base(dir)); m != nil && strings.Contains(dir, "/") {
			discFromDir = discNum(m[1])
			if dir = path.Dir(dir); dir == "." {
				dir = ""
			}
		}
	}
	dirKey := strings.ToLower(dir)
	// ponytail: no dash/quote folding, no NFKC — dirKey already separates a
	// remaster from its original, and every normaliser addition is a permanent
	// rekey ratchet.
	albumKey := strings.ToLower(strings.Join(strings.Fields(discSuffixRE.ReplaceAllString(album, "")), " "))
	// the artist fallback leaves the hash whenever the directory or the ALBUM tag
	// can do the separating — that removal is what stops one compilation with a
	// different ARTIST per track from splitting into one album per performer. It
	// stays at library root (no directory) and for untagged files (no album key),
	// where dropping it would collapse a folder of unrelated loose singles into
	// one album.
	aaKey := ""
	if dirKey == "" || albumKey == "" || albumKey == strings.ToLower(unknownAlbum) {
		aaKey = strings.ToLower(albumArtist)
	}
	return sha1Hex(dirKey + "\x00" + albumKey + "\x00" + aaKey), discFromDir
}

// AlbumID exposes the grouping rule to the one-shot migration-007 remap, which
// recomputes stored ids from the columns they derive from rather than
// re-parsing the library. Same function the scanner calls, so the result is
// exactly what the next scan would write.
func AlbumID(relPath, album, albumArtist string) (id string, discFromDir int) {
	return albumIdentity(relPath, album, albumArtist)
}

// discNum parses the numeral of a disc folder: "2", "02", "II" or "two".
func discNum(s string) int {
	if n, err := strconv.Atoi(s); err == nil {
		return n
	}
	return discWords[strings.ToLower(s)]
}

// truthy reads a boolean-ish tag value (iTunes writes "1", some taggers "true").
func truthy(v string) bool {
	return v == "1" || strings.EqualFold(v, "true") || strings.EqualFold(v, "yes")
}

func sha1Hex(s string) string {
	h := sha1.Sum([]byte(s))
	return hex.EncodeToString(h[:])
}

// first returns the first non-empty value across keys, in order.
func first(tags map[string][]string, keys ...string) string {
	for _, k := range keys {
		if vs := tags[k]; len(vs) > 0 && vs[0] != "" {
			return vs[0]
		}
	}
	return ""
}

func or(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

func strPtr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func intPtr(n int) *int {
	if n == 0 {
		return nil
	}
	return &n
}

func durPtr(d time.Duration) *float64 {
	if d == 0 {
		return nil
	}
	f := d.Seconds()
	return &f
}

// leadInt parses the leading digit run, handling "3/12"-style TRACKNUMBER.
func leadInt(s string) *int {
	n, digits := 0, 0
	for _, r := range s {
		if r < '0' || r > '9' {
			break
		}
		n, digits = n*10+int(r-'0'), digits+1
	}
	if digits == 0 || n == 0 {
		return nil
	}
	return &n
}

// yearOf takes the first 4 digits of a DATE value ("2021", "2021-03-01", ...).
func yearOf(s string) *int {
	for i := 0; i+4 <= len(s); i++ {
		if isDigits(s[i : i+4]) {
			var n int
			fmt.Sscanf(s[i:i+4], "%d", &n)
			return intPtr(n)
		}
	}
	return nil
}

func isDigits(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}
