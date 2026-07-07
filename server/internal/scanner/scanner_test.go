package scanner

import (
	"context"
	"path/filepath"
	"testing"

	"aria/internal/db"
	"aria/internal/repo"
)

func TestScan(t *testing.T) {
	musicDir, err := filepath.Abs("../../../test-music")
	if err != nil {
		t.Fatal(err)
	}
	dataDir := t.TempDir()
	d, err := db.Open(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	tracks := repo.NewTracks(d)
	s := New(musicDir, dataDir, tracks, repo.NewAlbums(d), nil)
	ctx := context.Background()

	n, err := s.Scan(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if n != 3 {
		t.Fatalf("scan count = %d, want 3", n)
	}

	tests := []struct {
		file, title, artist, album, format string
		sampleRate, bits                   int // 0 = expect nil
		lossless                           bool
	}{
		{"hires.flac", "Hi Res Sine", "Artist One", "Album Alpha", "FLAC", 96000, 24, true},
		{"cd.flac", "CD Sine", "Artist Two", "Album Beta", "FLAC", 44100, 16, true},
		{"lossy.mp3", "Lossy Sine", "Artist Three", "Album Gamma", "MPEG", 44100, 0, false},
	}
	for _, tc := range tests {
		t.Run(tc.file, func(t *testing.T) {
			// id stability: sha1 of MUSIC_DIR-relative path
			id := sha1Hex(tc.file)
			tr, err := tracks.ByID(ctx, id)
			if err != nil {
				t.Fatal(err)
			}
			if tr == nil {
				t.Fatalf("track %s (%s) not found", tc.file, id)
			}
			if tr.Title != tc.title || tr.Artist != tc.artist || tr.Album != tc.album {
				t.Errorf("got %q/%q/%q, want %q/%q/%q", tr.Title, tr.Artist, tr.Album, tc.title, tc.artist, tc.album)
			}
			// no albumartist tag: falls back to artist, lowercased into the albumId
			wantAlbumID := sha1Hex(toLowerPair(tc.artist, tc.album))
			if tr.AlbumID != wantAlbumID {
				t.Errorf("albumId = %s, want %s", tr.AlbumID, wantAlbumID)
			}
			if tr.Format != tc.format {
				t.Errorf("format = %q, want %q", tr.Format, tc.format)
			}
			if got := ptrVal(tr.SampleRate); got != tc.sampleRate {
				t.Errorf("sampleRate = %d, want %d", got, tc.sampleRate)
			}
			if got := ptrVal(tr.BitsPerSample); got != tc.bits {
				t.Errorf("bitsPerSample = %d, want %d", got, tc.bits)
			}
			if tr.Lossless != tc.lossless {
				t.Errorf("lossless = %v, want %v", tr.Lossless, tc.lossless)
			}
			if ptrVal(tr.TrackNo) != 1 {
				t.Errorf("trackNo = %d, want 1", ptrVal(tr.TrackNo))
			}
			if tr.Duration == nil || *tr.Duration <= 0 {
				t.Errorf("duration = %v, want > 0", tr.Duration)
			}
		})
	}

	first, err := tracks.ByID(ctx, sha1Hex("hires.flac"))
	if err != nil || first == nil {
		t.Fatalf("hires reread: %v", err)
	}

	// second scan: unchanged mtime+size means every file is skipped, not parsed
	n, err = s.Scan(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if n != 3 {
		t.Errorf("rescan count = %d, want 3", n)
	}
	if s.parsed != 0 {
		t.Errorf("rescan parsed %d files, want 0", s.parsed)
	}
	again, err := tracks.ByID(ctx, sha1Hex("hires.flac"))
	if err != nil || again == nil {
		t.Fatalf("hires after rescan: %v", err)
	}
	if again.AddedAt != first.AddedAt {
		t.Errorf("addedAt changed across rescan: %q -> %q", first.AddedAt, again.AddedAt)
	}
}

// A vanished/empty music dir must never wipe an existing library.
func TestScanRefusesToWipeLibrary(t *testing.T) {
	musicDir, err := filepath.Abs("../../../test-music")
	if err != nil {
		t.Fatal(err)
	}
	dataDir := t.TempDir()
	d, err := db.Open(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	tracks := repo.NewTracks(d)
	albums := repo.NewAlbums(d)
	ctx := context.Background()

	if _, err := New(musicDir, dataDir, tracks, albums, nil).Scan(ctx); err != nil {
		t.Fatal(err)
	}

	for _, dir := range []string{filepath.Join(t.TempDir(), "missing"), t.TempDir()} {
		if _, err := New(dir, dataDir, tracks, albums, nil).Scan(ctx); err == nil {
			t.Errorf("scan of %s: want error, got nil", dir)
		}
		if n, err := tracks.Count(ctx); err != nil || n != 3 {
			t.Fatalf("library after scan of %s: %d tracks (err %v), want 3", dir, n, err)
		}
	}
}

func toLowerPair(albumArtist, album string) string {
	return lower(albumArtist) + "\x00" + lower(album)
}

func lower(s string) string {
	b := []byte(s)
	for i := range b {
		if b[i] >= 'A' && b[i] <= 'Z' {
			b[i] += 'a' - 'A'
		}
	}
	return string(b)
}

func ptrVal(p *int) int {
	if p == nil {
		return 0
	}
	return *p
}
