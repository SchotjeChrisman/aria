package analyze

import (
	"context"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"aria/internal/db"
	"aria/internal/repo"
)

// All the ffmpeg output below is real stderr captured from the command the
// Analyzer runs, against the repo's own sample files. Nothing here shells out.

const summaryCD = `  Stream #0:0: Audio: flac, 44100 Hz, mono, s16
[Parsed_ebur128_0 @ 0xaaaaf0a15a60] Summary:

  Integrated loudness:
    I:         -21.3 LUFS
    Threshold: -31.3 LUFS

  Loudness range:
    LRA:         0.0 LU
    Threshold:   0.0 LUFS
    LRA low:     0.0 LUFS
    LRA high:    0.0 LUFS

  True peak:
    Peak:      -18.1 dBFS
`

const summaryDynamic = `  Stream #0:0: Audio: flac, 44100 Hz, stereo, s32 (24 bit)
[Parsed_ebur128_0 @ 0xaaaaf0a15a60] Summary:

  Integrated loudness:
    I:         -15.1 LUFS
    Threshold: -25.1 LUFS

  Loudness range:
    LRA:        20.0 LU
    Threshold: -35.1 LUFS
    LRA low:   -35.1 LUFS
    LRA high:  -15.1 LUFS

  True peak:
    Peak:      -12.1 dBFS
`

const summaryClipped = `  Stream #0:0: Audio: flac, 44100 Hz, mono, s16
    I:          -0.0 LUFS
    Threshold: -10.0 LUFS
    LRA:         0.0 LU
    Peak:        0.4 dBFS
`

// 5 s of digital silence: the -70.0 absolute gate, and -inf true peak.
const summarySilence = `  Stream #0:0: Audio: flac, 44100 Hz, mono, s16
    I:         -70.0 LUFS
    Threshold:   0.0 LUFS
    LRA:         0.0 LU
    Peak:       -inf dBFS
`

// 0.05 s of sine: shorter than one 400 ms gating block, so no loudness — but
// the true peak is perfectly valid. The two must fail independently.
const summaryShort = `  Stream #0:0: Audio: flac, 44100 Hz, mono, s16
    I:         -70.0 LUFS
    Threshold:   0.0 LUFS
    LRA:         0.0 LU
    Peak:      -18.1 dBFS
`

func f(v float64) *float64 { return &v }
func i(v int) *int         { return &v }

func eqf(a *float64, b *float64) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return math.Abs(*a-*b) < 1e-9
}

func TestParseSummary(t *testing.T) {
	tests := []struct {
		name         string
		in           string
		i, lra, peak *float64
	}{
		{"normal", summaryCD, f(-21.3), f(0), f(-18.1)},
		{"dynamic range", summaryDynamic, f(-15.1), f(20), f(-12.1)},
		{"clipped, positive peak", summaryClipped, f(-0.0), f(0), f(0.4)},
		// -70.0 is "nothing passed the gate", not "very quiet"; -inf is
		// unmarshalable by encoding/json and must never leave the parser.
		{"silence: both unmeasurable", summarySilence, nil, f(0), nil},
		{"too short for a gating block: peak still valid", summaryShort, nil, f(0), f(-18.1)},
		{"empty input", "", nil, nil, nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			p := parse(tc.in)
			if !eqf(p.I, tc.i) {
				t.Errorf("I = %v, want %v", p.I, tc.i)
			}
			if !eqf(p.LRA, tc.lra) {
				t.Errorf("LRA = %v, want %v", p.LRA, tc.lra)
			}
			if !eqf(p.Peak, tc.peak) {
				t.Errorf("Peak = %v, want %v", p.Peak, tc.peak)
			}
		})
	}
}

