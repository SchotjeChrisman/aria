// Package fingerprint computes Chromaprint fingerprints with the bundled fpcalc
// and resolves them against AcoustID.
//
// It is its own job rather than a phase of internal/analyze, for reasons that
// are each sufficient: fpcalc costs ~64 ms/file and is capped at the first 120 s
// regardless of track length, where the analyze decode is ~941 ms for a 300 s
// file and scales with duration — folding a 7-minute job into an hours-long one
// would delay the AcoustID hit rate the matching work is blocked on until after
// an overnight decode. The two have different feature gates (ffmpeg vs fpcalc,
// and a deployment can have either). And the lookup half is rate-limited,
// retryable, needs a key that may arrive weeks later, and must re-run without
// re-fingerprinting anything, which Analyzer's pending-set model has no concept
// of. What they share is the shape of Run/Status/setPhase/step/notify — about
// 60 lines, already duplicated between Enricher and Analyzer, and factoring it
// out would be an abstraction over three jobs with three phase vocabularies.
//
// Nothing here writes to the library: fpcalc opens files read-only and every
// result lives in the DB.
package fingerprint

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"

	"aria/internal/enrich"
	"aria/internal/repo"
)

// batchSize is fingerprints per AcoustID request. The server's
// MAX_RESULTS_PER_FINGERPRINT_QUERY is 10 and a batch of 10 real fingerprints is
// ~26 KB of POST body; at 2.5 req/s that is ~14 min for a 25k library against
// 2.3 h unbatched.
const batchSize = 10

