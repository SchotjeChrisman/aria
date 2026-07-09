package api

import (
	"context"
	"fmt"
	"hash/fnv"
	"math/rand"
	"net/http"
	"time"
)

func init() { register(registerMixes) }

func registerMixes(mux *http.ServeMux, d *Deps) {
	mux.HandleFunc("GET /api/mixes", func(w http.ResponseWriter, r *http.Request) { mixes(w, r, d) })
}

// mixes builds four ranked trackId lists per profile. Daily/weekly are
// artist-affinity mixes (recent artists -> their whole discography in-library)
// with a date-seeded deterministic shuffle so a mix is stable within its period
// and rotates after. Monthly/yearly are straight play-count rankings.
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

	daily, err := artistMix(ctx, d, pid, dayCut, seed(now.Format("2006-01-02")+pid))
	if err != nil {
		fail(w, err)
		return
	}
	weekly, err := artistMix(ctx, d, pid, weekCut, seed(fmt.Sprintf("%dW%02d", isoWeekY, isoWeek)+pid))
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

// artistMix: distinct artists played since cut -> every in-library track by
// those artists -> seeded shuffle -> cap 50. Empty window falls back to
// favourites, then random tracks.
func artistMix(ctx context.Context, d *Deps, pid, cut string, s int64) ([]string, error) {
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

func seed(s string) int64 {
	h := fnv.New64a()
	h.Write([]byte(s))
	return int64(h.Sum64())
}
