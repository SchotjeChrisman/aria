package enrich

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestSearchComposer(t *testing.T) {
	const bach = `{"composers":[
		{"name":"Bach","complete_name":"Johann Sebastian Bach","epoch":"Baroque",
		 "portrait":"https://o/bach.jpg","birth":"1685-01-01","death":"1750-01-01"}]}`

	tests := []struct {
		name, query, wantPath, body string
		want                        *Composer
	}{
		{
			// last name appears in complete_name
			name: "match by complete_name", query: "Johann Sebastian Bach", wantPath: "/composer/list/search/bach.json", body: bach,
			want: &Composer{FullName: "Johann Sebastian Bach", Epoch: "Baroque", Portrait: "https://o/bach.jpg",
				Born: ptr("1685"), Died: ptr("1750")},
		},
		{
			// queried name contains the short name (initials break the first rule's last-name check? no —
			// last "bach" is in complete_name too; this exercises the second rule via a complete_name miss)
			name: "match by short name", query: "J.S. Bach", wantPath: "/composer/list/search/bach.json",
			body: `{"composers":[{"name":"Bach","complete_name":"J. S. B.","epoch":"Baroque","portrait":"p","birth":"","death":""}]}`,
			want: &Composer{FullName: "J. S. B.", Epoch: "Baroque", Portrait: "p"},
		},
		{
			name: "no match", query: "John Williams", wantPath: "/composer/list/search/williams.json",
			body: `{"composers":[{"name":"Byrd","complete_name":"William Byrd"}]}`, want: nil,
		},
		{name: "empty result", query: "Nobody Here", wantPath: "/composer/list/search/here.json", body: `{"status":{"success":"false"}}`, want: nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var gotPath string
			srv := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
				gotPath = r.URL.Path
				rw.Write([]byte(tt.body))
			}))
			defer srv.Close()
			o := &OpenOpus{c: newPoliteClient(), base: srv.URL}
			got, err := o.SearchComposer(context.Background(), tt.query)
			if err != nil {
				t.Fatal(err)
			}
			if gotPath != tt.wantPath {
				t.Errorf("path = %q, want %q", gotPath, tt.wantPath)
			}
			if tt.want == nil {
				if got != nil {
					t.Fatalf("want nil, got %+v", got)
				}
				return
			}
			if got == nil {
				t.Fatal("want match, got nil")
			}
			if got.FullName != tt.want.FullName || got.Epoch != tt.want.Epoch || got.Portrait != tt.want.Portrait ||
				!eqPtr(got.Born, tt.want.Born) || !eqPtr(got.Died, tt.want.Died) {
				t.Errorf("got %+v, want %+v", got, tt.want)
			}
		})
	}
}

func ptr(s string) *string { return &s }

func eqPtr(a, b *string) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}
