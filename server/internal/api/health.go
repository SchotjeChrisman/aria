package api

import (
	"context"
	"fmt"
	"net/http"
	"sort"

	"aria/internal/enrich"
	"aria/internal/repo"
)

func init() { register(registerHealth) }

// healthMax caps the ITEMS returned per issue, never the counts. A library with
// 4,000 unanalysed tracks should say 4,000 and list a hundred of them — the
// list is for recognising what kind of thing is affected, and nobody scrolls
// four thousand rows to learn that.
const healthMax = 100

// healthItem is deliberately one shape for album issues and track issues alike:
// a title, who it is by, and one line saying what is wrong with it. Two shapes
// would buy nothing but a second widget on the client.
type healthItem struct {
	AlbumID  string `json:"albumId"`
	TrackID  string `json:"trackId,omitempty"`
	Title    string `json:"title"`
	Subtitle string `json:"subtitle,omitempty"`
	Detail   string `json:"detail,omitempty"`
}

type healthIssue struct {
	Kind  string       `json:"kind"`
	Count int          `json:"count"`
	Items []healthItem `json:"items"`
}

// issue builds one section, capping the list and keeping the true count.
func issue(kind string, items []healthItem) healthIssue {
	h := healthIssue{Kind: kind, Count: len(items), Items: items}
	if len(h.Items) > healthMax {
		h.Items = h.Items[:healthMax]
	}
	if h.Items == nil {
		h.Items = []healthItem{}
	}
	return h
}

// decisionItems renders a match decision list. reason is the matcher's own
// vocabulary (indistinguishable-siblings, no-plausible-candidate…), which is
// exactly the sentence the user needs to know whether to intervene.
func decisionItems(ds []repo.Decision, withSeparation bool) []healthItem {
	out := make([]healthItem, 0, len(ds))
	for _, d := range ds {
		detail := d.Reason
		if withSeparation && d.Separation != nil {
			detail = fmt.Sprintf("%s · runner-up %.2f away", d.Reason, *d.Separation)
		} else if !withSeparation {
			detail = d.State + " · " + d.Reason
		}
		out = append(out, healthItem{
			AlbumID: d.AlbumID, Title: d.Album, Subtitle: d.AlbumArtist, Detail: detail,
		})
	}
	return out
}

// libraryHealth is the whole "what is still wrong with this library" answer.
// Everything album-shaped is rolled up from the merged track view rather than
// queried again — that view is cached per generation and already carries the
// edits overlay, so the health page cannot disagree with what the album pages
// show. The measured columns come from track_audio directly, because codec and
// true peak are the two the view has no reason to carry.
func libraryHealth(ctx context.Context, d *Deps) (map[string]any, error) {
	ts, err := mergedTracks(ctx, d)
	if err != nil {
		return nil, err
	}
	audio, err := d.Audio.ListAll(ctx)
	if err != nil {
		return nil, err
	}
	analysed, err := d.Audio.Count(ctx)
	if err != nil {
		return nil, err
	}
	fingerprinted, identified, err := d.FP.Counts(ctx)
	if err != nil {
		return nil, err
	}

	// One pass over the library: album roll-up and the two track issues.
	type albumAgg struct {
		album, artist string
		art, mbid     bool
	}
	albums := map[string]*albumAgg{}
	var albumOrder []string
	var suspect, clipping, unanalysed []healthItem
	for _, t := range ts {
		id := str(t["albumId"])
		a := albums[id]
		if a == nil {
			a = &albumAgg{album: str(t["album"]), artist: str(t["albumArtist"])}
			albums[id] = a
			albumOrder = append(albumOrder, id)
		}
		if b, _ := t["hasArt"].(bool); b {
			a.art = true
		}
		if str(t["mbAlbumId"]) != "" {
			a.mbid = true
		}

		trackID := str(t["id"])
		item := healthItem{
			AlbumID: id, TrackID: trackID, Title: str(t["title"]), Subtitle: str(t["artist"]),
		}
		au, analysedTrack := audio[trackID]
		if !analysedTrack {
			item.Detail = "not analysed yet"
			unanalysed = append(unanalysed, item)
			continue
		}
		if au.Suspect {
			// The whole message is the contradiction: what the file claims to be
			// against what came out of the decoder.
			item.Detail = fmt.Sprintf("tagged %s, decodes as %s", str(t["format"]), au.Codec)
			suspect = append(suspect, item)
		}
		// A true peak above 0 dBFS is inter-sample clipping: the samples fit, the
		// reconstructed waveform does not. Not the same as a loud master, and the
		// only one of the two that is a defect.
		if au.TruePeakDBFS != nil && *au.TruePeakDBFS > 0 {
			item.Detail = fmt.Sprintf("true peak +%.1f dBFS", *au.TruePeakDBFS)
			clipping = append(clipping, item)
		}
	}

	var missingArt, missingMbid []healthItem
	for _, id := range albumOrder {
		a := albums[id]
		it := healthItem{AlbumID: id, Title: a.album, Subtitle: a.artist}
		if !a.art {
			missingArt = append(missingArt, it)
		}
		if !a.mbid {
			missingMbid = append(missingMbid, it)
		}
	}

	unmatched, err := d.Matches.NonMatched(ctx)
	if err != nil {
		return nil, err
	}
	// Twice the veto threshold: everything below it is already `review`, so this
	// band is "settled, but the runner-up was close" — the matches worth a human
	// glance. Read from the same setting the matcher vetoes on so calibrating one
	// cannot silently empty the other.
	_, minSep := enrich.Thresholds(ctx, d.Settings)
	lowSep, err := d.Matches.LowSeparation(ctx, 2*minSep)
	if err != nil {
		return nil, err
	}

	return map[string]any{
		"counts": map[string]int{
			"tracks":        len(ts),
			"albums":        len(albums),
			"analysed":      analysed,
			"fingerprinted": fingerprinted,
			"identified":    identified,
		},
		"issues": []healthIssue{
			issue("unmatched", decisionItems(unmatched, false)),
			issue("lowSeparation", decisionItems(lowSep, true)),
			issue("missingArt", missingArt),
			issue("missingMbid", missingMbid),
			issue("suspect", suspect),
			issue("clipping", clipping),
			issue("unanalysed", unanalysed),
		},
	}, nil
}

