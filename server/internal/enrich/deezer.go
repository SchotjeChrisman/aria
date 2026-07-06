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

// DiscographyItem matches the cached shape: {title, cover|null, date|null, type}.
type DiscographyItem struct {
	Title string  `json:"title"`
	Cover *string `json:"cover"`
	Date  *string `json:"date"`
	Type  string  `json:"type"`
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
		out = append(out, DiscographyItem{Title: x.Title, Cover: nullable(x.CoverMedium), Date: nullable(x.ReleaseDate), Type: typ})
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
