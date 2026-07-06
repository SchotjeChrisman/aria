package api

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
)

func init() { register(registerArt) }

var albumIDRe = regexp.MustCompile(`^[0-9a-f]{40}$`)

func registerArt(mux *http.ServeMux, d *Deps) {
	// art is extracted at scan time (or fetched by the enricher) into
	// DATA_DIR/art/<albumId>.jpg — always .jpg-named regardless of the actual
	// bytes; clients sniff. Immutable enough for a long client cache: the ETag
	// (mtime+size) revalidates the rare re-fetch.
	mux.HandleFunc("GET /api/art/{albumId}", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("albumId")
		if !albumIDRe.MatchString(id) {
			notFound(w)
			return
		}
		p := filepath.Join(d.Cfg.DataDir, "art", id+".jpg")
		f, err := os.Open(p)
		if err != nil {
			// tolerate extension-less files should the scanner write bare ids
			f, err = os.Open(filepath.Join(d.Cfg.DataDir, "art", id))
			if err != nil {
				notFound(w)
				return
			}
		}
		defer f.Close()
		fi, err := f.Stat()
		if err != nil || fi.IsDir() {
			notFound(w)
			return
		}
		w.Header().Set("Content-Type", "image/jpeg")
		w.Header().Set("Cache-Control", "public, max-age=31536000")
		w.Header().Set("ETag", fmt.Sprintf(`"%x-%x"`, fi.ModTime().UnixNano(), fi.Size()))
		http.ServeContent(w, r, "", fi.ModTime(), f) // handles If-None-Match/Range
	})
}