// dupeView is one duplicate group, resolved from track ids to something worth
// looking at. `exact` distinguishes "the decoded audio is byte-identical" from
// "AcoustID says this is the same recording", which are different enough
// findings that collapsing them would make the list unreadable.
type dupeView struct {
	Key    string      `json:"key"`
	Exact  bool        `json:"exact"`
	Tracks []dupeTrack `json:"tracks"`
}

type dupeTrack struct {
	ID            string `json:"id"`
	AlbumID       string `json:"albumId"`
	Title         string `json:"title"`
	Artist        string `json:"artist"`
	Album         string `json:"album"`
	Format        string `json:"format"`
	Duration      any    `json:"duration"`
	SampleRate    any    `json:"sampleRate"`
	BitsPerSample any    `json:"bitsPerSample"`
	Lossless      bool   `json:"lossless"`
}

// duplicates lists what the library owns more than one copy of. Read-only, by
// construction and by policy: MUSIC_DIR is mounted read-only and nothing here
// deletes anything. The user acts by going to the album.
//
// ponytail: no path is returned, because no view in this server returns one.
// The ceiling is that two copies in differently-named folders under the same
// album title look alike; format + sample rate + bit depth is what tells them
// apart today, and the upgrade is a path on this response alone.
func duplicates(ctx context.Context, d *Deps) ([]dupeView, error) {
	ts, err := mergedTracks(ctx, d)
	if err != nil {
		return nil, err
	}
	byID := make(map[string]map[string]any, len(ts))
	for _, t := range ts {
		byID[str(t["id"])] = t
	}

	exact, err := d.Audio.DuplicateMD5(ctx)
	if err != nil {
		return nil, err
	}
	near, err := d.FP.DuplicateAcoustID(ctx)
	if err != nil {
		return nil, err
	}

	// A group of byte-identical files also shares an AcoustID, so the near list
	// would repeat every exact group verbatim. Suppress those, and only those:
	// an AcoustID group that pulls in even one track the MD5 group missed is the
	// interesting case (the FLAC and its MP3) and stays.
	seen := map[string]bool{}
	for _, g := range exact {
		for _, id := range g.TrackIDs {
			seen[id] = true
		}
	}

	out := []dupeView{}
	add := func(g repo.DupeGroup, isExact bool) {
		var tracks []dupeTrack
		for _, id := range g.TrackIDs {
			t, ok := byID[id]
			if !ok { // analysed row for a track a later scan removed
				continue
			}
			ll, _ := t["lossless"].(bool)
			tracks = append(tracks, dupeTrack{
				ID: id, AlbumID: str(t["albumId"]), Title: str(t["title"]),
				Artist: str(t["artist"]), Album: str(t["album"]), Format: str(t["format"]),
				Duration: t["duration"], SampleRate: t["sampleRate"],
				BitsPerSample: t["bitsPerSample"], Lossless: ll,
			})
		}
		if len(tracks) < 2 { // no longer a duplicate once the vanished rows are dropped
			return
		}
		sort.SliceStable(tracks, func(i, j int) bool { return tracks[i].ID < tracks[j].ID })
		out = append(out, dupeView{Key: g.Key, Exact: isExact, Tracks: tracks})
	}
	for _, g := range exact {
		add(g, true)
	}
	for _, g := range near {
		fresh := false
		for _, id := range g.TrackIDs {
			if !seen[id] {
				fresh = true
				break
			}
		}
		if fresh {
			add(g, false)
		}
	}
	return out, nil
}

// registerHealth mounts the two read-only diagnostics. Both are plain GETs with
// no job behind them: everything they report was measured by the analyze,
// fingerprint and match passes that already have their own endpoints.
func registerHealth(mux *http.ServeMux, d *Deps) {
	mux.HandleFunc("GET /api/library/health", func(w http.ResponseWriter, r *http.Request) {
		h, err := libraryHealth(r.Context(), d)
		if err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, http.StatusOK, h)
	})

	mux.HandleFunc("GET /api/library/duplicates", func(w http.ResponseWriter, r *http.Request) {
		groups, err := duplicates(r.Context(), d)
		if err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, http.StatusOK, groups)
	})
}
