package api

import (
	"bufio"
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"aria/internal/enrich"
)

func init() { register(registerEnrich) }

// imgClient fetches external portraits; short timeout so a slow CDN can't pin
// a request goroutine.
var imgClient = &http.Client{Timeout: 15 * time.Second}

// servePersonImg serves a cached portrait with the immutable album-art cache
// policy; false when the file is absent or empty. Content-Type is sniffed by
// ServeContent (portraits are jpeg/png/webp).
func servePersonImg(w http.ResponseWriter, r *http.Request, path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || fi.IsDir() || fi.Size() == 0 {
		return false
	}
	w.Header().Set("Cache-Control", "public, max-age=31536000")
	w.Header().Set("ETag", fmt.Sprintf(`"%x-%x"`, fi.ModTime().UnixNano(), fi.Size()))
	http.ServeContent(w, r, filepath.Base(path), fi.ModTime(), f)
	return true
}

// cachePersonImg fetches src and writes it to dst atomically. Verifies the
// payload really is an image (a 200 HTML error page would otherwise be cached
// and served forever). maxArtBytes cap shared with the upload path.
func cachePersonImg(ctx context.Context, src, dst string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, src, nil)
	if err != nil {
		return err
	}
	resp, err := imgClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("upstream %d", resp.StatusCode)
	}
	body := bufio.NewReader(io.LimitReader(resp.Body, maxArtBytes))
	head, _ := body.Peek(512)
	if !strings.HasPrefix(http.DetectContentType(head), "image/") {
		return fmt.Errorf("not an image")
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(dst), "*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := io.Copy(tmp, body); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), dst)
}

// warmEnricher is the people/warm-up surface beyond Deps.Enricher (matched
// structurally by *enrich.Enricher, like onDemandEnricher in library.go).
type warmEnricher interface {
	People(ctx context.Context) (map[string]string, error)
	Warm(names []string) int
}

// The concrete enricher must satisfy every optional surface route files
// assert structurally — a signature drift is a compile error here, not a
// silent cache-only downgrade at runtime.
var (
	_ onDemandEnricher = (*enrich.Enricher)(nil)
	_ warmEnricher     = (*enrich.Enricher)(nil)
	_ identifier       = (*enrich.Enricher)(nil)
	_ artPreviewer     = (*enrich.Enricher)(nil)
)

// registerEnrich mounts the legacy enrichment group: status polling, manual
// re-kick, the bulk portrait map, and viewport-driven warm-up
// (server.js:286-312).
func registerEnrich(mux *http.ServeMux, d *Deps) {
	mux.HandleFunc("GET /api/enrich/status", func(w http.ResponseWriter, r *http.Request) {
		if d.Enricher == nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writeJSON(w, http.StatusOK, d.Enricher.Status())
	})

	// legacy kickEnrich(): fire-and-forget (single-flight inside Run), then
	// report status immediately.
	mux.HandleFunc("POST /api/enrich", func(w http.ResponseWriter, r *http.Request) {
		if d.Enricher == nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		d.GoBg(func(ctx context.Context) {
			if err := d.Enricher.Run(ctx); err != nil {
				log.Printf("enrich: %v", err)
			}
			d.InvalidateTracks() // enrichment feeds credits/hasArt into the merge
		})
		writeJSON(w, http.StatusOK, d.Enricher.Status())
	})

	// memoized: recompute scans every artist+composer cache blob, but the
	// map only changes as enrichment/edits land — 60s staleness is invisible
	var peopleMemo memo[map[string]string]
	// name -> external portrait URL (enrichment cache, edited portraits win).
	people := func(ctx context.Context) (map[string]string, error) {
		return peopleMemo.get(time.Minute, func() (map[string]string, error) {
			out := map[string]string{}
			if we, ok := d.Enricher.(warmEnricher); ok {
				m, err := we.People(ctx)
				if err != nil {
					return nil, err
				}
				out = m
			}
			// edited portraits win
			artists, err := d.Edits.ListKind(ctx, "artist")
			if err != nil {
				return nil, err
			}
			for n, raw := range artists {
				var e struct {
					Image string `json:"image"`
				}
				if json.Unmarshal(raw, &e) == nil && e.Image != "" {
					out[n] = e.Image
				}
			}
			return out, nil
		})
	}

	mux.HandleFunc("GET /api/people", func(w http.ResponseWriter, r *http.Request) {
		out, err := people(r.Context())
		if err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writeJSON(w, http.StatusOK, out)
	})

	// Portrait proxy: the map holds external CDN URLs (Deezer/Wikimedia).
	// Loading dozens straight from the app bursts those hosts and a random
	// subset drops each render. Fetch once, cache to DATA_DIR/people/, and
	// serve from the LAN like album art. 404 -> app shows initials.
	mux.HandleFunc("GET /api/people/img/{name}", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		if name == "" || utf8.RuneCountInString(name) > 200 {
			notFound(w)
			return
		}
		m, err := people(r.Context())
		if err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		src := m[name]
		if src == "" {
			notFound(w)
			return
		}
		// Key by source URL: a re-identified/edited portrait has a new URL, so
		// it lands in a fresh slot instead of serving the old file forever.
		// ponytail: the app's own image cache still keys by the stable proxy
		// URL — a portrait edit shows after an app restart. Add a version token
		// to the proxy path if in-session busting ever matters.
		sum := sha1.Sum([]byte(src))
		path := filepath.Join(d.Cfg.DataDir, "people", hex.EncodeToString(sum[:])+".jpg")
		if servePersonImg(w, r, path) {
			return
		}
		if err := cachePersonImg(r.Context(), src, path); err != nil {
			notFound(w)
			return
		}
		servePersonImg(w, r, path)
	})

	// warm faces/bios for names currently on the user's screen
	mux.HandleFunc("POST /api/enrich/people", func(w http.ResponseWriter, r *http.Request) {
		body, ok := bodyMap(w, r)
		if !ok {
			return
		}
		raw, _ := body["names"].([]any) // non-array reads as [] (legacy Array.isArray)
		var names []string
		for _, v := range raw {
			if s, isStr := v.(string); isStr && utf8.RuneCountInString(s) < 200 {
				names = append(names, s)
				if len(names) == 50 {
					break
				}
			}
		}
		queued := 0
		if we, ok := d.Enricher.(warmEnricher); ok {
			queued = we.Warm(names)
		}
		writeJSON(w, http.StatusOK, map[string]int{"queued": queued})
	})
}
