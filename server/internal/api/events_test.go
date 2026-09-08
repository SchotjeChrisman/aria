package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// The whole point of a GENERATION rather than a "something changed" ping: a
// client that missed a frame — asleep, offline, or dropped by the hub for
// being slow — still learns on its next connect that the library moved. So the
// number must be published on every invalidation AND readable at subscribe
// time, and it must rise.
func TestInvalidateTracksAnnouncesRisingGeneration(t *testing.T) {
	d := &Deps{Events: NewHub()}
	ch, cancel := d.Events.Subscribe()
	defer cancel()

	before := d.TracksGen()
	d.InvalidateTracks()
	d.InvalidateTracks()

	var gens []string
	for i := 0; i < 2; i++ {
		select {
		case frame := <-ch:
			s := string(frame)
			if !strings.HasPrefix(s, "event: library\n") {
				t.Fatalf("frame %d = %q, want a library event", i, s)
			}
			gens = append(gens, s)
		default:
			t.Fatalf("only %d frames published, want 2 — a missed invalidation is a stale client", i)
		}
	}
	if gens[0] == gens[1] {
		t.Errorf("both frames carry %q — the generation must rise, or clients cannot compare", gens[0])
	}
	if got := d.TracksGen(); got != before+2 {
		t.Errorf("TracksGen() = %d, want %d — the subscribe-time value must match what was published", got, before+2)
	}
}

// Deps built without a hub (the periodic-scan tests do exactly this) must not
// panic on the publish.
func TestInvalidateTracksWithoutHub(t *testing.T) {
	(&Deps{}).InvalidateTracks()
}

// The catch-up half of the design: a client that missed an announcement — it
// was offline, or the hub dropped its frame for being slow — has to be able to
// learn the current generation without anyone republishing. So the STREAM must
// state it, unprompted, at connect.
func TestEventsStreamOpensWithTheGeneration(t *testing.T) {
	d := &Deps{Events: NewHub()}
	d.InvalidateTracks() // a change this client was not around for
	mux := http.NewServeMux()
	registerEvents(mux, d)

	srv := httptest.NewServer(mux)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL+"/api/events", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	// The stream never ends on its own, so read until the frame shows up or the
	// context deadline kills the body read. The handler writes a ": connected"
	// comment first, hence accumulating rather than checking one Read.
	want := "event: library\ndata: {\"gen\":1}"
	var got strings.Builder
	buf := make([]byte, 256)
	for !strings.Contains(got.String(), want) {
		n, err := resp.Body.Read(buf)
		got.Write(buf[:n])
		if err != nil {
			t.Fatalf("stream gave %q before %v, want it to contain %q — without this\n"+
				"a client that missed a frame stays stale until something else changes",
				got.String(), err, want)
		}
	}
}