func TestParseStream(t *testing.T) {
	tests := []struct {
		name           string
		in             string
		codec          string
		rate, bits, ch *int
	}{
		{"flac mono 16", "  Stream #0:0: Audio: flac, 44100 Hz, mono, s16",
			"flac", i(44100), i(16), i(1)},
		{"flac hi-res: s32 (24 bit) is 24, not 32", "  Stream #0:0: Audio: flac, 96000 Hz, mono, s32 (24 bit)",
			"flac", i(96000), i(24), i(1)},
		{"mp3: float decode carries no source depth", "  Stream #0:0: Audio: mp3, 44100 Hz, mono, fltp, 192 kb/s",
			"mp3", i(44100), nil, i(1)},
		{"5.1 layout is 6 channels", "  Stream #0:0: Audio: flac, 44100 Hz, 5.1, s32 (24 bit)",
			"flac", i(44100), i(24), i(6)},
		{"vorbis", "  Stream #0:0: Audio: vorbis, 44100 Hz, stereo, fltp, 112 kb/s",
			"vorbis", i(44100), nil, i(2)},
		{"opus has no bitrate field", "  Stream #0:0: Audio: opus, 48000 Hz, stereo, fltp",
			"opus", i(48000), nil, i(2)},
		{"pcm codec name carries parenthesised extras",
			"  Stream #0:0: Audio: pcm_s24le ([1][0][0][0] / 0x0001), 88200 Hz, stereo, s32 (24 bit), 4233 kb/s",
			"pcm_s24le", i(88200), i(24), i(2)},
		// The MP4 forms: a regex anchored on "^  Stream #0:0: Audio: " misses
		// every ALAC and AAC file in the library.
		{"mp4 alac with stream id and language",
			"  Stream #0:0[0x1](und): Audio: alac (alac / 0x63616C61), 44100 Hz, stereo, s16p, 136 kb/s (default)",
			"alac", i(44100), i(16), i(2)},
		{"mp4 aac with a space in the codec name",
			"  Stream #0:0[0x1](und): Audio: aac (LC) (mp4a / 0x6134706D), 44100 Hz, stereo, fltp, 127 kb/s (default)",
			"aac", i(44100), nil, i(2)},
		// The mapping line also says "Stream #0:0" but has no ": Audio: ".
		{"stream mapping line must not match",
			"  Stream #0:0 -> #0:0 (flac (native) -> pcm_s16le (native))",
			"", nil, nil, nil},
		{"unknown channel layout stays null",
			"  Stream #0:0: Audio: flac, 44100 Hz, 22.2, s16", "flac", i(44100), i(16), nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			p := parse(tc.in)
			if p.Codec != tc.codec {
				t.Errorf("codec = %q, want %q", p.Codec, tc.codec)
			}
			for _, c := range []struct {
				what      string
				got, want *int
			}{{"sampleRate", p.SampleRate, tc.rate}, {"bits", p.BitsPerSample, tc.bits}, {"channels", p.Channels, tc.ch}} {
				if (c.got == nil) != (c.want == nil) || (c.got != nil && *c.got != *c.want) {
					t.Errorf("%s = %v, want %v", c.what, c.got, c.want)
				}
			}
		})
	}
}

// The output banner is a perfect ": Audio: " match describing the null muxer,
// not the file. Input #0 always precedes Output #0, so first match wins.
func TestParseStreamInputWinsOverOutput(t *testing.T) {
	const both = `Input #0, flac, from '/music/a.flac':
  Duration: 00:00:02.00, start: 0.000000, bitrate: 583 kb/s
  Stream #0:0: Audio: flac, 96000 Hz, stereo, s32 (24 bit)
Stream mapping:
  Stream #0:0 -> #0:0 (flac (native) -> pcm_s16le (native))
Output #0, null, to 'pipe:':
  Stream #0:0: Audio: pcm_s16le, 44100 Hz, mono, s16, 705 kb/s
`
	p := parse(both)
	if p.Codec != "flac" || *p.SampleRate != 96000 || *p.BitsPerSample != 24 || *p.Channels != 2 {
		t.Fatalf("output banner won: %+v", p)
	}
}

