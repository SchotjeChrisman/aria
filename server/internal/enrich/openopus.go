package enrich

import (
	"context"
	"errors"
	"net/url"
	"strings"
)

// OpenOpus: classical composer portraits, epochs, birth/death years.
type OpenOpus struct {
	c    *politeClient
	base string
}

func NewOpenOpus() *OpenOpus {
	return &OpenOpus{c: newPoliteClient(), base: "https://api.openopus.org"}
}

// Composer matches the cached composer-entry fields Open Opus contributes
// (the Wikipedia bio/url are merged in by the caller).
type Composer struct {
	FullName string  `json:"fullName"`
	Epoch    string  `json:"epoch"`
	Portrait string  `json:"portrait"`
	Born     *string `json:"born"`
	Died     *string `json:"died"`
}

// SearchComposer searches by last name and applies the legacy fuzzy match:
// complete_name contains the last name, or the queried name contains the
// short name. (nil, nil) = no match.
func (o *OpenOpus) SearchComposer(ctx context.Context, name string) (*Composer, error) {
	fields := strings.Fields(name)
	if len(fields) == 0 {
		return nil, nil
	}
	last := strings.ToLower(fields[len(fields)-1])
	var raw struct {
		Composers []struct {
			Name         string `json:"name"`
			CompleteName string `json:"complete_name"`
			Epoch        string `json:"epoch"`
			Portrait     string `json:"portrait"`
			Birth        string `json:"birth"`
			Death        string `json:"death"`
		} `json:"composers"`
	}
	err := o.c.getJSON(ctx, o.base+"/composer/list/search/"+url.PathEscape(last)+".json", &raw)
	if errors.Is(err, errNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	lname := strings.ToLower(name)
	for _, c := range raw.Composers {
		if strings.Contains(strings.ToLower(c.CompleteName), last) || strings.Contains(lname, strings.ToLower(c.Name)) {
			return &Composer{
				FullName: c.CompleteName,
				Epoch:    c.Epoch,
				Portrait: c.Portrait,
				Born:     year(c.Birth),
				Died:     year(c.Death),
			}, nil
		}
	}
	return nil, nil
}

// year: "1685-01-01" -> "1685"; "" -> null (legacy birth?.slice(0,4) || null).
func year(date string) *string {
	if date == "" {
		return nil
	}
	if len(date) > 4 {
		date = date[:4]
	}
	return &date
}
