package enrich

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"time"
)

// Opra fetches the OPRA headphone-EQ dataset (CC-BY-SA, Roon Labs) and joins
// its vendor/product/eq lines into the compact payload the app consumes:
// {"products":[{"vendor","product","eqs":[{"author","gainDb","bands":[...]}]}]}.
// On-demand endpoint, not part of Enricher.Run — a plain http client is fine.
type Opra struct {
	hc  *http.Client
	url string
}

func NewOpra() *Opra {
	return &Opra{
		hc:  &http.Client{Timeout: 60 * time.Second}, // the feed is ~20k JSONL lines
		url: "http://opra.roonlabs.net/database_v1.jsonl",
	}
}

// OpraBand mirrors an OPRA parametric band; q for biquads, slope (dB/oct)
// only for low/high_pass.
type OpraBand struct {
	Type      string   `json:"type"`
	Frequency float64  `json:"frequency"`
	GainDB    float64  `json:"gainDb"`
	Q         *float64 `json:"q,omitempty"`
	Slope     *float64 `json:"slope,omitempty"`
}

type OpraEq struct {
	Author string     `json:"author"`
	GainDB float64    `json:"gainDb"`
	Bands  []OpraBand `json:"bands"`
}

type OpraProduct struct {
	Vendor  string   `json:"vendor"`
	Product string   `json:"product"`
	Eqs     []OpraEq `json:"eqs"`
}

// Fetch downloads and compacts the dataset. Malformed lines are skipped;
// products without any parseable EQ are dropped.
func (o *Opra) Fetch(ctx context.Context) (json.RawMessage, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, o.url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", userAgent)
	res, err := o.hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode > 299 {
		return nil, fmt.Errorf("opra: status %d", res.StatusCode)
	}

	type line struct {
		Type string `json:"type"`
		ID   string `json:"id"`
		Data struct {
			Name       string `json:"name"`
			VendorID   string `json:"vendor_id"`
			ProductID  string `json:"product_id"`
			Author     string `json:"author"`
			Parameters struct {
				GainDB float64 `json:"gain_db"`
				Bands  []struct {
					Type      string   `json:"type"`
					Frequency float64  `json:"frequency"`
					GainDB    float64  `json:"gain_db"`
					Q         *float64 `json:"q"`
					Slope     *float64 `json:"slope"`
				} `json:"bands"`
			} `json:"parameters"`
		} `json:"data"`
	}

	vendors := map[string]string{} // vendor id -> name
	type prod struct{ name, vendorID string }
	products := map[string]prod{} // product id -> {name, vendor id}
	eqs := map[string][]OpraEq{}  // product id -> eqs
	sc := bufio.NewScanner(res.Body)
	sc.Buffer(make([]byte, 64<<10), 1<<20) // eq lines can exceed the 64K default
	for sc.Scan() {
		var l line
		if err := json.Unmarshal(sc.Bytes(), &l); err != nil {
			continue // skip malformed lines
		}
		switch l.Type {
		case "vendor":
			vendors[l.ID] = l.Data.Name
		case "product":
			products[l.ID] = prod{l.Data.Name, l.Data.VendorID}
		case "eq":
			eq := OpraEq{Author: l.Data.Author, GainDB: l.Data.Parameters.GainDB}
			for _, b := range l.Data.Parameters.Bands {
				eq.Bands = append(eq.Bands, OpraBand{
					Type: b.Type, Frequency: b.Frequency, GainDB: b.GainDB, Q: b.Q, Slope: b.Slope,
				})
			}
			eqs[l.Data.ProductID] = append(eqs[l.Data.ProductID], eq)
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}

	out := []OpraProduct{}
	for id, p := range products {
		if len(eqs[id]) == 0 {
			continue
		}
		out = append(out, OpraProduct{Vendor: vendors[p.vendorID], Product: p.name, Eqs: eqs[id]})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Vendor != out[j].Vendor {
			return out[i].Vendor < out[j].Vendor
		}
		return out[i].Product < out[j].Product
	})
	return json.Marshal(map[string]any{"products": out})
}