// Real stderr from the two-output command on test-music/hires.flac, with the
// output banners in the order actually observed: the md5 muxer's banner printed
// BEFORE the null muxer's. The interleave is non-deterministic, which is exactly
// why parse must key on "the first ': Audio: ' line" and never count banners.
func TestParseStreamOutputBannersInterleave(t *testing.T) {
	const both = `Input #0, flac, from 'hires.flac':
  Duration: 00:00:02.00, start: 0.000000, bitrate: 794 kb/s
  Stream #0:0: Audio: flac, 96000 Hz, mono, s32 (24 bit)
Stream mapping:
  Stream #0:0 -> #0:0 (flac (native) -> pcm_s16le (native))
  Stream #0:0 -> #1:0 (flac (native) -> pcm_s32le (native))
Output #1, md5, to 'pipe:':
  Stream #1:0: Audio: pcm_s32le, 96000 Hz, mono, s32 (24 bit), 3072 kb/s
Output #0, null, to 'pipe:':
  Stream #0:0: Audio: pcm_s16le, 96000 Hz, mono, s16, 1536 kb/s
`
	p := parse(both)
	if p.Codec != "flac" || *p.SampleRate != 96000 || *p.BitsPerSample != 24 || *p.Channels != 1 {
		t.Fatalf("an output banner won: %+v", p)
	}
}

func TestParseMD5(t *testing.T) {
	tests := []struct {
		name, in, want string
	}{
		// exactly what the md5 muxer writes, verified with od -c
		{"real output", "MD5=2a75b09672dd942a457873379cf702b2\n", "2a75b09672dd942a457873379cf702b2"},
		{"no trailing newline", "MD5=a9c3549374b6efe75ea5d6bd370f08c9", "a9c3549374b6efe75ea5d6bd370f08c9"},
		{"empty stdout", "", ""},
		{"prefix only", "MD5=\n", ""},
		{"too short", "MD5=2a75b09672dd942a457873379cf702\n", ""},
		{"too long", "MD5=2a75b09672dd942a457873379cf702b2ff\n", ""},
		// an equality key must not match itself case-insensitively by accident
		{"uppercase rejected", "MD5=2A75B09672DD942A457873379CF702B2\n", ""},
		{"non-hex", "MD5=zz75b09672dd942a457873379cf702b2!\n", ""},
		{"garbage", "not a hash at all\n", ""},
		// A file whose audio stream decodes to zero samples still exits 0 and
		// still gets an MD5 — of nothing at all. Every such file in the library
		// produces this same constant, so storing it would make them all
		// "byte-identical" to each other in the duplicates view.
		{"zero samples decoded", "MD5=d41d8cd98f00b204e9800998ecf8427e\n", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := parseMD5(tt.in); got != tt.want {
				t.Errorf("parseMD5(%q) = %q, want %q", tt.in, got, tt.want)
			}
		})
	}
}

func TestIsLossless(t *testing.T) {
	for _, c := range []string{"flac", "alac", "wavpack", "pcm_s24le", "dsd_lsbf_planar", "truehd"} {
		if !isLossless(c) {
			t.Errorf("%s should be lossless", c)
		}
	}
	for _, c := range []string{"mp3", "aac", "opus", "vorbis", "wmav2", ""} {
		if isLossless(c) {
			t.Errorf("%s should not be lossless", c)
		}
	}
}

