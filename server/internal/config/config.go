// Package config reads server configuration from the environment.
package config

import (
	"log"
	"os"
	"strconv"
	"time"
)

type Config struct {
	Port     string
	MusicDir string
	DataDir  string

	FFmpegPath       string // env FFMPEG_PATH; feature-gated at startup
	FPCalcPath       string // env FPCALC_PATH; feature-gated at startup, like FFmpegPath
	TranscodeCacheMB int    // env TRANSCODE_CACHE_MB; DATA_DIR/tc sweep budget
	ExtArtCacheMB    int    // env EXT_ART_CACHE_MB; DATA_DIR/extart sweep budget

	// ScanInterval is how often the library is walked for new and changed files
	// (env SCAN_INTERVAL). Nothing else discovers a newly added album: the
	// scanner is the only thing that reads the filesystem, and the enrich,
	// fingerprint and analysis passes all work from the tracks table it fills.
	//
	// FullScanInterval (env FULL_SCAN_INTERVAL) is the same walk, but it also
	// runs those passes whether or not the walk found anything. That is what
	// refreshes EXISTING albums: the enricher's own TTLs (discography 7d,
	// popular 30d) decide what is stale, so this pass is what gives them a
	// chance to expire. Running it hourly instead would make the two cadences
	// identical and hit the metadata services 24x more often for the same result.
	//
	// Both are time.ParseDuration strings ("90m", "6h"). Zero disables that
	// cadence; an unparseable value falls back to the default rather than
	// silently disabling a scan the user meant to schedule.
	ScanInterval     time.Duration
	FullScanInterval time.Duration

	// AcoustIDKey is the AcoustID application key, env ACOUSTID_KEY. It has NO
	// default and no key ships in the image: a key is the user's to obtain
	// (https://acoustid.org/new-application) and register against. Empty means
	// the lookup half of fingerprinting never runs — read with os.Getenv rather
	// than getenv() precisely so no default can ever be introduced by accident.
	AcoustIDKey string

	// DiscogsToken is a Discogs personal access token, env DISCOGS_TOKEN.
	// Same discipline as AcoustIDKey: no default, no key in the image, read
	// with os.Getenv rather than getenv() so a default can never sneak in.
	// Empty means the Discogs half of the sources phase never runs.
	DiscogsToken string
}

func FromEnv() Config {
	return Config{
		Port:     getenv("PORT", "3000"),
		MusicDir: getenv("MUSIC_DIR", "/music"),
		DataDir:  getenv("DATA_DIR", "/data"),

		FFmpegPath:       getenv("FFMPEG_PATH", "/ffmpeg"),
		FPCalcPath:       getenv("FPCALC_PATH", "/fpcalc"),
		TranscodeCacheMB: getenvInt("TRANSCODE_CACHE_MB", 5000),
		ExtArtCacheMB:    getenvInt("EXT_ART_CACHE_MB", 512),
		AcoustIDKey:      os.Getenv("ACOUSTID_KEY"),
		DiscogsToken:     os.Getenv("DISCOGS_TOKEN"),

		ScanInterval:     getenvDur("SCAN_INTERVAL", time.Hour),
		FullScanInterval: getenvDur("FULL_SCAN_INTERVAL", 24*time.Hour),
	}
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func getenvInt(key string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(key)); err == nil && v > 0 {
		return v
	}
	return def
}

// getenvDur differs from getenvInt in accepting zero: "0" is the documented way
// to turn a scan cadence off, so it cannot be folded into the invalid case the
// way a zero-size cache budget can. Negative is not a way to turn it off — it is
// a typo, and a typo takes the default.
func getenvDur(key string, def time.Duration) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil || d < 0 {
		log.Printf("config: %s=%q is not a duration, using %s", key, v, def)
		return def
	}
	return d
}
