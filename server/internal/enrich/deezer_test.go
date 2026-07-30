package enrich

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

// dzServer fakes the three Deezer endpoints the clients hit.
func dzServer(t *testing.T, searchArtist, related, albums, searchAlbum string) *Deezer {
	t.Helper()
	mux := http.NewServeMux()
	serve := func(path, body string) {
		mux.HandleFunc(path, func(rw http.ResponseWriter, r *http.Request) { rw.Write([]byte(body)) })
	}
	serve("/search/artist", searchArtist)
	serve("/artist/27/related", related)
	serve("/artist/27/albums", albums)
	serve("/search/album", searchAlbum)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return &Deezer{c: newPoliteClient(), base: srv.URL}
}

const dpArtist = `{"data":[{"id":27,"name":"Daft Punk","picture_medium":"pm","picture_xl":"px"}]}`

func TestSearchArtist(t *testing.T) {
	d := dzServer(t, dpArtist, "", "", "")
	a, err := d.SearchArtist(context.Background(), "Daft Punk")
	if err != nil {
		t.Fatal(err)
	}
	want := DeezerArtist{ID: 27, Name: "Daft Punk", PictureMedium: "pm", PictureXL: "px"}
	if *a != want {
		t.Errorf("got %+v, want %+v", *a, want)
	}

	d = dzServer(t, `{"data":[]}`, "", "", "")
	if a, err = d.SearchArtist(context.Background(), "Nobody"); err != nil || a != nil {
		t.Errorf("empty search: got %+v, %v", a, err)
	}
}

func TestSimilar(t *testing.T) {
	// 13 related — capped at 12; second has no picture -> null image
	rel := `{"data":[`
	for i := 0; i < 13; i++ {
		if i > 0 {
			rel += ","
		}
		pic := fmt.Sprintf(`"p%d"`, i)
		if i == 1 {
			pic = `""`
		}
		rel += fmt.Sprintf(`{"id":%d,"name":"a%d","picture_medium":%s}`, i, i, pic)
	}
	rel += `]}`
	d := dzServer(t, dpArtist, rel, "", "")
	got, err := d.Similar(context.Background(), "Daft Punk")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 12 {
		t.Fatalf("len = %d, want 12", len(got))
	}
	if got[0].Name != "a0" || got[0].Image == nil || *got[0].Image != "p0" {
		t.Errorf("got[0] = %+v", got[0])
	}
	if got[1].Image != nil {
		t.Errorf("empty picture should be nil, got %v", *got[1].Image)
	}

	// unknown artist -> empty non-nil slice, no related call
	d = dzServer(t, `{"data":[]}`, "", "", "")
	if got, err = d.Similar(context.Background(), "Nobody"); err != nil || got == nil || len(got) != 0 {
		t.Errorf("unknown artist: got %#v, %v", got, err)
	}
}

func TestDiscography(t *testing.T) {
	albums := `{"data":[
		{"title":"Discovery","cover_medium":"cm","release_date":"2001-03-07","record_type":"ALBUM"},
		{"title":"One More Time","cover_medium":"","release_date":"","record_type":""}]}`

	tests := []struct {
		name, query, searchBody string
		wantLen                 int
	}{
		{"exact match", "Daft Punk", dpArtist, 2},
		{"case-insensitive match", "daft punk", dpArtist, 2},
		{"name mismatch", "Someone Else", dpArtist, 0},
		{"no artist", "Nobody", `{"data":[]}`, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			d := dzServer(t, tt.searchBody, "", albums, "")
			got, err := d.Discography(context.Background(), tt.query)
			if err != nil {
				t.Fatal(err)
			}
			if got == nil {
				t.Fatal("must be non-nil (nil is reserved for errors)")
			}
			if len(got) != tt.wantLen {
				t.Fatalf("len = %d, want %d", len(got), tt.wantLen)
			}
			if tt.wantLen == 0 {
				return
			}
			if got[0].Title != "Discovery" || *got[0].Cover != "cm" || *got[0].Date != "2001-03-07" || got[0].Type != "album" {
				t.Errorf("got[0] = %+v", got[0])
			}
			if got[1].Cover != nil || got[1].Date != nil || got[1].Type != "album" {
				t.Errorf("empty fields: got[1] = %+v", got[1])
			}
		})
	}
}

// dzAlbumServer fakes /search/album + /album/{id} for the contributor lookup.
func dzAlbumServer(t *testing.T, searchAlbum, album string) *Deezer {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/search/album", func(rw http.ResponseWriter, r *http.Request) { rw.Write([]byte(searchAlbum)) })
	mux.HandleFunc("/album/", func(rw http.ResponseWriter, r *http.Request) { rw.Write([]byte(album)) })
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return &Deezer{c: newPoliteClient(), base: srv.URL}
}

func TestAlbumContributors(t *testing.T) {
	const found = `{"data":[{"id":42,"title":"Barber & Bruch Violin Concertos","artist":{"name":"Esther Yoo"}}]}`

	tests := []struct {
		name, search, album string
		want                []string
		wantErr             bool
	}{
		{
			name:   "contributors in Deezer order",
			search: found,
			album:  `{"id":42,"contributors":[{"name":"Esther Yoo"},{"name":"Royal Philharmonic Orchestra"},{"name":"Vasily Petrenko"}]}`,
			want:   []string{"Esther Yoo", "Royal Philharmonic Orchestra", "Vasily Petrenko"},
		},
		{"missing contributors", found, `{"id":42}`, nil, false},
		{"empty contributors", found, `{"id":42,"contributors":[]}`, nil, false},
		{"album 404s", found, `{"error":{"type":"DataException"}}`, nil, false},
		{"album not found in search", `{"data":[]}`, `{"id":42,"contributors":[{"name":"X"}]}`, nil, false},
		{"malformed album JSON", found, `{"id":42,"contributors":`, nil, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			d := dzAlbumServer(t, tt.search, tt.album)
			got, err := d.AlbumContributors(context.Background(), "Esther Yoo", "Barber & Bruch Violin Concertos")
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if len(got) != len(tt.want) {
				t.Fatalf("got %#v, want %#v", got, tt.want)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("got[%d] = %q, want %q", i, got[i], tt.want[i])
				}
			}
		})
	}
}

func TestContributorsAgree(t *testing.T) {
	dz := []string{"Esther Yoo", "Royal Philharmonic Orchestra", "Vasily Petrenko"}
	if !contributorsAgree(dz, []string{"Василий Петренко", "The Royal Philharmonic Orchestra"}) {
		t.Error("one overlap (modulo norm) should be enough")
	}
	// the T2 Trainspotting case: right query, wrong album, no shared credit.
	if contributorsAgree([]string{"Wolf Alice", "Young Fathers"}, []string{"Iggy Pop", "Brian Eno"}) {
		t.Error("disjoint credits must not agree")
	}
	if contributorsAgree(nil, []string{"Iggy Pop"}) {
		t.Error("no contributors must not agree")
	}
}

func TestAlbumCoverURL(t *testing.T) {
	d := dzServer(t, "", "", "", `{"data":[{"id":1,"cover_xl":"https://c/xl.jpg"}]}`)
	got, err := d.AlbumCoverURL(context.Background(), "Daft Punk", "Discovery")
	if err != nil || got != "https://c/xl.jpg" {
		t.Errorf("got %q, %v", got, err)
	}

	d = dzServer(t, "", "", "", `{"data":[]}`)
	if got, err = d.AlbumCoverURL(context.Background(), "X", "Y"); err != nil || got != "" {
		t.Errorf("no results: got %q, %v", got, err)
	}
}
