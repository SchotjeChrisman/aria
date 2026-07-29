package enrich

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
)

// release 249504, trimmed to the fields we decode (verified live).
const dgRelease = `{"id":249504,"country":"US","year":1985,"master_id":96559,
  "genres":["Electronic","Pop"],"styles":["Euro-Disco"],
  "labels":[{"name":"RCA","catno":"PB 41447","id":895}],
  "identifiers":[{"type":"Barcode","value":"07863414479"}]}`

func dgServer(t *testing.T, body string, code int) (*Discogs, *string) {
	t.Helper()
	var gotQuery string
	srv := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		rw.WriteHeader(code)
		rw.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return &Discogs{c: newPoliteClient(), base: srv.URL, token: "tok"}, &gotQuery
}

func TestDiscogsRelease(t *testing.T) {
	tests := []struct {
		name    string
		body    string
		code    int
		want    *DiscogsRelease
		wantErr error
	}{
		{
			name: "full release",
			body: dgRelease, code: 200,
			want: &DiscogsRelease{
				Genres: []string{"Electronic", "Pop"},
				Styles: []string{"Euro-Disco"},
				Labels: []struct {
					Name  string `json:"name"`
					Catno string `json:"catno"`
				}{{Name: "RCA", Catno: "PB 41447"}},
			},
		},
		{
			// plenty of releases carry genres but no styles at all
			name: "no styles, no labels",
			body: `{"id":1,"genres":["Rock"]}`, code: 200,
			want: &DiscogsRelease{Genres: []string{"Rock"}},
		},
		{
			// a dead link in MusicBrainz: a definitive miss, and the caller
			// stamps DiscogsAt on it so it is never asked again
			name: "404", body: `{"message":"not found"}`, code: 404,
			wantErr: errNotFound,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			d, query := dgServer(t, tt.body, tt.code)
			got, err := d.Release(context.Background(), 249504)
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("err = %v, want %v", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("got %+v, want %+v", got, tt.want)
			}
			// the token has to actually reach the wire, or the pass silently
			// runs at the 25/min unauthenticated tier forever
			if *query != "token=tok" {
				t.Errorf("query = %q, want token=tok", *query)
			}
		})
	}
}

// The feature gate. Without a token there is no client at all, which is what
// makes every call site's `e.dg == nil` guard the whole of the degradation.
func TestNewDiscogsNoToken(t *testing.T) {
	if d := NewDiscogs(""); d != nil {
		t.Errorf("NewDiscogs(\"\") = %+v, want nil", d)
	}
	if d := NewDiscogs("tok"); d == nil {
		t.Error("NewDiscogs(token) = nil")
	}
}