func TestSuspect(t *testing.T) {
	tests := []struct {
		name string
		pend repo.Pending
		p    probe
		want bool
	}{
		{"agrees", repo.Pending{Lossless: true, SampleRate: i(44100), BitsPerSample: i(16), Channels: i(2)},
			probe{Codec: "flac", SampleRate: i(44100), BitsPerSample: i(16), Channels: i(2)}, false},
		{"m4a tagged lossless decodes as aac", repo.Pending{Lossless: true},
			probe{Codec: "aac"}, true},
		{"taglib lied about the rate", repo.Pending{Lossless: true, SampleRate: i(44100)},
			probe{Codec: "flac", SampleRate: i(96000)}, true},
		{"null stream values cannot contradict anything", repo.Pending{Lossless: false, BitsPerSample: i(16)},
			probe{Codec: "mp3"}, false},
		{"ffmpeg said nothing at all", repo.Pending{Lossless: true}, probe{}, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := toRow(tc.pend, tc.p).Suspect; got != tc.want {
				t.Errorf("suspect = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestReplayGain(t *testing.T) {
	tests := []struct {
		name       string
		lufs, peak *float64
		gain, lin  *float64
	}{
		{"cd.flac", f(-21.3), f(-18.1), f(3.30), f(0.124451)},
		{"hires.flac", f(-21.8), f(-18.1), f(3.80), f(0.124451)},
		{"lossy.mp3", f(-21.9), f(-18.3), f(3.90), f(0.121619)},
		// peak > 1.0 is normal and meaningful: it is what a gain stage must
		// respect to avoid clipping.
		{"clipped", f(-0.0), f(0.4), f(-18.00), f(1.047129)},
		{"unmeasured", nil, nil, nil, nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			g, p := TrackGain(tc.lufs), TrackPeak(tc.peak)
			if (g == nil) != (tc.gain == nil) || (g != nil && math.Abs(*g-*tc.gain) > 0.005) {
				t.Errorf("gain = %v, want %v", g, tc.gain)
			}
			if (p == nil) != (tc.lin == nil) || (p != nil && math.Abs(*p-*tc.lin) > 5e-6) {
				t.Errorf("peak = %v, want %v", p, tc.lin)
			}
		})
	}
}

func TestAlbumAggregation(t *testing.T) {
	// Both cases were measured against a true single concatenated pass; the
	// second is asserted as the KNOWN approximation error, so the day someone
	// implements the concat pass this test says exactly what changed.
	tests := []struct {
		name     string
		ts       []AlbumTrack
		wantLUFS *float64 // nil = no gain at all
		trueLUFS string   // what one concatenated pass measured, for the record
	}{
		{"4-LU spread (a normal pop album)",
			[]AlbumTrack{{LUFS: f(-29.9), Duration: 30}, {LUFS: f(-33.9), Duration: 30}},
			f(-31.455), "-31.4, so 0.05 dB out — inaudible"},
		{"20-LU spread (classical with a pianissimo movement)",
			[]AlbumTrack{{LUFS: f(-29.9), Duration: 30}, {LUFS: f(-49.9), Duration: 30}},
			f(-32.868), "-29.9, so 2.97 dB out — reads quiet, so gain reads high"},
		{"single track is exact", []AlbumTrack{{LUFS: f(-14.0), Duration: 200}}, f(-14.0), "exact"},
		{"unmeasurable tracks are skipped, not counted as silence",
			[]AlbumTrack{{LUFS: f(-14.0), Duration: 200}, {LUFS: nil, Duration: 200}}, f(-14.0), "n/a"},
		{"nothing measurable", []AlbumTrack{{LUFS: nil, Duration: 10}}, nil, "n/a"},
		{"empty album", nil, nil, "n/a"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			g := AlbumGain(tc.ts)
			if tc.wantLUFS == nil {
				if g != nil {
					t.Fatalf("gain = %v, want nil", *g)
				}
				return
			}
			if g == nil {
				t.Fatalf("gain = nil, want %v LUFS (true pass: %s)", *tc.wantLUFS, tc.trueLUFS)
			}
			if got := rgReference - *g; math.Abs(got-*tc.wantLUFS) > 0.01 {
				t.Errorf("album LUFS = %.3f, want %.3f", got, *tc.wantLUFS)
			}
		})
	}
}

// Duration is the weight, so a long loud track must dominate a short quiet one.
func TestAlbumGainIsDurationWeighted(t *testing.T) {
	long := AlbumGain([]AlbumTrack{{LUFS: f(-10), Duration: 600}, {LUFS: f(-30), Duration: 10}})
	even := AlbumGain([]AlbumTrack{{LUFS: f(-10), Duration: 100}, {LUFS: f(-30), Duration: 100}})
	if *long >= *even {
		t.Errorf("weighting had no effect: long=%v even=%v", *long, *even)
	}
	// 10*log10((600*10^-1 + 10*10^-3)/610): the 10 s quiet track moves the
	// album barely 0.07 dB off the loud track's own value.
	if got := rgReference - *long; math.Abs(got-(-10.071)) > 0.01 {
		t.Errorf("long-track album LUFS = %.3f, want ~-10.071", got)
	}
}

func TestAlbumPeak(t *testing.T) {
	// max is max — exact, no caveat, and it must survive an unmeasurable peak
	// sitting next to a real one.
	got := AlbumPeak([]AlbumTrack{{PeakDBFS: f(-18.1)}, {PeakDBFS: nil}, {PeakDBFS: f(0.4)}})
	if got == nil || math.Abs(*got-1.047129) > 5e-6 {
		t.Fatalf("album peak = %v, want 1.047129", got)
	}
	if AlbumPeak([]AlbumTrack{{PeakDBFS: nil}}) != nil {
		t.Error("no measured peak should give nil, not 0")
	}
}

// writeStubFFmpeg drops a POSIX-sh "ffmpeg" that logs its argv and replays a
// captured stderr fixture. No real decoder runs in CI.
func writeStubFFmpeg(t *testing.T, argvLog string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "ffmpeg")
	script := "#!/bin/sh\n" +
		"echo \"$@\" >> '" + argvLog + "'\n" +
		"cat >&2 <<'XEOF'\n" + summaryCD + "XEOF\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestRunStub(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX-sh stub")
	}
	dir := t.TempDir()
	sqlDB, err := db.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer sqlDB.Close()
	ctx := context.Background()
	tracks := repo.NewTracks(sqlDB)
	if err := tracks.UpsertAll(ctx, []repo.Track{{
		ID: "t1", Path: "a/one.flac", Mtime: 100, Size: 200,
		AddedAt: "2026-01-01T00:00:00Z", Title: "One", Album: "A", AlbumID: "al",
		Format: "FLAC", Lossless: true,
	}}); err != nil {
		t.Fatal(err)
	}
	audio := repo.NewAudio(sqlDB)
	argvLog := filepath.Join(dir, "argv")
	a := New(writeStubFFmpeg(t, argvLog), "/music", audio)
	a.log = func(string) {}

	if err := a.Run(ctx); err != nil {
		t.Fatalf("run: %v", err)
	}
	argv, err := os.ReadFile(argvLog)
	if err != nil {
		t.Fatalf("stub never ran: %v", err)
	}
	for _, want := range []string{
		"-af ebur128=peak=true:framelog=quiet", // framelog=quiet is what keeps this cheap
		"-map 0:a:0",                           // skip embedded cover art
		"-nostdin",                             // a corrupt file must not block on the terminal
		"/music/a/one.flac",
	} {
		if !strings.Contains(string(argv), want) {
			t.Errorf("argv missing %q: %s", want, argv)
		}
	}
	if strings.Contains(string(argv), "-loglevel") {
		t.Error("-loglevel suppresses the Summary block entirely")
	}

	rows, err := audio.ListAll(ctx)
	if err != nil {
		t.Fatal(err)
	}
	got, ok := rows["t1"]
	if !ok {
		t.Fatal("no track_audio row")
	}
	if got.IntegratedLUFS == nil || *got.IntegratedLUFS != -21.3 || got.Codec != "flac" || !got.Lossless {
		t.Errorf("row = %+v", got)
	}
	// mono s16 vs the scanner's silence: nothing contradicts, so not suspect.
	if got.Suspect {
		t.Error("suspect on a row nothing contradicts")
	}

	// Incremental: unchanged bytes are not decoded again.
	before, _ := os.ReadFile(argvLog)
	if err := a.Run(ctx); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(argvLog)
	if len(before) != len(after) {
		t.Errorf("second pass re-decoded a fresh row")
	}

	// ...and a moved mtime makes it pending again, exactly as the scanner's
	// own skip test would.
	if _, err := sqlDB.ExecContext(ctx, `UPDATE tracks SET mtime = 999 WHERE id = 't1'`); err != nil {
		t.Fatal(err)
	}
	if err := a.Run(ctx); err != nil {
		t.Fatal(err)
	}
	again, _ := os.ReadFile(argvLog)
	if len(again) <= len(after) {
		t.Error("changed mtime did not re-queue the file")
	}
}

func TestRunSingleFlightAndStatus(t *testing.T) {
	a := New("/nonexistent/ffmpeg", "/music", nil)
	st := a.Status().(map[string]any)
	for _, k := range []string{"phase", "done", "total", "running"} {
		if _, ok := st[k]; !ok {
			t.Errorf("status missing %q — the SSE payload must match EnrichStatus", k)
		}
	}
	if st["phase"] != "idle" || st["running"] != false {
		t.Errorf("fresh analyzer = %v", st)
	}
	// A Run while one is in flight is a silent no-op, not an error and not a
	// second pass: audio is nil here, so any real work would panic.
	a.mu.Lock()
	a.running = true
	a.mu.Unlock()
	if err := a.Run(context.Background()); err != nil {
		t.Errorf("re-entrant Run = %v, want nil", err)
	}
}
