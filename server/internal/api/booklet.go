package api

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

func init() { register(registerBooklet) }

func registerBooklet(mux *http.ServeMux, d *Deps) {
	// Booklets are resolved on demand from the album's directory on disk —
	// no scanner/DB involvement. The album directory comes from the first
	// track's path (all tracks of an album share a folder in practice).
	mux.HandleFunc("GET /api/albums/{albumId}/booklet", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("albumId")
		if !albumIDRe.MatchString(id) {
			notFound(w)
			return
		}
		ts, err := d.Tracks.ByAlbum(r.Context(), id)
		if err != nil || len(ts) == 0 {
			notFound(w)
			return
		}
		dir := filepath.Join(d.Cfg.MusicDir, filepath.Dir(filepath.FromSlash(ts[0].Path)))
		entries, err := os.ReadDir(dir)
		if err != nil {
			notFound(w)
			return
		}
		// ponytail: single booklet per album — a name containing "booklet"
		// wins, else the largest PDF; a JSON list endpoint if multi-booklet
		// albums show up.
		var best string
		var bestSize int64
		var bestNamed bool
		for _, e := range entries {
			if e.IsDir() || !strings.EqualFold(filepath.Ext(e.Name()), ".pdf") {
				continue
			}
			fi, err := e.Info()
			if err != nil {
				continue
			}
			named := strings.Contains(strings.ToLower(e.Name()), "booklet")
			if best == "" || (named && !bestNamed) ||
				(named == bestNamed && fi.Size() > bestSize) {
				best, bestSize, bestNamed = e.Name(), fi.Size(), named
			}
		}
		if best == "" {
			notFound(w)
			return
		}
		f, err := os.Open(filepath.Join(dir, best))
		if err != nil {
			notFound(w)
			return
		}
		defer f.Close()
		fi, err := f.Stat()
		if err != nil || fi.IsDir() {
			notFound(w)
			return
		}
		w.Header().Set("Content-Type", "application/pdf")
		w.Header().Set("Cache-Control", "private, no-cache")
		w.Header().Set("ETag", fmt.Sprintf(`"%x-%x"`, fi.ModTime().UnixNano(), fi.Size()))
		http.ServeContent(w, r, "", fi.ModTime(), f) // handles Range/If-None-Match/HEAD
	})
}
