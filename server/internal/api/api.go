// Package api holds HTTP plumbing shared by the route files (library.go,
// tags.go, ... — one file per route group, each registering via register()).
package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
)

const maxBodyBytes = 32 << 10 // legacy express.json limit

var registrars []func(*http.ServeMux, *Deps)

// register hooks a route group into New. Route files call it from init():
//
//	func init() { register(registerLibrary) }
func register(f func(*http.ServeMux, *Deps)) { registrars = append(registrars, f) }

// New builds the mux with all registered route groups plus /healthz.
func New(d *Deps) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})
	for _, f := range registrars {
		f(mux, d)
	}
	return mux
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
	if err != nil && err.Error() == "EOF" {
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
	b, err := json.Marshal(data)
	if err != nil {
		return
	}
	frame := []byte(fmt.Sprintf("event: %s\ndata: %s\n\n", event, b))
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subs {
		select {
		case ch <- frame:
		default:
		}
	}
}
