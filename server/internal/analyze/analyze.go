// Package analyze reads facts off the decoded audio: EBU R128 loudness (for
// ReplayGain), true peak, and the codec/rate/depth ffmpeg actually sees —
// which is not always what the container tags claim.
//
// One ffmpeg invocation per file yields all of it. The `Stream #0:0 ... Audio:`
// input banner and the ebur128 Summary block both land on stderr from the same
// run, so no ffprobe is needed (the image only copies /ffmpeg).
//
// Nothing here writes to the library: ffmpeg opens the file read-only and the
// results live in the DB, never in file tags.
package analyze

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"math"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"aria/internal/repo"
)

// rgReference is the ReplayGain 2.0 reference level in LUFS. Only the gain
// arithmetic uses it; the DB stores raw LUFS so this stays a decision instead
// of being frozen into 25,000 rows.
const rgReference = -18.0

// absoluteGate is EBU R128's -70 LUFS floor. ebur128 prints it verbatim when
// NO 400 ms block passed gating — digital silence, or a file shorter than one
// block. It means "unmeasurable", not "very quiet": treated as a number it
// becomes a +52 dB ReplayGain and takes the user's speakers off the wall.
const absoluteGate = -70.0

// ---------------------------------------------------------------- arithmetic

// TrackGain is the ReplayGain 2.0 track gain in dB, nil when the track was
// never measured (or measured as unmeasurable).
func TrackGain(lufs *float64) *float64 {
	if lufs == nil {
		return nil
	}
	g := rgReference - *lufs
	return &g
}

// TrackPeak converts a true peak in dBFS to RG2's linear amplitude (1.0 = FS).
// Values above 1.0 are normal and meaningful: they are what a gain stage has
// to respect to avoid clipping.
func TrackPeak(dbfs *float64) *float64 {
	if dbfs == nil {
		return nil
	}
	p := math.Pow(10, *dbfs/20)
	return &p
}

// AlbumTrack is one track's contribution to its album's aggregate.
type AlbumTrack struct {
	LUFS     *float64
	PeakDBFS *float64
	Duration float64 // seconds; the weight
}

// AlbumGain is the album gain in dB, nil when no track of the album has a
// usable measurement. Unmeasurable tracks are skipped rather than counted as
// silence, which would drag the mean down and over-boost the whole album.
//
// ponytail: duration-weighted energy mean of the per-track values. Measured
// against a true single-pass album measurement: 0.05 dB out on a 4-LU-spread
// album, 2.97 dB out on a 20-LU-spread one, always reading quiet (so gain
// reads high, i.e. toward clipping). The divergence is structural, not
// arithmetic — integrated loudness is relative-gated per track, so blocks that
// counted toward a quiet track's own I are dropped entirely from a real album
// measurement, and the weight should be gated block count, which ffmpeg does
// not report. Exact needs one concatenated decode per album — `ffmpeg -f
// concat -safe 0 -i list.txt -map 0:a:0 -af ebur128=peak=true:framelog=quiet
// -f null -` — which doubles the analysis cost. Upgrade when a classical album
// measurably over-boosts.
func AlbumGain(ts []AlbumTrack) *float64 {
	var energy, weight float64
	for _, t := range ts {
		if t.LUFS == nil {
			continue
		}
		// a zero/absent duration must still count, or a track with no stored
		// duration silently vanishes from its own album's gain
		d := t.Duration
		if d <= 0 {
			d = 1
		}
		energy += d * math.Pow(10, *t.LUFS/10)
		weight += d
	}
	if weight == 0 || energy <= 0 {
		return nil
	}
	// The -0.691 BS.1770 offset cancels identically on both sides of the log,
	// so this is algebraically exact for a mean of energies. What is not exact
	// is which energies get counted — see the ponytail note above.
	g := rgReference - 10*math.Log10(energy/weight)
	return &g
}

// AlbumPeak is the loudest true peak on the album, as RG2 linear amplitude.
// Exact, no caveat: max is max.
func AlbumPeak(ts []AlbumTrack) *float64 {
	var out *float64
	for _, t := range ts {
		if t.PeakDBFS == nil {
			continue
		}
		if out == nil || *t.PeakDBFS > *out {
			v := *t.PeakDBFS
			out = &v
		}
	}
	return TrackPeak(out)
}

