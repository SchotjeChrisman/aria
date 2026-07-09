package api

import (
	"net/http"
	"time"

	"aria/internal/enrich"
)

// ponytail: OPRA dataset cached 7 days in enrich_cache; a refetch failure
// serves whatever stale copy exists.
const opraTTL = 7 * 24 * time.Hour

var opra = enrich.NewOpra()

func init() { register(registerEq) }

func registerEq(mux *http.ServeMux, d *Deps) {
	mux.HandleFunc("GET /api/eq/opra", func(w http.ResponseWriter, r *http.Request) {
		cached, at, ok, err := d.EnrichCache.GetFetched(r.Context(), "opra", "db2")
		if err != nil {
			fail(w, err)
			return
		}
		if ok {
			if t, perr := time.Parse("2006-01-02T15:04:05.000Z", at); perr == nil && time.Since(t) < opraTTL {
				writeJSON(w, http.StatusOK, cached)
				return
			}
		}
		fresh, ferr := opra.Fetch(r.Context())
		if ferr != nil {
			if ok { // stale beats nothing
				writeJSON(w, http.StatusOK, cached)
				return
			}
			httpError(w, http.StatusBadGateway, "opra fetch failed: "+ferr.Error())
			return
		}
		if err := d.EnrichCache.Put(r.Context(), "opra", "db2", fresh, isoNow()); err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, http.StatusOK, fresh)
	})
}
