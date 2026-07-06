package api

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

func init() { register(registerStream) }

// no transcoding EVER: the original file's bits, with Range support via
// http.ServeContent.
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
		t, err := d.Tracks.ByID(r.Context(), r.PathValue("id"))
		if err != nil || t == nil {
			notFound(w)
			return
		}
		p := filepath.Join(d.Cfg.MusicDir, filepath.FromSlash(t.Path))
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
		http.ServeContent(w, r, fi.Name(), fi.ModTime(), f)
	})
}