// ------------------------------------------------------------------- parsing

// losslessCodecs is keyed on what ffmpeg reports decoding, not on the file
// extension — an .m4a holding AAC and an .m4a holding ALAC are the same
// container. pcm_* and dsd_* are matched by prefix below.
var losslessCodecs = map[string]bool{
	"flac": true, "alac": true, "wavpack": true, "ape": true, "tta": true,
	"mlp": true, "truehd": true, "wmalossless": true, "shorten": true,
}

func isLossless(codec string) bool {
	return losslessCodecs[codec] ||
		strings.HasPrefix(codec, "pcm_") || strings.HasPrefix(codec, "dsd_")
}

// channelCounts maps ffmpeg's layout NAMES (it prints a layout, never a
// number) to channel counts. Unknown layouts stay nil rather than guessing.
var channelCounts = map[string]int{
	"mono": 1, "stereo": 2, "2.1": 3, "quad": 4, "4.0": 4,
	"5.0": 5, "5.0(side)": 5, "5.1": 6, "5.1(side)": 6,
	"6.1": 7, "7.1": 8, "7.1(wide)": 8, "7.1(wide-side)": 8,
}

// bitDepths maps ffmpeg sample formats to a source bit depth. Float formats
// map to nothing on purpose: a float decode target carries no meaningful
// source depth, and every lossy codec lands there.
var bitDepths = map[string]int{
	"u8": 8, "u8p": 8, "s16": 16, "s16p": 16, "s32": 32, "s32p": 32,
	"s64": 64, "s64p": 64,
}

// probe is what one ffmpeg run tells us. Every field is independently
// optional: a 50 ms file has a valid true peak and no valid loudness, so
// nothing here may be gated on anything else here.
type probe struct {
	I, LRA, Peak                        *float64
	Codec                               string
	SampleRate, BitsPerSample, Channels *int
	MD5                                 string // decoded-audio hash, "" when ffmpeg gave none
}

// parseMD5 reads the md5 muxer's entire stdout, which is exactly
// "MD5=<32 lowercase hex>\n" (verified with od -c: no other byte is written).
// Anything that is not exactly that shape yields "", which is stored as an
// empty string so the file is not re-decoded forever, per 009_audio_md5.sql.
func parseMD5(stdout string) string {
	h, ok := strings.CutPrefix(strings.TrimSpace(stdout), "MD5=")
	if !ok || len(h) != 32 {
		return ""
	}
	for _, c := range h {
		// lowercase only: the hash is an equality key, and accepting both cases
		// would let one ffmpeg build's output silently fail to match another's.
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return ""
		}
	}
	return h
}

// parse reads one ffmpeg stderr dump. Format notes that the parser depends on:
//   - Summary values are right-aligned in a fixed-width column, so the run of
//     spaces after the label varies; strings.Fields normalises that away.
//   - the literal "Threshold:" appears TWICE with different meanings (the
//     integrated gate, then the LRA gate), so it is never keyed on. "I:",
//     "LRA:" and "Peak:" are each unique as Fields[0]; "LRA low:"/"LRA high:"
//     split to "LRA" (no colon) and the "True peak:" header to "True".
func parse(stderr string) probe {
	var p probe
	gotStream := false
	for _, line := range strings.Split(stderr, "\n") {
		// The first ": Audio: " line is by definition the input stream that
		// -map 0:a:0 selected: "Input #0" always precedes "Output #0", and the
		// output banner (the null muxer, "pcm_s16le, 44100 Hz, ...") is a
		// perfect match that describes nothing about the file. Matching the
		// substring rather than anchoring on "  Stream #0:0: " is what keeps
		// MP4's "Stream #0:0[0x1](und):" — every ALAC and AAC file — in scope,
		// while the "Stream #0:0 -> #0:0" mapping line has no ": Audio: " and
		// is excluded for free.
		if !gotStream {
			if _, rest, ok := strings.Cut(line, ": Audio: "); ok {
				parseStream(&p, rest)
				gotStream = true
				continue
			}
		}
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		switch f[0] {
		case "I:":
			// -70.0 is the absolute gate, i.e. nothing passed gating.
			if v, err := strconv.ParseFloat(f[1], 64); err == nil && v > absoluteGate && !math.IsInf(v, 0) {
				p.I = &v
			}
		case "LRA:":
			// 0.0 LU on a short or constant-level file is a real value.
			if v, err := strconv.ParseFloat(f[1], 64); err == nil && !math.IsInf(v, 0) {
				p.LRA = &v
			}
		case "Peak:":
			// "-inf" parses cleanly to math.Inf(-1) and even survives the
			// 10^(x/20) peak arithmetic (it is exactly 0) — but encoding/json
			// refuses to marshal it, so it is dropped here, at parse time,
			// rather than blowing up a handler three layers away.
			if v, err := strconv.ParseFloat(f[1], 64); err == nil && !math.IsInf(v, 0) {
				p.Peak = &v
			}
		}
	}
	return p
}

