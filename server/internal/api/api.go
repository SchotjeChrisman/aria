// Package api holds HTTP plumbing shared by the route files (library.go,
// tags.go, ... — one file per route group, each registering via register()).
package api

import (
	"compress/gzip"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"
)

// memo caches one value for a TTL, single-flighting concurrent rebuilds —
// for endpoints whose recompute scans a whole table/cache (people,
// newreleases) but whose inputs change rarely.
type memo[T any] struct {
	mu  sync.Mutex
	at  time.Time
	val T
}

func (m *memo[T]) get(ttl time.Duration, build func() (T, error)) (T, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.at.IsZero() && time.Since(m.at) < ttl {
		return m.val, nil
	}
	v, err := build()
	if err != nil {
		return v, err
	}
	m.val, m.at = v, time.Now()
	return v, nil
}

const maxBodyBytes = 32 << 10 // legacy express.json limit

var registrars []func(*http.ServeMux, *Deps)

// register hooks a route group into New. Route files call it from init():
//
//	func init() { register(registerLibrary) }
func register(f func(*http.ServeMux, *Deps)) { registrars = append(registrars, f) }

// New builds the mux with all registered route groups plus /healthz,
// wrapped in gzip for the large JSON payloads (/api/tracks is multi-MB).
func New(d *Deps) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})
	for _, f := range registrars {
		f(mux, d)
	}
	return gzipped(logged(mux))
}

// statusRecorder captures the status code for the access log.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

// ReadFrom re-exposes the wrapped writer's io.ReaderFrom (sendfile for
// /api/stream, /api/art and booklet ServeContent), which the embedded
// interface hides. Status is already recorded: ServeContent calls
// WriteHeader before copying.
func (s *statusRecorder) ReadFrom(r io.Reader) (int64, error) {
	if rf, ok := s.ResponseWriter.(io.ReaderFrom); ok {
		return rf.ReadFrom(r)
	}
	return io.Copy(s.ResponseWriter, r)
}

// logged writes one access-log line per request. /healthz probes are skipped
// (container healthcheck noise); /api/events is logged on connect because the
// SSE stream never completes.
func logged(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/healthz":
			h.ServeHTTP(w, r)
			return
		case "/api/events":
			log.Printf("http: %s %q connect", r.Method, r.URL.Path)
			h.ServeHTTP(w, r) // raw writer — the handler needs http.Flusher
			return
		}
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		h.ServeHTTP(rec, r)
		// %q escapes control chars: the decoded path is attacker-controlled and
		// would otherwise allow log-line forgery / terminal ANSI injection
		log.Printf("http: %s %q %d %s", r.Method, r.URL.Path, rec.status, time.Since(start))
	})
}

// gzipRW starts compressing lazily on the first write so handlers that set
// their own Content-Encoding (pre-gzipped /api/tracks cache) pass through.
type gzipRW struct {
	http.ResponseWriter
	gz      *gzip.Writer
	started bool
	skip    bool
}

func (g *gzipRW) start() {
	if g.started {
		return
	}
	g.started = true
	if g.Header().Get("Content-Encoding") != "" { // handler pre-compressed
		g.skip = true
		return
	}
	g.Header().Set("Content-Encoding", "gzip")
	g.Header().Del("Content-Length")
	g.gz = gzip.NewWriter(g.ResponseWriter)
}

func (g *gzipRW) WriteHeader(code int) {
	g.start()
	g.ResponseWriter.WriteHeader(code)
}

func (g *gzipRW) Write(b []byte) (int, error) {
	g.start()
	if g.skip {
		return g.ResponseWriter.Write(b)
	}
	return g.gz.Write(b)
}

// gzipped compresses responses when the client accepts it; SSE and file
// serving are excluded (long-lived/Range streams, already-compressed art).
func gzipped(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		if !strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") ||
			p == "/api/events" ||
			strings.HasPrefix(p, "/api/stream/") ||
			strings.HasPrefix(p, "/api/art/") ||
			// gzip breaks ServeContent Range; also skips the tiny booklet
			// name list, a non-loss.
			strings.Contains(p, "/booklet") {
			h.ServeHTTP(w, r)
			return
		}
		grw := &gzipRW{ResponseWriter: w}
		defer func() {
			if grw.gz != nil {
				grw.gz.Close()
			}
		}()
		h.ServeHTTP(grw, r)
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

// httpError writes {"error": msg} — the legacy error shape.
func httpError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

// readJSON decodes the body into dst (32 KiB cap). A missing/empty body
// decodes as no-op so `req.body ?? {}` semantics survive the port.
func readJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	body := http.MaxBytesReader(w, r.Body, maxBodyBytes)
	err := json.NewDecoder(body).Decode(dst)
	if errors.Is(err, io.EOF) {
		return nil
	}
	return err
}

// requireFields takes name, value pairs; on the first blank value it writes
// a 400 "<name> required" and returns false.
func requireFields(w http.ResponseWriter, pairs ...string) bool {
	for i := 0; i+1 < len(pairs); i += 2 {
		if strings.TrimSpace(pairs[i+1]) == "" {
			httpError(w, http.StatusBadRequest, pairs[i]+" required")
			return false
		}
	}
	return true
}

// Hub is a minimal SSE fan-out (scan/enrich progress; used by events.go).
type Hub struct {
	mu   sync.Mutex
	subs map[chan []byte]struct{}
}

func NewHub() *Hub { return &Hub{subs: map[chan []byte]struct{}{}} }

// Subscribe returns a channel of ready-to-write SSE frames and a cancel func.
func (h *Hub) Subscribe() (<-chan []byte, func()) {
	ch := make(chan []byte, 16)
	h.mu.Lock()
	h.subs[ch] = struct{}{}
	h.mu.Unlock()
	cancel := func() {
		h.mu.Lock()
		if _, ok := h.subs[ch]; ok {
			delete(h.subs, ch)
			close(ch)
		}
		h.mu.Unlock()
	}
	return ch, cancel
}

// Close closes all subscriber channels, unblocking open SSE handlers so
// http.Server.Shutdown can finish (wired via srv.RegisterOnShutdown).
func (h *Hub) Close() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subs {
		delete(h.subs, ch)
		close(ch)
	}
}

// Publish sends an SSE frame to all subscribers; slow ones drop frames
// (progress events are refreshed constantly, losing one is harmless).
func (h *Hub) Publish(event string, data any) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.subs) == 0 { // nobody listening: skip the marshal/format entirely
		return
	}
	b, err := json.Marshal(data)
	if err != nil {
		return
	}
	frame := []byte(fmt.Sprintf("event: %s\ndata: %s\n\n", event, b))
	for ch := range h.subs {
		select {
		case ch <- frame:
		default:
		}
	}
}
