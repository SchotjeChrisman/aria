package scanner

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"go.senan.xyz/taglib"

	"aria/internal/db"
	"aria/internal/repo"
)

// fixtureTree copies test-music/cd.flac to each rel path under a fresh music
// dir and stamps the given tags on it, so a test can build any on-disk layout.
// taglib.Clear wipes the source file's own ARTIST/ALBUM so nothing leaks
// between cases; a key left out of the map is absent on disk.
func fixtureTree(t *testing.T, files map[string]map[string][]string) string {
	t.Helper()
	src, err := filepath.Abs("../../../test-music/cd.flac")
	if err != nil {
		t.Fatal(err)
	}
	blob, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	for rel, tags := range files {
		dst := filepath.Join(dir, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(dst, blob, 0o644); err != nil {
			t.Fatal(err)
		}
		if err := taglib.WriteTags(dst, tags, taglib.Clear); err != nil {
			t.Fatalf("write tags %s: %v", rel, err)
		}
	}
	return dir
}

// albumIDs returns rel path -> albumId for every scanned track.
func albumIDs(t *testing.T, ctx context.Context, tracks *repo.Tracks) map[string]string {
	t.Helper()
	ts, err := tracks.ListAll(ctx)
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]string{}
	for _, tr := range ts {
		out[filepath.ToSlash(tr.Path)] = tr.AlbumID
	}
	return out
}

