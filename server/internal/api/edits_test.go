package api

import (
	"encoding/json"
	"testing"
)

// The manual album flags are a trust boundary: an unknown state or a non-bool
// locked must reject the whole patch, exactly like every other bad field.
func TestCleanEditsAlbumFlags(t *testing.T) {
	cases := []struct {
		name, body string
		want       any // nil = the patch must be rejected
		field      string
	}{
		{name: "state local", body: `{"state":"local"}`, field: "state", want: "local"},
		{name: "state matched", body: `{"state":"matched"}`, field: "state", want: "matched"},
		{name: "state unknown", body: `{"state":"review"}`},
		{name: "state not a string", body: `{"state":1}`},
		{name: "locked true", body: `{"locked":true}`, field: "locked", want: true},
		{name: "locked false", body: `{"locked":false}`, field: "locked", want: false},
		{name: "locked not a bool", body: `{"locked":"yes"}`},
		{name: "disambiguation", body: `{"disambiguation":" 2019-05, Amsterdam "}`,
			field: "disambiguation", want: "2019-05, Amsterdam"},
		{name: "disambiguation empty", body: `{"disambiguation":"  "}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var body map[string]json.RawMessage
			if err := json.Unmarshal([]byte(tc.body), &body); err != nil {
				t.Fatal(err)
			}
			got := cleanEdits(body, "album")
			if tc.field == "" {
				if got != nil {
					t.Errorf("cleanEdits(%s) = %v, want nil", tc.body, got)
				}
				return
			}
			if got[tc.field] != tc.want {
				t.Errorf("cleanEdits(%s)[%s] = %v, want %v", tc.body, tc.field, got[tc.field], tc.want)
			}
		})
	}
}
