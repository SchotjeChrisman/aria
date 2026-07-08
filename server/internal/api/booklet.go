package api

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

func init() { register(registerBooklet) }

// bookletCommonDir returns the deepest common ancestor of relative dirs,
// compared by path segments; "." when they share none.
func bookletCommonDir(dirs []string) string {
	segs := strings.Split(dirs[0], string(filepath.Separator))
	for _, d := range dirs[1:] {
		s := strings.Split(d, string(filepath.Separator))
		if len(s) < len(segs) {
			segs = segs[:len(s)]
		}
		for i := range segs {
			if segs[i] != s[i] {
				segs = segs[:i]
				break
			}
		}
	}
	if len(segs) == 0 {
		return "."
	}
	return filepath.Join(segs...)
}

func registerBooklet(mux *http.ServeMux, d *Deps) {
	// Booklets are resolved on demand from the album's directories on disk —
	// no scanner/DB involvement. Candidates come from the deepest common
	// ancestor of all track paths (multi-disc rips keep the booklet at the
	// album root) plus each distinct track directory.
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
		dirs := map[string]bool{}
		rels := make([]string, 0, len(ts))
		for _, t := range ts {
			rel := filepath.Dir(filepath.FromSlash(t.Path))
			rels = append(rels, rel)
			dirs[rel] = true
		}
		dirs[bookletCommonDir(rels)] = true
		// ponytail: single booklet per album — a name containing "booklet"
		// wins, else the largest PDF; a JSON list endpoint if multi-booklet
		// albums show up.
		var best string // full path
		var bestSize int64
		var bestNamed bool
		for rel := range dirs {
			if rel == "." {
				continue // root-level PDFs can't be attributed to an album
			}
			dir := filepath.Join(d.Cfg.MusicDir, rel)
			entries, err := os.ReadDir(dir)
			if err != nil {
				continue
			}
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
					best, bestSize, bestNamed = filepath.Join(dir, e.Name()), fi.Size(), named
				}
			}
		}
		if best == "" {
			notFound(w)
			return
		}
		f, err := os.Open(best)
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