// parseStream reads the remainder of an input banner line after ": Audio: ",
// e.g. "aac (LC) (mp4a / 0x6134706D), 44100 Hz, stereo, fltp, 127 kb/s".
// Codec names carry spaces and parenthesised extras but never a comma inside
// them, so splitting on ", " first and taking the leading token second works
// where a regex over the whole line does not.
func parseStream(p *probe, rest string) {
	parts := strings.Split(rest, ", ")
	p.Codec, _, _ = strings.Cut(parts[0], " ")
	if len(parts) > 1 {
		if f := strings.Fields(parts[1]); len(f) == 2 && f[1] == "Hz" {
			if n, err := strconv.Atoi(f[0]); err == nil && n > 0 {
				p.SampleRate = &n
			}
		}
	}
	if len(parts) > 2 {
		if n, ok := channelCounts[parts[2]]; ok {
			p.Channels = &n
		}
	}
	if len(parts) > 3 {
		// "s32 (24 bit)" is the one format whose real depth is narrower than
		// its container: 24-bit FLAC and 24-bit WAV both decode into s32.
		if parts[3] == "s32 (24 bit)" {
			n := 24
			p.BitsPerSample = &n
		} else if n, ok := bitDepths[parts[3]]; ok {
			p.BitsPerSample = &n
		}
	}
}

// toRow turns a probe into the row to store, computing `suspect` against what
// the scanner read off the container: an .m4a tagged ALAC that decodes as AAC,
// or a .flac whose taglib properties lie. Only non-nil stream values can
// contradict anything.
//
// suspect and LRA are read by the library health view and the quality
// smart-playlist predicates (api/health.go, api/playlists.go); codec is
// reported per track by the health view's suspect list, where "claims FLAC,
// decodes as AAC" is the whole message.
func toRow(pend repo.Pending, p probe) repo.TrackAudio {
	lossless := isLossless(p.Codec)
	suspect := p.Codec != "" && lossless != pend.Lossless
	neq := func(a, b *int) bool { return a != nil && b != nil && *a != *b }
	if neq(p.SampleRate, pend.SampleRate) || neq(p.BitsPerSample, pend.BitsPerSample) ||
		neq(p.Channels, pend.Channels) {
		suspect = true
	}
	return repo.TrackAudio{
		TrackID: pend.ID, IntegratedLUFS: p.I, LRA: p.LRA, TruePeakDBFS: p.Peak,
		Codec: p.Codec, SampleRate: p.SampleRate, BitsPerSample: p.BitsPerSample,
		Channels: p.Channels, Lossless: lossless, Suspect: suspect, AudioMD5: p.MD5,
	}
}

// ------------------------------------------------------------------ the job