// The two reported grouping failures, on disk: one folder is one album however
// its tracks are tagged, and two folders are two albums however identically.
func TestScanGroupsByDirectory(t *testing.T) {
	const brahms = "Essential Brahms, volume 1"
	musicDir := fixtureTree(t, map[string]map[string][]string{
		// no ALBUMARTIST and a different ARTIST per work: split four ways before
		"Brahms/01.flac": {taglib.Title: {"A"}, taglib.Artist: {"Kremer"}, taglib.Album: {brahms}},
		"Brahms/02.flac": {taglib.Title: {"B"}, taglib.Artist: {"Argerich"}, taglib.Album: {brahms}},
		"Brahms/03.flac": {taglib.Title: {"C"}, taglib.Artist: {"Zimerman"}, taglib.Album: {brahms},
			taglib.Compilation: {"1"}},
		"Brahms/04.flac": {taglib.Title: {"D"}, taglib.Artist: {"Perahia"}, taglib.Album: {brahms}},
		// byte-identical tags, two different nights: merged into one before
		"Knopfler/Amsterdam/01.flac": {taglib.Title: {"Why Aye Man"}, taglib.Artist: {"Mark Knopfler"},
			taglib.Album: {"Down the Road Wherever Tour"}},
		"Knopfler/Madrid/01.flac": {taglib.Title: {"Why Aye Man"}, taglib.Artist: {"Mark Knopfler"},
			taglib.Album: {"Down the Road Wherever Tour"}},
	})
	dataDir := t.TempDir()
	d, err := db.Open(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	tracks := repo.NewTracks(d)
	s := New(musicDir, dataDir, tracks, repo.NewAlbums(d), nil)
	ctx := context.Background()
	if _, err := s.Scan(ctx); err != nil {
		t.Fatal(err)
	}
	ids := albumIDs(t, ctx, tracks)

	want := ids["Brahms/01.flac"]
	distinct := map[string]bool{}
	for _, f := range []string{"Brahms/01.flac", "Brahms/02.flac", "Brahms/03.flac", "Brahms/04.flac"} {
		if ids[f] != want {
			t.Errorf("%s albumId = %s, want %s (same folder)", f, ids[f], want)
		}
		distinct[ids[f]] = true
	}
	// a regression that splits into two rather than four must fail too
	if len(distinct) != 1 {
		t.Errorf("distinct Brahms albumIds = %d, want 1", len(distinct))
	}
	if ids["Knopfler/Amsterdam/01.flac"] == ids["Knopfler/Madrid/01.flac"] {
		t.Errorf("two concert folders share albumId %s, want two albums", ids["Knopfler/Amsterdam/01.flac"])
	}
	// api.albumIDRe is ^[0-9a-f]{40}$ and gates all art and both booklet routes
	for f, id := range ids {
		if len(id) != 40 || id != lower(id) {
			t.Errorf("%s albumId = %q, want 40 lowercase hex", f, id)
		}
	}

	// COMPILATION feeds the displayed album artist, not identity
	for _, tc := range []struct{ file, want string }{
		{"Brahms/03.flac", "Various Artists"},
		{"Brahms/01.flac", "Kremer"},
	} {
		tr, err := tracks.ByID(ctx, sha1Hex(tc.file))
		if err != nil || tr == nil {
			t.Fatalf("%s: %v", tc.file, err)
		}
		if tr.AlbumArtist != tc.want {
			t.Errorf("%s albumArtist = %q, want %q", tc.file, tr.AlbumArtist, tc.want)
		}
	}

	// scanning writes nothing back to the fixtures, so a rescan parses nothing
	if _, err := s.Scan(ctx); err != nil {
		t.Fatal(err)
	}
	if s.parsed != 0 {
		t.Errorf("rescan parsed %d files, want 0", s.parsed)
	}
}

// The grouping rule itself: disk layout decides, the ALBUM tag only separates
// albums sharing a folder, and "Disc"-the-band must not fold into its parent.
func TestAlbumIdentity(t *testing.T) {
	id := func(rel, album, albumArtist string) string {
		s, _ := albumIdentity(rel, album, albumArtist)
		return s
	}
	cases := []struct {
		name, rel, album string
		sameAs           string // rel path of a file tagged ALBUM=X that must share the id
		differsFrom      string // ... and one that must not
		otherAlbum       string // the ALBUM tag of differsFrom (default "X")
		wantDisc         int
	}{
		{name: "disc folders fold", rel: "Box/CD1/01.flac", album: "X", sameAs: "Box/CD2/01.flac", wantDisc: 1},
		{name: "disc folder disc no", rel: "Box/CD2/01.flac", album: "X", wantDisc: 2},
		// the folder fold alone is undone by the album key without discSuffixRE
		{name: "disc suffix in tag", rel: "Box/CD1/01.flac", album: "X (Disc 1)", sameAs: "Box/CD2/01.flac", wantDisc: 1},
		{name: "flat two-disc folder", rel: "Set/01.flac", album: "X (Disc 1)", sameAs: "Set/02.flac"},
		{name: "band called Disc", rel: "Disc/01.flac", album: "X", differsFrom: "01.flac"},
		{name: "Discography", rel: "Discography/01.flac", album: "X", differsFrom: "01.flac"},
		{name: "Disco", rel: "Disco/01.flac", album: "X", differsFrom: "01.flac"},
		{name: "CD Singles", rel: "CD Singles/01.flac", album: "X", differsFrom: "01.flac"},
		{name: "Disc Jockey", rel: "Disc Jockey/01.flac", album: "X", differsFrom: "01.flac"},
		// the roman whitelist, not [ivxlcdm]{1,4}
		{name: "Disc Mix", rel: "Disc Mix/01.flac", album: "X", differsFrom: "01.flac"},
		// a disc folder directly under MUSIC_DIR keeps its own group
		{name: "root disc folder", rel: "CD1/01.flac", album: "X", differsFrom: "01.flac"},
		{name: "nested disc folders fold once", rel: "Box/CD1/Disc 1/01.flac", album: "X",
			differsFrom: "Box/01.flac", wantDisc: 1},
		{name: "two albums in one folder", rel: "Folder/a.flac", album: "X",
			differsFrom: "Folder/b.flac", otherAlbum: "Y"},
		{name: "whitespace collapses", rel: "Folder/a.flac", album: "  X  ", sameAs: "Folder/b.flac"},
		{name: "CD 1", rel: "Box/CD 1/01.flac", album: "X", sameAs: "Box/CD2/01.flac", wantDisc: 1},
		{name: "CD-1", rel: "Box/CD-1/01.flac", album: "X", sameAs: "Box/CD2/01.flac", wantDisc: 1},
		{name: "cd01", rel: "Box/cd01/01.flac", album: "X", sameAs: "Box/CD2/01.flac", wantDisc: 1},
		{name: "Disc One", rel: "Box/Disc One/01.flac", album: "X", sameAs: "Box/CD2/01.flac", wantDisc: 1},
		{name: "Disc II", rel: "Box/Disc II/01.flac", album: "X", sameAs: "Box/CD2/01.flac", wantDisc: 2},
		{name: "CD1 - Live in Paris", rel: "Box/CD1 - Live in Paris/01.flac", album: "X",
			sameAs: "Box/CD2/01.flac", wantDisc: 1},
		{name: "Disc 1 (Remastered)", rel: "Box/Disc 1 (Remastered)/01.flac", album: "X",
			sameAs: "Box/CD2/01.flac", wantDisc: 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, disc := albumIdentity(tc.rel, tc.album, "AA")
			if disc != tc.wantDisc {
				t.Errorf("discFromDir = %d, want %d", disc, tc.wantDisc)
			}
			if tc.sameAs != "" && got != id(tc.sameAs, "X", "AA") {
				t.Errorf("%s albumId = %s, want same as %s", tc.rel, got, tc.sameAs)
			}
			other := tc.otherAlbum
			if other == "" {
				other = "X"
			}
			if tc.differsFrom != "" && got == id(tc.differsFrom, other, "AA") {
				t.Errorf("%s albumId = %s, want different from %s", tc.rel, got, tc.differsFrom)
			}
		})
	}

	// one level only: Box/CD1/Disc 1 keys on Box/CD1, not on Box
	if got := id("Box/CD1/Disc 1/01.flac", "X", "AA"); got != sha1Hex("box/cd1\x00x\x00") {
		t.Errorf("nested disc fold albumId = %s, want key %q", got, "box/cd1\x00x\x00")
	}

	// at library root there is no directory, so the album-artist tag partitions
	if id("a.flac", "X", "AA") == id("b.flac", "X", "BB") {
		t.Error("root albumId ignores albumArtist, want a partition per artist")
	}
	if id("a.flac", "X", "AA") != id("b.flac", "X", "AA") {
		t.Error("root albumId differs for one album+artist, want one album")
	}

	// ... and with no ALBUM tag the directory is the only thing left, so a folder
	// of unrelated loose singles needs the artist back or all of it collapses
	// into one album
	if id("Singles/a.flac", unknownAlbum, "AA") == id("Singles/b.flac", unknownAlbum, "BB") {
		t.Error("untagged tracks in one folder ignore albumArtist, want a partition per artist")
	}
	if id("Singles/a.flac", unknownAlbum, "AA") != id("Singles/b.flac", unknownAlbum, "AA") {
		t.Error("untagged tracks by one artist in one folder split, want one album")
	}
	// a real ALBUM tag still overrides the artist, which is the compilation fix
	if id("Brahms/a.flac", "X", "AA") != id("Brahms/b.flac", "X", "BB") {
		t.Error("tagged tracks in one folder split by artist, want one album")
	}
}

