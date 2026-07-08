package enrich

import (
	"context"
	"testing"
)

// Notify must fire with the fresh status on every change — the SSE `enrich`
// frames (and the client's refresh-on-idle) hang off it.
func TestNotifyFiresOnStatusChanges(t *testing.T) {
	e := New(context.Background(), nil, nil, t.TempDir())
	var got []map[string]any
	e.Notify = func(s any) { got = append(got, s.(map[string]any)) }

	e.setPhase("albums", 3)
	e.step()

	if len(got) != 2 {
		t.Fatalf("want 2 notifications, got %d", len(got))
	}
	if got[0]["phase"] != "albums" || got[0]["total"] != 3 || got[0]["done"] != 0 {
		t.Errorf("setPhase frame wrong: %v", got[0])
	}
	if got[1]["done"] != 1 {
		t.Errorf("step frame wrong: %v", got[1])
	}
}
