package enrich

import (
	"context"
	"fmt"
	"net/url"
	"strings"
)

// Deezer: missing album art, similar artists, discographies. Free, no key.
type Deezer struct {
	c    *politeClient
	base string
}

func NewDeezer() *Deezer {
	return &Deezer{c: newPoliteClient(), base: "https://api.deezer.com"}
}

type DeezerArtist struct {
	ID            int64
	Name          string
	PictureMedium string
	PictureXL     string
}

type dzArtist struct {
	ID            int64  `json:"id"`
	Name          string `json:"name"`
	PictureMedium string `json:"picture_medium"`
	PictureXL     string `json:"picture_xl"`
}

// SearchArtist returns the top hit, (nil, nil) when Deezer knows nothing.
// Callers wanting the artist's own photo must check Name equality themselves
// (legacy only trusts picture_xl on an exact lowercase name match).
func (d *Deezer) SearchArtist(ctx context.Context, name string) (*DeezerArtist, error) {
	var raw struct {
		Data []dzArtist `json:"data"`
	}
	if err := d.c.getJSON(ctx, d.base+"/search/artist?q="+url.QueryEscape(name), &raw); err != nil {
		return nil, err
	}
	if len(raw.Data) == 0 {
		return nil, nil
	}
	a := raw.Data[0]
	return &DeezerArtist{ID: a.ID, Name: a.Name, PictureMedium: a.PictureMedium, PictureXL: a.PictureXL}, nil
}

// SimilarArtist matches the cached shape: {name, image|null}.
type SimilarArtist struct {
	Name  string  `json:"name"`
	Image *string `json:"image"`
}

// Similar returns up to 12 related artists; empty non-nil slice when the
// artist is unknown (legacy []). Legacy treated fetch failures as [] too and
// cached them forever — callers decide whether to reproduce that.
func (d *Deezer) Similar(ctx context.Context, name string) ([]SimilarArtist, error) {
	out := []SimilarArtist{}
	a, err := d.SearchArtist(ctx, name)
	if err != nil {
		return nil, err
	}
	if a == nil {
		return out, nil
	}
	var raw struct {
		Data []dzArtist `json:"data"`
	}
	if err := d.c.getJSON(ctx, fmt.Sprintf("%s/artist/%d/related", d.base, a.ID), &raw); err != nil {
		return nil, err
	}
	for _, x := range raw.Data {
		if len(out) == 12 {
			break
		}
		out = append(out, SimilarArtist{Name: x.Name, Image: nullable(x.PictureMedium)})
	}
	return out, nil
}

// DiscographyItem matches the cached shape: {title, cover|null, date|null,
// type}. deezerId is additive — blobs cached before it existed simply lack it,
// and callers fall back to a name search (see AlbumID).
type DiscographyItem struct {
	Title    string  `json:"title"`
	Cover    *string `json:"cover"`
	Date     *string `json:"date"`
	Type     string  `json:"type"`
	DeezerID int64   `json:"deezerId,omitempty"`
}

// Discography returns all record types (album/single/ep/compilation), max 60.
// Exact-name match only — session musicians share names. Empty non-nil slice
// = Deezer answered and the artist genuinely has nothing (cacheable); error =
// transient failure, callers keep stale cache and retry next run.
func (d *Deezer) Discography(ctx context.Context, name string) ([]DiscographyItem, error) {
	a, err := d.SearchArtist(ctx, name)
	if err != nil {
		return nil, err
	}
	out := []DiscographyItem{}
	if a == nil || !strings.EqualFold(a.Name, name) {
		return out, nil
	}
	var raw struct {
		Data []struct {
			ID          int64  `json:"id"`
			Title       string `json:"title"`
			CoverMedium string `json:"cover_medium"`
			ReleaseDate string `json:"release_date"`
			RecordType  string `json:"record_type"`
		} `json:"data"`
	}
	if err := d.c.getJSON(ctx, fmt.Sprintf("%s/artist/%d/albums?limit=60", d.base, a.ID), &raw); err != nil {
		return nil, err
	}
	for _, x := range raw.Data {
		typ := strings.ToLower(x.RecordType)
		if typ == "" {
			typ = "album"
		}
		out = append(out, DiscographyItem{Title: x.Title, Cover: nullable(x.CoverMedium), Date: nullable(x.ReleaseDate), Type: typ, DeezerID: x.ID})
	}
	return out, nil
}

