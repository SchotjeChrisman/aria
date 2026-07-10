package api

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	"aria/internal/repo"
)

func init() { register(registerArt) }

var albumIDRe = regexp.MustCompile(`^[0-9a-f]{40}$`)

const maxArtBytes = 10 << 20 // 10 MiB upload cap

// artPreviewer is the enricher surface the art-preview branch needs (matched
// structurally by *enrich.Enricher). nil result == fetch failed.
type artPreviewer interface {
	AlbumArt(ctx context.Context, albumArtist, album, mbid string) []byte
}

// artSlotPath maps a source to its on-disk file. "" and "file" share the bare
// .jpg slot (embedded art); "api"/"custom" get suffixed slots.
func artSlotPath(dataDir, id, source string) string {
	switch source {
	case "api":
		return filepath.Join(dataDir, "art", id+".api.jpg")
	case "custom":
		return filepath.Join(dataDir, "art", id+".custom.jpg")
	default: // "" or "file"
		return filepath.Join(dataDir, "art", id+".jpg")
	}
}

// embeddedArtPresent reports real scanner-written embedded art (.jpg or the
// legacy extension-less file), size > 0.
func embeddedArtPresent(dataDir, id string) bool {
	for _, p := range []string{artSlotPath(dataDir, id, "file"), filepath.Join(dataDir, "art", id)} {
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() && fi.Size() > 0 {
			return true
		}
	}
	return false
}

// albumArtMeta reads the stored album edit's artSource/artVersion (zero values
// when no edit exists).
func albumArtMeta(ctx context.Context, d *Deps, id string) (source string, version int) {
	raw, err := d.Edits.Get(ctx, "album", id)
	if err != nil || raw == nil {
		return "", 0
	}
	var m struct {
		ArtSource  string `json:"artSource"`
		ArtVersion int    `json:"artVersion"`
	}
	json.Unmarshal(raw, &m)
	return m.ArtSource, m.ArtVersion
}

func mbidOf(ts []repo.Track) string {
	for _, t := range ts {
		if t.MBAlbumID != nil && *t.MBAlbumID != "" {
			return *t.MBAlbumID
		}
	}
	return ""
}

// serveArtSlot serves the on-disk slot with the long-lived immutable cache +
// ETag; false when the file is absent. The file slot also honours the legacy
// extension-less path.
func serveArtSlot(w http.ResponseWriter, r *http.Request, dataDir, id, source string) bool {
	f, err := os.Open(artSlotPath(dataDir, id, source))
	if err != nil && source == "file" {
		f, err = os.Open(filepath.Join(dataDir, "art", id))
	}
	if err != nil {
		return false
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || fi.IsDir() {
		return false
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "public, max-age=31536000")
	w.Header().Set("ETag", fmt.Sprintf(`"%x-%x"`, fi.ModTime().UnixNano(), fi.Size()))
	http.ServeContent(w, r, "", fi.ModTime(), f) // handles If-None-Match/Range
	return true
}

// serveArtPreview streams remote art without persisting; no-store so the
// live preview is never cached. 404 when unavailable (FE falls back).
func serveArtPreview(w http.ResponseWriter, r *http.Request, d *Deps, id string) {
	ap, ok := d.Enricher.(artPreviewer)
	if !ok {
		notFound(w)
		return
	}
	ts, err := d.Tracks.ByAlbum(r.Context(), id)
	if err != nil || len(ts) == 0 {
		notFound(w)
		return
	}
	img := ap.AlbumArt(r.Context(), ts[0].AlbumArtist, ts[0].Album, mbidOf(ts))
	if img == nil {
		notFound(w)
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(img)
}

func registerArt(mux *http.ServeMux, d *Deps) {
	// art lives under DATA_DIR/art/ in per-source slots: <id>.jpg (embedded,
	// scanner), <id>.api.jpg (enriched/picked API), <id>.custom.jpg (upload).
	// On-disk slots get a long client cache; the artVersion query token busts
	// it. ?source= selects a slot directly (dialog thumbnails); a missing api
	// slot streams a live remote preview, uncached.
	mux.HandleFunc("GET /api/art/{albumId}", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("albumId")
		if !albumIDRe.MatchString(id) {
			notFound(w)
			return
		}
		source := r.URL.Query().Get("source")
		if !slices.Contains([]string{"", "file", "api", "custom"}, source) {
			httpError(w, http.StatusBadRequest, "invalid source")
			return
		}
		dir := d.Cfg.DataDir

		if source == "" { // resolve stored artSource (default when none set)
			stored, _ := albumArtMeta(r.Context(), d, id)
			switch stored {
			case "custom":
				if !serveArtSlot(w, r, dir, id, "custom") {
					notFound(w)
				}
			case "api":
				if !serveArtSlot(w, r, dir, id, "api") {
					serveArtPreview(w, r, d, id)
				}
			default: // "" (none set) or "file": embedded, else api fallback
				if embeddedArtPresent(dir, id) && serveArtSlot(w, r, dir, id, "file") {
					return
				}
				if !serveArtSlot(w, r, dir, id, "api") {
					notFound(w)
				}
			}
			return
		}

		// explicit slot request (thumbnails): serve exactly that slot
		switch source {
		case "api":
			if !serveArtSlot(w, r, dir, id, "api") {
				serveArtPreview(w, r, d, id)
			}
		default: // file | custom — no fallback
			if !serveArtSlot(w, r, dir, id, source) {
				notFound(w)
			}
		}
	})

	// custom art upload: writes the .custom.jpg slot and switches the album to
	// artSource=custom (bumping artVersion).
	mux.HandleFunc("POST /api/art/{albumId}", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("albumId")
		if !albumIDRe.MatchString(id) {
			notFound(w)
			return
		}
		ts, err := d.Tracks.ByAlbum(r.Context(), id)
		if err != nil {
			fail(w, err)
			return
		}
		if len(ts) == 0 {
			notFound(w)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, maxArtBytes)
		f, _, err := r.FormFile("image")
		if err != nil {
			if errors.As(err, new(*http.MaxBytesError)) {
				httpError(w, http.StatusRequestEntityTooLarge, "image too large")
				return
			}
			httpError(w, http.StatusBadRequest, "not an image")
			return
		}
		defer f.Close()
		buf := bufio.NewReader(f)
		head, _ := buf.Peek(512)
		if !strings.HasPrefix(http.DetectContentType(head), "image/") {
			httpError(w, http.StatusBadRequest, "not an image")
			return
		}
		out, err := os.OpenFile(artSlotPath(d.Cfg.DataDir, id, "custom"), os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
		if err != nil {
			fail(w, err)
			return
		}
		if _, err := io.Copy(out, buf); err != nil {
			out.Close()
			fail(w, err)
			return
		}
		if err := out.Close(); err != nil {
			fail(w, err)
			return
		}
		_, ver := albumArtMeta(r.Context(), d, id)
		cur, err := patchEdits(r.Context(), d, "album", id, map[string]any{"artSource": "custom", "artVersion": ver + 1})
		if err != nil {
			fail(w, err)
			return
		}
		d.InvalidateTracks()
		writeJSON(w, http.StatusOK, cur)
	})
}
