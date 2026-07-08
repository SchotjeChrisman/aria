package api

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

func init() { register(registerStream) }

// original tier = the file's bits, byte-for-byte, with Range support via
// http.ServeContent. high/low tiers transcode to an on-disk Opus cache and
// serve THAT with the same ServeContent call (keeps Range/304/sendfile).
var streamMIME = map[string]string{
	".flac": "audio/flac",
	".mp3":  "audio/mpeg",
	".m4a":  "audio/mp4",
	".ogg":  "audio/ogg",
	".opus": "audio/ogg", // opus-in-ogg container
	".wav":  "audio/wav",
	".aiff": "audio/aiff",
	".ape":  "audio/x-ape",
	".wv":   "audio/x-wavpack",
	".dsf":  "audio/x-dsf",
}

func registerStream(mux *http.ServeMux, d *Deps) {
	// ids resolved only via the DB — the client never supplies a path
	mux.HandleFunc("GET /api/stream/{id}", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		t, err := d.Tracks.ByID(r.Context(), id)
		if err != nil || t == nil {
			notFound(w)
			return
		}
		p := filepath.Join(d.Cfg.MusicDir, filepath.FromSlash(t.Path))
		switch r.URL.Query().Get("tier") {
		case "high":
			serveTranscoded(w, r, d, id, p, "high", "192k")
		case "low":
			serveTranscoded(w, r, d, id, p, "low", "96k")
		default:
			// "" / "original" / anything unknown → bit-perfect passthrough (lenient)
			serveOriginal(w, r, p)
		}
	})
}

// serveOriginal is the unchanged bit-perfect path: the file's bytes verbatim.
func serveOriginal(w http.ResponseWriter, r *http.Request, p string) {
	f, err := os.Open(p)
	if err != nil {
		notFound(w) // file vanished since the last scan
		return
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || fi.IsDir() {
		notFound(w)
		return
	}
	if ct, ok := streamMIME[strings.ToLower(filepath.Ext(p))]; ok {
		w.Header().Set("Content-Type", ct)
	}
	// no-cache = revalidate, not "don't cache": unchanged files answer 304
	// via the ETag, retagged files aren't served stale
	w.Header().Set("Cache-Control", "private, no-cache")
	w.Header().Set("ETag", fmt.Sprintf(`"%x-%x"`, fi.ModTime().UnixNano(), fi.Size()))
	http.ServeContent(w, r, fi.Name(), fi.ModTime(), f)
}

// serveTranscoded transcodes p to an Opus cache file keyed by the source's
// mtime+size (so a re-tagged file gets a fresh cache entry) and serves the
// cache with http.ServeContent. 501 if no ffmpeg is available.
func serveTranscoded(w http.ResponseWriter, r *http.Request, d *Deps, id, p, tier, bitrate string) {
	if !d.CanTranscode {
		httpError(w, http.StatusNotImplemented, "transcoding unavailable")
		return
	}
	src, err := os.Stat(p)
	if err != nil || src.IsDir() {
		notFound(w) // file vanished since the last scan
		return
	}
	dir := filepath.Join(d.Cfg.DataDir, "tc")
	cachePath := filepath.Join(dir, fmt.Sprintf("%s__%s__%x-%x.opus",
		id, tier, src.ModTime().UnixNano(), src.Size()))

	if _, err := os.Stat(cachePath); err != nil {
		// cache miss: transcode to a temp file, then atomically rename in.
		if err := os.MkdirAll(dir, 0o755); err != nil {
			httpError(w, http.StatusInternalServerError, "transcode failed")
			return
		}
		tmp, err := os.CreateTemp(dir, filepath.Base(cachePath)+".*.part")
		if err != nil {
			httpError(w, http.StatusInternalServerError, "transcode failed")
			return
		}
		tmpPath := tmp.Name()
		tmp.Close() // ffmpeg writes the file itself
		// app-lifetime timeout, NOT r.Context(): finish the encode even if the
		// client disconnects, so the cache entry is populated for next time.
		ffCtx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
		defer cancel()
		cmd := exec.CommandContext(ffCtx, d.Cfg.FFmpegPath,
			"-nostdin", "-hide_banner", "-loglevel", "error",
			"-i", p, "-vn", "-map_metadata", "0",
			"-c:a", "libopus", "-b:a", bitrate, "-f", "ogg", "-y", tmpPath)
		if err := cmd.Run(); err != nil {
			os.Remove(tmpPath)
			httpError(w, http.StatusInternalServerError, "transcode failed")
			return
		}
		if err := os.Rename(tmpPath, cachePath); err != nil {
			os.Remove(tmpPath)
			httpError(w, http.StatusInternalServerError, "transcode failed")
			return
		}
		sweepCache(dir, int64(d.Cfg.TranscodeCacheMB)<<20, cachePath)
	}

	cf, err := os.Open(cachePath)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "transcode failed")
		return
	}
	defer cf.Close()
	cfi, err := cf.Stat()
	if err != nil {
		httpError(w, http.StatusInternalServerError, "transcode failed")
		return
	}
	w.Header().Set("Content-Type", "audio/ogg")
	w.Header().Set("Cache-Control", "private, no-cache")
	w.Header().Set("ETag", fmt.Sprintf(`"%x-%x"`, cfi.ModTime().UnixNano(), cfi.Size()))
	http.ServeContent(w, r, filepath.Base(cachePath), cfi.ModTime(), cf)
}

// sweepCache deletes oldest-by-ModTime .opus files until the dir is under
// budget bytes. keep is never evicted (the file about to be served), so a
// single output larger than the whole budget can't delete itself.
// ponytail: O(n) dir scan + oldest-first delete; a real LRU only if the cache
// dir ever gets huge.
func sweepCache(dir string, budget int64, keep string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	type f struct {
		path string
		size int64
		mod  time.Time
	}
	var files []f
	var total int64
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".opus") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		files = append(files, f{filepath.Join(dir, e.Name()), info.Size(), info.ModTime()})
		total += info.Size()
	}
	if total <= budget {
		return
	}
	sort.Slice(files, func(i, j int) bool { return files[i].mod.Before(files[j].mod) })
	for _, fl := range files {
		if total <= budget {
			break
		}
		if fl.path == keep {
			continue
		}
		if os.Remove(fl.path) == nil {
			total -= fl.size
		}
	}
}
