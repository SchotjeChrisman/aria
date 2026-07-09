package api

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"

	"aria/internal/config"
	"aria/internal/db"
)

// A fresh cached OPRA payload is served as-is (no network fetch).
func TestEqOpraServesCache(t *testing.T) {
	d, err := db.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	deps := NewDeps(d, config.Config{}, "test")
	ctx := context.Background()

	payload := `{"products":[{"vendor":"Sennheiser","product":"HD 650","eqs":[{"author":"oratory1990","gainDb":-6.8,"bands":[{"type":"peak_dip","frequency":105,"gainDb":3.1,"q":0.7}]}]}]}`
	at := time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
	if err := deps.EnrichCache.Put(ctx, "opra", "db2", json.RawMessage(payload), at); err != nil {
		t.Fatal(err)
	}

	rec := httptest.NewRecorder()
	New(deps).ServeHTTP(rec, httptest.NewRequest("GET", "/api/eq/opra", nil))
	if rec.Code != 200 {
		t.Fatalf("GET /api/eq/opra = %d: %s", rec.Code, rec.Body.String())
	}
	var got struct {
		Products []struct {
			Vendor  string `json:"vendor"`
			Product string `json:"product"`
			Eqs     []struct {
				Author string           `json:"author"`
				GainDB float64          `json:"gainDb"`
				Bands  []map[string]any `json:"bands"`
			} `json:"eqs"`
		} `json:"products"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Products) != 1 || got.Products[0].Vendor != "Sennheiser" {
		t.Fatalf("products = %+v", got.Products)
	}
	eq := got.Products[0].Eqs[0]
	if eq.Author != "oratory1990" || eq.GainDB != -6.8 || eq.Bands[0]["q"] != 0.7 {
		t.Fatalf("eq = %+v", eq)
	}
}
