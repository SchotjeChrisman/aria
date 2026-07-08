package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"aria/internal/config"
	"aria/internal/db"
	"aria/internal/repo"
)

// writeStubFFmpeg drops a tiny POSIX-sh "ffmpeg" that appends one byte to
// sentinel per invocation and writes a fixed blob to its last arg (the output
// path). No real encoder runs in CI.
func writeStubFFmpeg(t *testing.T, sentinel string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "ffmpeg")
	script := "#!/bin/sh\n" +
		"printf x >> '" + sentinel + "'\n" +
		"for a in \"$@\"; do out=\"$a\"; done\n" +
		"printf 'FAKEOPUS' > \"$out\"\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// streamDeps builds Deps with one track "t1" → <musicDir>/song.flac.
func streamDeps(t *testing.T, body string) *Deps {
	t.Helper()
	d, err := db.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	cfg := config.Config{
		MusicDir:         t.TempDir(),
		DataDir:          t.TempDir(),
		TranscodeCacheMB: 5000,
	}
	if err := os.WriteFile(filepath.Join(cfg.MusicDir, "song.flac"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	deps := NewDeps(d, cfg, "test")
	if err := deps.Tracks.UpsertAll(context.Background(), []repo.Track{{
		ID: "t1", Path: "song.flac", Title: "One", AlbumID: "al1",
		AddedAt: "2026-01-01T00:00:00.000Z",
	}}); err != nil {
		t.Fatal(err)
	}
	return deps
}

func get(t *testing.T, deps *Deps, url string, hdr map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", url, nil)
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	New(deps).ServeHTTP(rec, req)
	return rec
}

// original / empty / unknown tier all serve the source bytes verbatim.
func TestStreamOriginalPassthrough(t *testing.T) {
	deps := streamDeps(t, "SOURCEBYTES")
	for _, u := range []string{"/api/stream/t1", "/api/stream/t1?tier=original", "/api/stream/t1?tier=bogus"} {
		rec := get(t, deps, u, nil)
		if rec.Code != 200 {
			t.Fatalf("%s = %d: %s", u, rec.Code, rec.Body.String())
		}
		if rec.Body.String() != "SOURCEBYTES" {
			t.Fatalf("%s body = %q", u, rec.Body.String())
		}
		if ct := rec.Header().Get("Content-Type"); ct != "audio/flac" {
			t.Fatalf("%s content-type = %q", u, ct)
		}
	}
}

// high tier: transcodes once, caches under the expected name, reuses on the
// second request without re-invoking ffmpeg.
func TestStreamTranscodeCacheAndReuse(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("stub ffmpeg is a POSIX sh script")
	}
	deps := streamDeps(t, "SOURCEBYTES")
	sentinel := filepath.Join(t.TempDir(), "hits")
	deps.Cfg.FFmpegPath = writeStubFFmpeg(t, sentinel)
	deps.CanTranscode = true

	rec := get(t, deps, "/api/stream/t1?tier=high", nil)
	if rec.Code != 200 {
		t.Fatalf("high = %d: %s", rec.Code, rec.Body.String())
	}
	if rec.Body.String() != "FAKEOPUS" {
		t.Fatalf("high body = %q", rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "audio/ogg" {
		t.Fatalf("content-type = %q", ct)
	}

	// expected cache filename from source mtime/size
	src, _ := os.Stat(filepath.Join(deps.Cfg.MusicDir, "song.flac"))
	want := fmt.Sprintf("t1__high__%x-%x.opus", src.ModTime().UnixNano(), src.Size())
	if _, err := os.Stat(filepath.Join(deps.Cfg.DataDir, "tc", want)); err != nil {
		t.Fatalf("cache file %s missing: %v", want, err)
	}
	if hits := invocations(t, sentinel); hits != 1 {
		t.Fatalf("ffmpeg invocations = %d, want 1", hits)
	}

	// second request: cache hit, no re-invoke
	rec2 := get(t, deps, "/api/stream/t1?tier=high", nil)
	if rec2.Code != 200 || rec2.Body.String() != "FAKEOPUS" {
		t.Fatalf("reuse = %d %q", rec2.Code, rec2.Body.String())
	}
	if hits := invocations(t, sentinel); hits != 1 {
		t.Fatalf("ffmpeg invocations after reuse = %d, want 1", hits)
	}
}

// Range request on the cached file → 206 + Content-Range.
func TestStreamTranscodeRange(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("stub ffmpeg is a POSIX sh script")
	}
	deps := streamDeps(t, "SOURCEBYTES")
	deps.Cfg.FFmpegPath = writeStubFFmpeg(t, filepath.Join(t.TempDir(), "hits"))
	deps.CanTranscode = true
	// prime the cache
	get(t, deps, "/api/stream/t1?tier=low", nil)

	rec := get(t, deps, "/api/stream/t1?tier=low", map[string]string{"Range": "bytes=0-3"})
	if rec.Code != 206 {
		t.Fatalf("range = %d, want 206", rec.Code)
	}
	if cr := rec.Header().Get("Content-Range"); cr != "bytes 0-3/8" {
		t.Fatalf("content-range = %q", cr)
	}
	if rec.Body.String() != "FAKE" {
		t.Fatalf("range body = %q", rec.Body.String())
	}
}

// No ffmpeg → high/low return 501, original still works.
func TestStreamTranscodeUnavailable(t *testing.T) {
	deps := streamDeps(t, "SOURCEBYTES")
	deps.CanTranscode = false
	if rec := get(t, deps, "/api/stream/t1?tier=high", nil); rec.Code != 501 {
		t.Fatalf("high w/o ffmpeg = %d, want 501", rec.Code)
	}
	if rec := get(t, deps, "/api/stream/t1", nil); rec.Code != 200 {
		t.Fatalf("original w/o ffmpeg = %d, want 200", rec.Code)
	}
}

// /api/status reports the transcode capability flag.
func TestStatusTranscodeFlag(t *testing.T) {
	deps := streamDeps(t, "x")
	deps.CanTranscode = true
	rec := get(t, deps, "/api/status", nil)
	if rec.Code != 200 {
		t.Fatalf("status = %d", rec.Code)
	}
	var s map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &s); err != nil {
		t.Fatal(err)
	}
	if s["transcode"] != true {
		t.Fatalf("transcode = %v, want true", s["transcode"])
	}
}

// Changing the source (mtime/size) yields a fresh cache filename.
func TestStreamTranscodeStaleInvalidation(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("stub ffmpeg is a POSIX sh script")
	}
	deps := streamDeps(t, "SOURCEBYTES")
	deps.Cfg.FFmpegPath = writeStubFFmpeg(t, filepath.Join(t.TempDir(), "hits"))
	deps.CanTranscode = true
	tcDir := filepath.Join(deps.Cfg.DataDir, "tc")

	get(t, deps, "/api/stream/t1?tier=high", nil)
	first := opusFiles(t, tcDir)
	if len(first) != 1 {
		t.Fatalf("first cache = %v", first)
	}

	// rewrite source with a different size → different key
	if err := os.WriteFile(filepath.Join(deps.Cfg.MusicDir, "song.flac"), []byte("DIFFERENT-LONGER-BYTES"), 0o644); err != nil {
		t.Fatal(err)
	}
	get(t, deps, "/api/stream/t1?tier=high", nil)
	after := opusFiles(t, tcDir)
	if len(after) != 2 {
		t.Fatalf("after stale = %v, want 2 distinct cache files", after)
	}
}

func invocations(t *testing.T, sentinel string) int {
	t.Helper()
	b, err := os.ReadFile(sentinel)
	if err != nil {
		return 0
	}
	return len(b)
}

func opusFiles(t *testing.T, dir string) []string {
	t.Helper()
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range ents {
		if filepath.Ext(e.Name()) == ".opus" {
			out = append(out, e.Name())
		}
	}
	return out
}
