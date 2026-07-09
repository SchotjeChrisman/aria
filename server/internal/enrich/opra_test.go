package enrich

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestOpraFetch(t *testing.T) {
	feed := `{"type":"vendor","id":"senn","data":{"name":"Sennheiser"}}
{"type":"product","id":"senn::hd650","data":{"name":"HD 650","vendor_id":"senn"}}
not json at all
{"type":"eq","id":"e1","data":{"author":"oratory1990","details":"Measured by X","type":"parametric_eq","product_id":"senn::hd650","parameters":{"gain_db":-6.8,"bands":[{"type":"peak_dip","frequency":105,"gain_db":3.1,"q":0.7},{"type":"low_pass","frequency":18000,"gain_db":0,"slope":12}]}}}
{"type":"product","id":"senn::noeq","data":{"name":"No EQ","vendor_id":"senn"}}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(feed))
	}))
	t.Cleanup(srv.Close)

	o := &Opra{hc: &http.Client{Timeout: 5 * time.Second}, url: srv.URL}
	raw, err := o.Fetch(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var got struct{ Products []OpraProduct }
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	// eq-less product dropped, malformed line skipped
	if len(got.Products) != 1 {
		t.Fatalf("products = %+v, want 1", got.Products)
	}
	p := got.Products[0]
	if p.Vendor != "Sennheiser" || p.Product != "HD 650" || len(p.Eqs) != 1 {
		t.Fatalf("product = %+v", p)
	}
	eq := p.Eqs[0]
	if eq.Author != "oratory1990" || eq.Details != "Measured by X" || eq.GainDB != -6.8 || len(eq.Bands) != 2 {
		t.Fatalf("eq = %+v", eq)
	}
	if b := eq.Bands[0]; b.Type != "peak_dip" || b.Frequency != 105 || b.GainDB != 3.1 || b.Q == nil || *b.Q != 0.7 || b.Slope != nil {
		t.Errorf("band 0 = %+v", b)
	}
	if b := eq.Bands[1]; b.Type != "low_pass" || b.Slope == nil || *b.Slope != 12 || b.Q != nil {
		t.Errorf("band 1 = %+v", b)
	}
}
