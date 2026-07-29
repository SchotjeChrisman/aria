package api

import (
	"context"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"math/rand"
	"net/http"
	"slices"
	"time"
)

func init() { register(registerMixes) }

func registerMixes(mux *http.ServeMux, d *Deps) {
	mux.HandleFunc("GET /api/mixes", func(w http.ResponseWriter, r *http.Request) { mixes(w, r, d) })
}

// mixes builds four ranked trackId lists per profile. Daily/weekly are
// artist-affinity mixes (recent artists -> their whole discography in-library)
// with a date-seeded deterministic shuffle so a mix is stable within its period
// and rotates after, then ListenBrainz popularity promotes recognisable
// recordings within that order. Monthly/yearly are straight play-count
// rankings and stay that way — they mean "what you played", and mixing global
// popularity into them would quietly change what the number says.
// ponytail: monthly/yearly recomputed per request; cache if hot.
func mixes(w http.ResponseWriter, r *http.Request, d *Deps) {
	ctx := r.Context()
	pid := r.URL.Query().Get("profileId")
	if pid != "" {
		p, err := d.Profiles.ByID(ctx, pid)
		if err != nil {
			fail(w, err)
			return
		}
		if p == nil {
			http.Error(w, "Not Found", http.StatusNotFound)
			return
		}
	}

	// ISO timestamp cutoffs compare lexicographically (same as stats).
	now := time.Now()
	dayCut := now.Add(-24 * time.Hour).UTC().Format("2006-01-02T15:04:05.000Z")
	weekCut := now.Add(-7 * 24 * time.Hour).UTC().Format("2006-01-02T15:04:05.000Z")
	monthCut := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, now.Location()).
		UTC().Format("2006-01-02T15:04:05.000Z")
	yearCut := time.Date(now.Year(), 1, 1, 0, 0, 0, 0, now.Location()).
		UTC().Format("2006-01-02T15:04:05.000Z")

	isoWeekY, isoWeek := now.ISOWeek()

	pop, err := popularTracks(ctx, d)
	if err != nil {
		fail(w, err)
		return
	}

	daily, err := artistMix(ctx, d, pid, dayCut, seed(now.Format("2006-01-02")+pid), pop)
	if err != nil {
		fail(w, err)
		return
	}
	weekly, err := artistMix(ctx, d, pid, weekCut, seed(fmt.Sprintf("%dW%02d", isoWeekY, isoWeek)+pid), pop)
	if err != nil {
		fail(w, err)
		return
	}
	monthly, err := countMix(ctx, d, pid, monthCut, 50)
	if err != nil {
		fail(w, err)
		return
	}
	yearly, err := countMix(ctx, d, pid, yearCut, 100)
	if err != nil {
		fail(w, err)
		return
	}

	writeJSON(w, http.StatusOK, map[string][]string{
		"daily":   daily,
		"weekly":  weekly,
		"monthly": monthly,
		"yearly":  yearly,
	})
}

const mixScope = `(?1 = '' OR p.profileId = ?1)`

// popularTracks returns the ids of library tracks whose recording MBID appears
// in some cached ListenBrainz "popular" doc — i.e. tracks the wider world
// actually listens to, as opposed to the live sets and alternate takes that
// share an artist with them. Empty (and cheap) when nothing is cached yet or
// no file carries a recording MBID, which is exactly today's behaviour.
// ponytail: rebuilt per request from the whole cache kind; memoize next to
// newReleases if /api/mixes ever gets hot.
func popularTracks(ctx context.Context, d *Deps) (map[string]bool, error) {
	docs, err := d.EnrichCache.ListKind(ctx, "popular")
	if err != nil || len(docs) == 0 {
		return nil, err
	}
	rec := map[string]bool{}
	for _, raw := range docs {
		var doc struct {
			Top []string `json:"top"`
		}
		if json.Unmarshal(raw, &doc) != nil {
			continue
		}
		for _, m := range doc.Top {
			rec[m] = true
		}
	}
	rows, err := d.DB.QueryContext(ctx, `SELECT id, mbRecordingId FROM tracks WHERE mbRecordingId <> ''`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]bool{}
	for rows.Next() {
		var id, mbid string
		if err := rows.Scan(&id, &mbid); err != nil {
			return nil, err
		}
		if rec[mbid] {
			out[id] = true
		}
	}
	return out, rows.Err()
}

// artistMix: distinct artists played since cut -> every in-library track by
// those artists -> seeded shuffle -> globally-popular recordings floated to the
// front -> cap 50. Empty window falls back to favourites, then random tracks.
func artistMix(ctx context.Context, d *Deps, pid, cut string, s int64, pop map[string]bool) ([]string, error) {
	ids, err := queryIDs(ctx, d, `
		SELECT t2.id FROM tracks t2 WHERE t2.artist <> '' AND t2.artist IN (
			SELECT DISTINCT t.artist FROM plays p JOIN tracks t ON t.id = p.trackId
			WHERE `+mixScope+` AND p.at >= ?2 AND t.artist <> ''
		)`, pid, cut)
	if err != nil {
		return nil, err
	}
	if len(ids) == 0 {
		// no recent plays: favourites, else random
		ids, err = queryIDs(ctx, d, `SELECT id FROM tracks WHERE favourite = 1`)
		if err != nil {
			return nil, err
		}
		if len(ids) == 0 {
			ids, err = queryIDs(ctx, d, `SELECT id FROM tracks`)
			if err != nil {
				return nil, err
			}
		}
	}
	rng := rand.New(rand.NewSource(s))
	rng.Shuffle(len(ids), func(i, j int) { ids[i], ids[j] = ids[j], ids[i] })
	// Stable partition, not a sort by popularity: the shuffle is the feature
	// (the mix has to rotate day to day), so ranking may only decide which
	// bucket a track lands in, never its order inside the bucket. Partitioning
	// before the cap is deliberate — a recognisable track sitting at shuffled
	// position 800 is exactly the one worth promoting into the 50.
	if len(pop) > 0 {
		slices.SortStableFunc(ids, func(a, b string) int {
			return btoi(pop[b]) - btoi(pop[a])
		})
	}
	if len(ids) > 50 {
		ids = ids[:50]
	}
	return ids, nil
}

// countMix: known tracks played since cut, ranked by play count. Ties break on
// first-ever play (MIN(p.id)), matching stats.go.
func countMix(ctx context.Context, d *Deps, pid, cut string, limit int) ([]string, error) {
	return queryIDs(ctx, d, `
		SELECT p.trackId FROM plays p JOIN tracks t ON t.id = p.trackId
		WHERE `+mixScope+` AND p.at >= ?2
		GROUP BY p.trackId ORDER BY COUNT(*) DESC, MIN(p.id) LIMIT ?3`, pid, cut, limit)
}

func queryIDs(ctx context.Context, d *Deps, q string, args ...any) ([]string, error) {
	rows, err := d.DB.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

func btoi(b bool) int {
	if b {
		return 1
	}
	return 0
}

func seed(s string) int64 {
	h := fnv.New64a()
	h.Write([]byte(s))
	return int64(h.Sum64())
}