type Analyzer struct {
	ffmpeg, musicDir string
	audio            *repo.Audio
	workers          int
	log              func(string)

	// Notify, when set before the server starts, is called after every status
	// change; main wires it to the SSE hub's `analyze` event. Same contract as
	// Enricher.Notify. The app's library watcher refreshes on the busy->idle
	// edge; nothing renders the intermediate done/total yet, which is what the
	// existing enrich progress row would grow into.
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

// New wires an Analyzer. Construct it only when ffmpeg resolves: a nil
// *Analyzer in Deps IS the feature gate, exactly as CanTranscode gates the
// stream tiers — a second boolean off the same LookPath would be a value that
// never varies independently.
func New(ffmpeg, musicDir string, audio *repo.Audio) *Analyzer {
	// ponytail: NumCPU/2 with no runtime feedback. The scanner takes all of
	// NumCPU and is right to — a scan is minutes and the user is watching it.
	// This is hours and the user is listening to music while it runs, so half
	// the box stays free for /api/stream transcodes and playback. The ceiling
	// is that a 2-core NAS analysing while transcoding will still stutter; the
	// upgrade is reading load and shrinking the pool, which needs a
	// measurement this box cannot make portably.
	w := max(1, runtime.NumCPU()/2)
	return &Analyzer{
		ffmpeg: ffmpeg, musicDir: musicDir, audio: audio, workers: w,
		log:   func(m string) { log.Printf("analyze: %s", m) },
		phase: "idle",
	}
}

// Status reports {"phase","done","total","running"} — deliberately the same
// shape as EnrichStatus so the SSE payload and the client progress widget need
// no second deserialiser, even though there is only ever one phase.
func (a *Analyzer) Status() any {
	a.mu.Lock()
	defer a.mu.Unlock()
	return map[string]any{"phase": a.phase, "done": a.done, "total": a.total, "running": a.running}
}

func (a *Analyzer) setPhase(phase string, total int) {
	a.mu.Lock()
	a.phase, a.total, a.done = phase, total, 0
	a.mu.Unlock()
	a.notify()
}

func (a *Analyzer) step() {
	a.mu.Lock()
	a.done++
	a.mu.Unlock()
	a.notify()
}

// notify runs outside the mutex: Status() takes it.
func (a *Analyzer) notify() {
	if a.Notify != nil {
		a.Notify(a.Status())
	}
}

// Run is one incremental analysis pass over every track whose bytes moved
// since it was last analysed. Single-flight: a second call while one is in
// flight is a silent no-op, like Enricher.Run — POST /api/analyze is
// fire-and-forget, not synchronous like POST /api/scan, so there is no 409 to
// report. Cancel ctx to stop; in-flight decodes die with it.
func (a *Analyzer) Run(ctx context.Context) error {
	a.mu.Lock()
	if a.running {
		a.mu.Unlock()
		return nil
	}
	a.running = true
	a.mu.Unlock()
	a.notify()
	defer func() {
		a.mu.Lock()
		a.running, a.phase = false, "idle"
		a.mu.Unlock()
		a.notify() // the idle frame is what tells clients to refresh
	}()

	pending, err := a.audio.ListPending(ctx)
	if err != nil {
		return err
	}
	a.setPhase("loudness", len(pending))
	if len(pending) == 0 {
		return nil
	}
	a.log(fmt.Sprintf("%d files to analyse on %d workers", len(pending), a.workers))

	jobs := make(chan repo.Pending)
	var wg sync.WaitGroup
	for i := 0; i < a.workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for p := range jobs {
				if err := a.one(ctx, p); err != nil && ctx.Err() == nil {
					// A corrupt or unreadable file must not end the pass; it
					// simply stays pending and is retried next time.
					a.log(fmt.Sprintf("%s: %v", p.Path, err))
				}
				a.step()
			}
		}()
	}
