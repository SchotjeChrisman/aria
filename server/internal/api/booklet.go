package api

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
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

type bookletCand struct {
	name  string // basename, the client-facing key
	path  string // resolved absolute path
	size  int64
	named bool // name contains "booklet"
}

// bookletBetter reports whether a outranks b: "booklet"-named first, then
// size desc, then name — the list order and the per-name de-dupe winner.
func bookletBetter(a, b bookletCand) bool {
	if a.named != b.named {
		return a.named
	}
	if a.size != b.size {
		return a.size > b.size
	}
	return a.name < b.name
}

func registerBooklet(mux *http.ServeMux, d *Deps) {
	// Booklets are resolved on demand from the album's directories on disk —
	// no scanner/DB involvement. Candidates come from the deepest common
	// ancestor of all track paths (multi-disc rips keep the booklet at the
	// album root) plus each distinct track directory. De-duped by basename
	// (better one wins) so names are unique keys for the serve route.
	candidates := func(r *http.Request, id string) ([]bookletCand, bool) {
		if !albumIDRe.MatchString(id) {
			return nil, false
		}
		ts, err := d.Tracks.ByAlbum(r.Context(), id)
		if err != nil || len(ts) == 0 {
			return nil, false
		}
		dirs := map[string]bool{}
		rels := make([]string, 0, len(ts))
		for _, t := range ts {
			rel := filepath.Dir(filepath.FromSlash(t.Path))
			rels = append(rels, rel)
			dirs[rel] = true
		}
		dirs[bookletCommonDir(rels)] = true
		byName := map[string]bookletCand{}
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
				c := bookletCand{
					name:  e.Name(),
					path:  filepath.Join(dir, e.Name()),
					size:  fi.Size(),
					named: strings.Contains(strings.ToLower(e.Name()), "booklet"),
				}
				if prev, ok := byName[c.name]; !ok || bookletBetter(c, prev) {
					byName[c.name] = c
				}
			}
		}
		cs := make([]bookletCand, 0, len(byName))
		for _, c := range byName {
			cs = append(cs, c)
		}
		sort.Slice(cs, func(i, j int) bool { return bookletBetter(cs[i], cs[j]) })
		return cs, true
	}

	mux.HandleFunc("GET /api/albums/{albumId}/booklets", func(w http.ResponseWriter, r *http.Request) {
		cs, ok := candidates(r, r.PathValue("albumId"))
		if !ok {
			notFound(w)
			return
		}
		names := make([]string, len(cs))
		for i, c := range cs {
			names[i] = c.name
		}
		writeJSON(w, http.StatusOK, map[string]any{"booklets": names})
	})

	mux.HandleFunc("GET /api/albums/{albumId}/booklet/{name}", func(w http.ResponseWriter, r *http.Request) {
		cs, ok := candidates(r, r.PathValue("albumId"))
		if !ok {
			notFound(w)
			return
		}
		// The name must exactly match a collected candidate basename and we
		// serve that candidate's own resolved path — user input is never
		// joined into a filesystem path, so traversal names just miss.
		var path string
		for _, c := range cs {
			if c.name == r.PathValue("name") {
				path = c.path
				break
			}
		}
		if path == "" {
			notFound(w)
			return
		}
		f, err := os.Open(path)
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
