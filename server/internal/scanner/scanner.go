// Package scanner walks MUSIC_DIR, parses tags concurrently via go-taglib,
// and upserts the tracks table incrementally (unchanged mtime+size = skip).
package scanner

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"

	"go.senan.xyz/taglib"

	"aria/internal/repo"
)

var exts = map[string]bool{
	".flac": true, ".mp3": true, ".m4a": true, ".ogg": true, ".opus": true,
	".wav": true, ".aiff": true, ".ape": true, ".wv": true, ".dsf": true,
}

// taglib format names that are always lossless; mp4 needs the alac codec check.
var losslessFmt = map[string]bool{
	"flac": true, "wav": true, "aiff": true, "ape": true, "wavpack": true,
	"dsf": true, "dsdiff": true, "tta": true, "shorten": true,
}

// "Work: Movement" / "Work - Movement" where the movement starts with a roman
// or arabic numeral. Same pattern as scanner.js; explicit tags win when present.
var workRE = regexp.MustCompile(`^(.+)(?::|\s[-–—])\s+((?:[IVXLCDM]+|No\.?\s*\d+|\d+)[.):]\s*.+)$`)

const batchSize = 500

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

type fileEntry struct {
	abs, rel    string
	mtime, size int64
}

// Scan walks the library, re-parses new/changed files across NumCPU workers,
// deletes rows for vanished files, rebuilds albums, and returns the track count.
func (s *Scanner) Scan(ctx context.Context) (int, error) {
	s.runMu.Lock()
	defer s.runMu.Unlock()

	artDir := filepath.Join(s.dataDir, "art")
	if err := os.MkdirAll(artDir, 0o755); err != nil {
		return 0, err
	}

	files := s.walk()
	prev, err := s.tracks.ListPathInfo(ctx)
	if err != nil {
		return 0, err
	}
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
		keep    []string
		wg      sync.WaitGroup
		resMu   sync.Mutex // guards parsed + artSeen during the pool
		parsed  []repo.Track
		jobs    = make(chan fileEntry)
		workers = runtime.NumCPU()
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
	for start := 0; start < len(parsed); start += batchSize {
		end := min(start+batchSize, len(parsed))
		if err := s.tracks.UpsertAll(ctx, parsed[start:end]); err != nil {
			return 0, err
		}
	}
	if _, err := s.tracks.DeleteNotIn(ctx, keep); err != nil {
		return 0, err
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
	if cb != nil {
		cb(done, total)
	}
}

func (s *Scanner) walk() []fileEntry {
	var out []fileEntry
	filepath.WalkDir(s.musicDir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			log.Printf("scan: skip %s: %v", p, err)
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
	return out
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
	albumArtist := or(first(tags, taglib.AlbumArtist), artist)
	album := or(first(tags, taglib.Album), "Unknown Album")
	albumID := sha1Hex(strings.ToLower(albumArtist) + "\x00" + strings.ToLower(album))
	title := or(first(tags, taglib.Title), fe.rel)

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
		DiscNo:          leadInt(first(tags, taglib.DiscNumber)),
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
		Lossless:        losslessFmt[props.Format] || (props.Format == "mp4" && props.InnerCodec == "alac"),
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
