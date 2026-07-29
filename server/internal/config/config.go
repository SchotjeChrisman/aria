// Package config reads server configuration from the environment.
package config

import (
	"os"
	"strconv"
)

type Config struct {
	Port     string
	MusicDir string
	DataDir  string

	FFmpegPath       string // env FFMPEG_PATH; feature-gated at startup
	FPCalcPath       string // env FPCALC_PATH; feature-gated at startup, like FFmpegPath
	TranscodeCacheMB int    // env TRANSCODE_CACHE_MB; DATA_DIR/tc sweep budget
	ExtArtCacheMB    int    // env EXT_ART_CACHE_MB; DATA_DIR/extart sweep budget

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