// ExtTrack is one track of an album nobody owns yet — enough to render a
// listing, not enough to play (there is no file).
type ExtTrack struct {
	Title    string `json:"title"`
	Duration int    `json:"duration"`
	Disc     int    `json:"disc"`
	Number   int    `json:"number"`
}

// ExtAlbum is Deezer's full album object: the UPC that bridges to
// MusicBrainz/Qobuz, plus the content an unowned-album page shows.
type ExtAlbum struct {
	DeezerID int64      `json:"deezerId"`
	Title    string     `json:"title"`
	Artist   string     `json:"artist"`
	UPC      string     `json:"upc"`
	Cover    *string    `json:"cover"`
	Date     string     `json:"date"`
	Type     string     `json:"type"`
	Label    string     `json:"label"`
	Link     string     `json:"link"`
	Tracks   []ExtTrack `json:"tracks"`
}

// AlbumID finds the Deezer album id for an artist+title. Deezer's field
// operators (artist:"x" album:"y") return nothing on /search/album, so this
// uses the same plain-text query as AlbumCoverURL and picks the hit whose
// artist and title both match; 0 when nothing matches well enough.
func (d *Deezer) AlbumID(ctx context.Context, artist, title string) (int64, error) {
	var raw struct {
		Data []struct {
			ID     int64  `json:"id"`
			Title  string `json:"title"`
			Artist struct {
				Name string `json:"name"`
			} `json:"artist"`
		} `json:"data"`
	}
	q := url.QueryEscape(artist + " " + title)
	if err := d.c.getJSON(ctx, d.base+"/search/album?q="+q, &raw); err != nil {
		return 0, err
	}
	for _, x := range raw.Data {
		if strings.EqualFold(x.Artist.Name, artist) && strings.EqualFold(x.Title, title) {
			return x.ID, nil
		}
	}
	// Deezer's top hit for an exact "artist title" query is reliable enough to
	// use, but only when the artist agrees — "Hounds of Love" must not resolve
	// to a covers compilation.
	for _, x := range raw.Data {
		if strings.EqualFold(x.Artist.Name, artist) {
			return x.ID, nil
		}
	}
	return 0, nil
}

// Album fetches one album by Deezer id. (nil, nil) when Deezer 404s it.
func (d *Deezer) Album(ctx context.Context, id int64) (*ExtAlbum, error) {
	var raw struct {
		ID     int64  `json:"id"`
		Title  string `json:"title"`
		UPC    string `json:"upc"`
		Link   string `json:"link"`
		Label  string `json:"label"`
		Cover  string `json:"cover_xl"`
		Date   string `json:"release_date"`
		Type   string `json:"record_type"`
		Artist struct {
			Name string `json:"name"`
		} `json:"artist"`
		Tracks struct {
			Data []struct {
				Title    string `json:"title"`
				Duration int    `json:"duration"`
				Disc     int    `json:"disk_number"`
				Number   int    `json:"track_position"`
			} `json:"data"`
		} `json:"tracks"`
		Error *struct{} `json:"error"`
	}
	if err := d.c.getJSON(ctx, fmt.Sprintf("%s/album/%d", d.base, id), &raw); err != nil {
		return nil, err
	}
	if raw.Error != nil || raw.ID == 0 {
		return nil, nil
	}
	typ := strings.ToLower(raw.Type)
	if typ == "" {
		typ = "album"
	}
	out := &ExtAlbum{
		DeezerID: raw.ID, Title: raw.Title, Artist: raw.Artist.Name, UPC: raw.UPC,
		Cover: nullable(raw.Cover), Date: raw.Date, Type: typ, Label: raw.Label, Link: raw.Link,
		Tracks: []ExtTrack{},
	}
	for _, t := range raw.Tracks.Data {
		out.Tracks = append(out.Tracks, ExtTrack{Title: t.Title, Duration: t.Duration, Disc: t.Disc, Number: t.Number})
	}
	return out, nil
}

// AlbumCoverURL finds a cover_xl for a missing-art album (fallback after
// Cover Art Archive); "" when the top hit has none.
func (d *Deezer) AlbumCoverURL(ctx context.Context, albumArtist, album string) (string, error) {
	var raw struct {
		Data []struct {
			CoverXL string `json:"cover_xl"`
		} `json:"data"`
	}
	q := url.QueryEscape(albumArtist + " " + album)
	if err := d.c.getJSON(ctx, d.base+"/search/album?q="+q, &raw); err != nil {
		return "", err
	}
	if len(raw.Data) == 0 {
		return "", nil
	}
	return raw.Data[0].CoverXL, nil
}