// parseFPCalc reads `fpcalc -json` stdout: exactly one JSON object,
// {"duration": 300.00, "fingerprint": "AQADtE..."}. duration is the FULL file
// length even though only the first 120 s are fingerprinted, which is what
// AcoustID wants.
//
// Every fpcalc failure — missing file, undecodable data, and "Empty
// fingerprint" for anything under ~3 s of audio — exits 2 and writes NOTHING to
// stdout, so an empty or unparseable stdout is the only failure signal needed.
func parseFPCalc(stdout string) (fp string, duration int, err error) {
	var raw struct {
		Duration    float64 `json:"duration"`
		Fingerprint string  `json:"fingerprint"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(stdout)), &raw); err != nil {
		return "", 0, fmt.Errorf("fpcalc output: %w", err)
	}
	if raw.Fingerprint == "" {
		return "", 0, fmt.Errorf("fpcalc produced no fingerprint")
	}
	// Whole seconds: AcoustID's duration parameter is an int, and its
	// maxdurationdiff tolerance is 7 s, so sub-second precision is noise.
	return raw.Fingerprint, int(math.Round(raw.Duration)), nil
}

type Fingerprinter struct {
	fpcalc, musicDir string
	fp               *repo.FP
	ac               *enrich.AcoustID
	workers          int
	log              func(string)

	// Notify is called after every status change; main wires it to the SSE hub's
	// `fingerprint` event. Same contract as Enricher.Notify and Analyzer.Notify.
	Notify func(status any)
	// Busy, when set, reports that a library scan is in flight; the pass holds
	// off between files rather than fighting the scanner for the same disk.
	Busy func() bool

	mu      sync.Mutex
	running bool
	phase   string
	done    int
	total   int
}

// New wires a Fingerprinter. Construct it only when fpcalc actually runs: a nil
// *Fingerprinter in Deps IS the feature gate, exactly as a nil *Analyzer is.
// key may be "", which leaves the lookup half permanently dark and is the
// normal state — no AcoustID key ships with Aria.
func New(fpcalc, musicDir string, fp *repo.FP, key string) *Fingerprinter {
	// Same NumCPU/2 reasoning as the analyzer: the user is listening to music
	// while this runs, so half the box stays free for transcodes and playback.
	// fpcalc is 64 ms/file, so even one worker would finish a 25k library in
	// ~27 min; the pool is about not monopolising the disk, not about speed.
	return &Fingerprinter{
		fpcalc: fpcalc, musicDir: musicDir, fp: fp, ac: enrich.NewAcoustID(key),
		workers: max(1, runtime.NumCPU()/2),
		log:     func(m string) { log.Printf("fingerprint: %s", m) },
		phase:   "idle",
	}
}

// Status reports {"phase","done","total","running"} — deliberately the same
// shape as EnrichStatus and AnalyzeStatus so the SSE payload and the client
// progress widget need no third deserialiser.
func (f *Fingerprinter) Status() any {
	f.mu.Lock()
	defer f.mu.Unlock()
	return map[string]any{"phase": f.phase, "done": f.done, "total": f.total, "running": f.running}
}

func (f *Fingerprinter) setPhase(phase string, total int) {
	f.mu.Lock()
	f.phase, f.total, f.done = phase, total, 0
	f.mu.Unlock()
	f.notify()
}

func (f *Fingerprinter) step(n int) {
	f.mu.Lock()
	f.done += n
	f.mu.Unlock()
	f.notify()
}

// notify runs outside the mutex: Status() takes it.
func (f *Fingerprinter) notify() {
	if f.Notify != nil {
		f.Notify(f.Status())
	}
}

// Run is one incremental pass: fingerprint every file whose bytes moved, then
// look up every fingerprint never sent to AcoustID. Single-flight, like
// Enricher.Run and Analyzer.Run — POST /api/fingerprint is fire-and-forget, so
// a second call while one is in flight is a silent no-op.
func (f *Fingerprinter) Run(ctx context.Context) error {
	f.mu.Lock()
	if f.running {
		f.mu.Unlock()
		return nil
	}
	f.running = true
	f.mu.Unlock()
	f.notify()
	defer func() {
		f.mu.Lock()
		f.running, f.phase = false, "idle"
		f.mu.Unlock()
		f.notify() // the idle frame is what tells clients to refresh
	}()

	if err := f.fingerprintAll(ctx); err != nil {
		return err
	}
	return f.lookupAll(ctx)
}

func (f *Fingerprinter) fingerprintAll(ctx context.Context) error {
	pending, err := f.fp.ListPendingFP(ctx)
	if err != nil {
		return err
	}
	f.setPhase("fingerprint", len(pending))
	if len(pending) == 0 {
		return nil
	}
	f.log(fmt.Sprintf("%d files to fingerprint on %d workers", len(pending), f.workers))

	jobs := make(chan repo.PendingFP)
	var wg sync.WaitGroup
	for i := 0; i < f.workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for p := range jobs {
				if err := f.one(ctx, p); err != nil && ctx.Err() == nil {
					// A file too short to fingerprint (under ~3 s) or corrupt
					// must not end the pass. It stays pending and is retried, at
					// 64 ms a go — cheap enough that a permanent-failure marker
					// would cost more schema than it saves.
					f.log(fmt.Sprintf("%s: %v", p.Path, err))
				}
				f.step(1)
			}
		}()
	}
dispatch:
	for _, p := range pending {
		// Same courtesy as the analyzer: nothing new starts while a scan walks
		// the same disk. The skip rule is mtime+size, so a row rewritten mid-pass
		// simply fails the freshness test next pass and is redone.
		for f.Busy != nil && f.Busy() {
			select {
			case <-ctx.Done():
				break dispatch
			case <-time.After(5 * time.Second):
			}
		}
		if ctx.Err() != nil {
			break
		}
		jobs <- p
	}
	close(jobs)
	wg.Wait()
	return ctx.Err()
}

// one fingerprints a single file and stores the result.
func (f *Fingerprinter) one(ctx context.Context, p repo.PendingFP) error {
	// fpcalc is 64 ms on a 300 s FLAC and is capped at 120 s of audio no matter
	// how long the file is, so a minute is ~1000x headroom; it exists only to
	// bound a corrupt file that makes it spin.
	fileCtx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()

	// -length 120 is already fpcalc's default. It is passed explicitly to PIN
	// it: AcoustID's index is built over the first 120 s, and a future default
	// change would silently invalidate every stored fingerprint without moving
	// mtime or size, so nothing would ever recompute them.
	cmd := exec.CommandContext(fileCtx, f.fpcalc, "-json", "-length", "120",
		filepath.Join(f.musicDir, p.Path))
	var outBuf, errBuf bytes.Buffer
	cmd.Stdout, cmd.Stderr = &outBuf, &errBuf
	if err := cmd.Start(); err != nil {
		return err
	}
	// Be polite on a NAS the user is also listening through, exactly as the
	// analyzer does — distroless has no `nice` binary, so this is the syscall,
	// and nonroot can always raise niceness.
	syscall.Setpriority(syscall.PRIO_PROCESS, cmd.Process.Pid, 10)
	runErr := cmd.Wait()

	fpStr, dur, err := parseFPCalc(outBuf.String())
	if err != nil {
		// Every fpcalc failure writes its reason to stderr and nothing to
		// stdout, so stderr is the only useful diagnostic. runErr alone would
		// read as a bare "exit status 2".
		if msg := strings.TrimSpace(errBuf.String()); msg != "" {
			return fmt.Errorf("%s", msg)
		}
		if runErr != nil {
			return runErr
		}
		return err
	}
	return f.fp.PutFP(ctx, p.ID, fpStr, dur, p.Mtime, p.Size,
		time.Now().UTC().Format("2006-01-02T15:04:05.000Z"))
}

// lookupAll resolves stored fingerprints against AcoustID in batches.
//
// With no key this is completely silent: no phase change worth watching, no log
// line, no rows touched. That is what makes "no key" indistinguishable from
// "not looked up yet" in the DB, so setting a key later needs no backfill.
func (f *Fingerprinter) lookupAll(ctx context.Context) error {
	if !f.ac.Enabled() {
		return nil
	}
	n, err := f.fp.CountPendingLookup(ctx)
	if err != nil {
		return err
	}
	f.setPhase("lookup", n)
	if n == 0 {
		return nil
	}
	f.log(fmt.Sprintf("%d fingerprints to look up", n))

	for ctx.Err() == nil {
		batch, err := f.fp.ListPendingLookup(ctx, batchSize)
		if err != nil {
			return err
		}
		if len(batch) == 0 {
			return nil
		}
		qs := make([]enrich.FPQuery, len(batch))
		for i, b := range batch {
			qs[i] = enrich.FPQuery{Fingerprint: b.Fingerprint, Duration: b.Duration}
		}
		res, err := f.ac.Lookup(ctx, qs)
		if err != nil {
			// Lookup errors are systematic far more often than not (invalid key,
			// rate limit, outage), so the pass stops rather than burning through
			// 2,500 batches to fail identically each time. The reason is recorded
			// on this batch's rows with lookedUpAt still NULL, so it is visible
			// and every row is retried next pass.
			for _, b := range batch {
				f.fp.PutLookupError(ctx, b.TrackID, err.Error())
			}
			f.log(fmt.Sprintf("lookup stopped: %v", err))
			return nil
		}
		if len(res) != len(batch) {
			// Lookup allocates one slot per query, so this cannot happen —
			// asserted rather than indexed blindly, because getting it wrong
			// would write one track's AcoustID onto another's row.
			return fmt.Errorf("acoustid: %d results for %d queries", len(res), len(batch))
		}
		now := time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
		for i, b := range batch {
			var id *string
			var score *float64
			// res is index-aligned with qs by Lookup itself; a fingerprint the
			// server dropped comes back as an empty FPResult, which is stored as
			// a real "no match" so it is not asked again every pass.
			if best := res[i].Best(); best != nil {
				id, score = &best.ID, &best.Score
			}
			if err := f.fp.PutLookup(ctx, b.TrackID, id, score, res[i].RecordingsJSON(), now); err != nil {
				return err
			}
		}
		f.step(len(batch))
	}
	return ctx.Err()
}