// A file that read fine one pass and not the next (an NFS hiccup, a
// half-finished copy, a permission change) must keep its row: that row carries
// favourite, addedAt and every plays join, and the file is usually readable
// again on the next scan.
func TestScanKeepsRowWhenReparseFails(t *testing.T) {
	musicDir := fixtureTree(t, map[string]map[string][]string{
		"A/01.flac": {taglib.Title: {"One"}, taglib.Artist: {"X"}, taglib.Album: {"Al"}},
		"A/02.flac": {taglib.Title: {"Two"}, taglib.Artist: {"X"}, taglib.Album: {"Al"}},
	})
	dataDir := t.TempDir()
	d, err := db.Open(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	tracks := repo.NewTracks(d)
	s := New(musicDir, dataDir, tracks, repo.NewAlbums(d), nil)
	ctx := context.Background()
	if _, err := s.Scan(ctx); err != nil {
		t.Fatal(err)
	}
	doomed := sha1Hex("A/02.flac")
	if err := tracks.SetFavourite(ctx, doomed, true); err != nil {
		t.Fatal(err)
	}

	// changed size+mtime, so it is re-parsed rather than skipped — and unreadable
	if err := os.WriteFile(filepath.Join(musicDir, "A", "02.flac"), []byte("half a copy"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Scan(ctx); err != nil {
		t.Fatal(err)
	}
	tr, err := tracks.ByID(ctx, doomed)
	if err != nil {
		t.Fatal(err)
	}
	if tr == nil {
		t.Fatal("an unreadable file cost its track row, and favourite/addedAt/plays with it")
	}
	if !tr.Favourite {
		t.Error("favourite lost across a failed re-parse")
	}
}

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
			// at library root there is no directory to key on, so identity falls
			// back to the album-artist partition — and with no albumartist tag,
			// to the artist
			wantAlbumID := sha1Hex("\x00" + lower(tc.album) + "\x00" + lower(tc.artist))
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

// The exts map is the ONLY gate on coverage — taglib parses whatever the walk
// hands it — and nothing else asserts it, so a typo'd extension would ship
// silently. walk() only stats, so zero-byte files are enough here; the
// rejections matter as much as the acceptances (see the exts comment for why
// .dff and the tracker modules stay out).
func TestWalkExtensionGate(t *testing.T) {
	cases := map[string]bool{
		"a.flac": true, "a.mp3": true, "a.m4a": true, "a.ogg": true, "a.opus": true,
		"a.wav": true, "a.aiff": true, "a.ape": true, "a.wv": true, "a.dsf": true,
		"a.aif": true, "a.aifc": true, "a.afc": true, "a.oga": true, "a.spx": true,
		"a.m4b": true, "a.wma": true, "a.tta": true, "a.shn": true, "a.mpc": true,
		"A.FLAC": true, "sub/b.WmA": true, // extension match is case-insensitive
		"a.dff": false, "a.dsdiff": false, // taglib tags them, ffmpeg can't demux them
		"a.mod": false, "a.it": false, "a.xm": false, // need libopenmpt
		"a.mp4": false, "a.m4v": false, "a.m4p": false, "a.m4r": false, // video/DRM/ringtone
		"a.aac": false, "a.mka": false, "a.caf": false, "a.w64": false,
		"a.jpg": false, "a.pdf": false, "a.txt": false, "noext": false,
	}
	dir := t.TempDir()
	for name := range cases {
		p := filepath.Join(dir, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	got := map[string]bool{}
	files, _ := (&Scanner{musicDir: dir}).walk()
	for _, fe := range files {
		got[filepath.ToSlash(fe.rel)] = true
	}
	for name, want := range cases {
		if got[name] != want {
			t.Errorf("walk %s: indexed=%v, want %v", name, got[name], want)
		}
	}
}

// Lossless is not a property of the container for wav/aiff/mp4/asf — each can
// hold either payload, and taglib hands us the codec that decides it.
func TestIsLossless(t *testing.T) {
	cases := []struct {
		format, codec string
		want          bool
	}{
		{"flac", "", true}, // also Ogg FLAC: taglib reports it as plain "flac"
		{"ape", "", true},
		{"wavpack", "", true},
		{"dsf", "", true},
		{"tta", "", true},     // was unreachable: named here but rejected by exts
		{"shorten", "", true}, // ditto
		{"wav", "pcm", true},
		{"wav", "", false}, // ADPCM etc: taglib sets pcm only for wFormatTag 1/3
		{"aiff", "pcm", true},
		{"aiff", "", false}, // compressed AIFF-C
		{"mp4", "alac", true},
		{"mp4", "aac", false},
		{"asf", "wma9lossless", true},
		{"asf", "wma2", false},
		{"asf", "wma9pro", false},
		{"ogg", "vorbis", false},
		{"ogg", "opus", false},
		{"ogg", "speex", false},
		{"mpeg", "", false},
		{"musepack", "", false},
		{"dsdiff", "", false}, // deleted from losslessFmt: unplayable, never indexed
		{"", "", false},
	}
	for _, c := range cases {
		if got := isLossless(c.format, c.codec); got != c.want {
			t.Errorf("isLossless(%q, %q) = %v, want %v", c.format, c.codec, got, c.want)
		}
	}
}