dispatch:
	for _, p := range pending {
		// Files already in flight finish; nothing new starts while a scan is
		// walking the same disk. A scan is minutes and this is hours, so the
		// pause costs nothing. No lock is needed for correctness — the skip
		// rule is mtime+size, so a row rewritten mid-pass just fails the
		// freshness test next pass and is redone. Worst case is one wasted
		// decode, never a wrong stored value.
		for a.Busy != nil && a.Busy() {
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

// one decodes a single file and stores the result.
func (a *Analyzer) one(ctx context.Context, p repo.Pending) error {
	// 10 minutes is ~120x headroom over the worst realistic file (a 3-hour DJ
	// set decodes in ~50 s at the measured 214x realtime); it exists only to
	// bound a corrupt file that makes ffmpeg spin, not to cap normal work.
	fileCtx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()

	// Every element is load-bearing:
	//   -nostdin        a corrupt file must not let ffmpeg block on the terminal
	//   -map 0:a:0      first audio stream, skipping an embedded cover-art mjpeg
	//   framelog=quiet  without it a 5-minute track emits ~3000 progress lines
	//                   (one per 100 ms); with it, 15 lines total
	//   -threads 1      N workers must mean N cores, not N x NumCPU. Costs
	//   -filter_threads 1   1.40s -> 1.57s on a 5-min flac. Take the predictability.
	// Do NOT add -loglevel error: the Summary block is logged at AV_LOG_INFO
	// and disappears entirely, silently, leaving every column NULL.
	//
	// The SECOND output is the decoded-audio MD5, hanging off the same single
	// decode — measured 941ms -> 969ms on a 300s FLAC (+2.7%), against +29% for
	// a second ffmpeg invocation. -af is per-output-stream (it is -filter:a), so
	// placing it before output 0 confines ebur128 to output 0 and output 1 hashes
	// the UNFILTERED decode. -c:a pcm_s32le is load-bearing: the md5 muxer's
	// default is pcm_s16le regardless of input, which would hash every hi-res
	// file at 16 bit and collide a 24-bit master with its own truncated copy.
	cmd := exec.CommandContext(fileCtx, a.ffmpeg,
		"-nostdin", "-hide_banner", "-nostats", "-threads", "1", "-filter_threads", "1",
		"-i", filepath.Join(a.musicDir, p.Path),
		"-map", "0:a:0", "-af", "ebur128=peak=true:framelog=quiet", "-f", "null", "-",
		"-map", "0:a:0", "-c:a", "pcm_s32le", "-f", "md5", "-")
	// Banner and Summary are on stderr, the md5 line is the only thing on stdout.
	var errBuf, outBuf bytes.Buffer
	cmd.Stderr = &errBuf
	cmd.Stdout = &outBuf
	if err := cmd.Start(); err != nil {
		return err
	}
	// Be polite on a NAS the user is also listening through. Distroless has no
	// shell and no `nice` binary, so this must be the syscall; nonroot can
	// always RAISE niceness (lowering needs CAP_SYS_NICE), which is the only
	// direction wanted. The Start/Setpriority race is microseconds against a
	// multi-second decode — ignore it, and ignore the error.
	// ponytail: ioprio_set is deliberately not attempted — no stdlib wrapper,
	// raw syscall numbers, and on an NFS-mounted library the ioprio class does
	// nothing anyway. Also: syscall.Setpriority does not exist on windows/js,
	// so a windows contributor gets a compile error here; the fix if it ever
	// bites is moving this line into nice_unix.go with a no-op sibling.
	syscall.Setpriority(syscall.PRIO_PROCESS, cmd.Process.Pid, 10)
	runErr := cmd.Wait()

	pr := parse(errBuf.String())
	// A truncated file exits 0 and still emits an MD5 over whatever decoded.
	// That partial hash is stored as-is: it is stable across runs and cannot
	// false-POSITIVE against a different file. The only cost is that a truncated
	// copy of X will not match X — a false negative in dedup, the harmless
	// direction. -xerror would fix it and would also change the loudness path's
	// failure behaviour, regressing a shipped feature for this.
	//
	// ponytail: lossless sources (FLAC/ALAC/WavPack/APE) decode bit-exactly so
	// their hash is stable across ffmpeg versions; lossy sources decode to float
	// and a decoder change can shift it. Ceiling: bumping the bundled ffmpeg
	// silently splits the lossy half of the library into two hash generations and
	// dedup under-reports. Upgrade: a settings key `audioMd5Gen`, bumped
	// alongside the ffmpeg bump, as one more OR in ListPending.
	pr.MD5 = parseMD5(outBuf.String())
	if runErr != nil && pr.Codec == "" {
		// ffmpeg failed before it even described the input: nothing worth
		// storing, and no row means it stays pending.
		return runErr
	}
	return a.audio.Put(ctx, toRow(p, pr), p.Mtime, p.Size,
		time.Now().UTC().Format("2006-01-02T15:04:05.000Z"))
}
