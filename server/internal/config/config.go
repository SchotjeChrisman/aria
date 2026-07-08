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
	TranscodeCacheMB int    // env TRANSCODE_CACHE_MB; DATA_DIR/tc sweep budget
}

func FromEnv() Config {
	return Config{
		Port:     getenv("PORT", "3000"),
		MusicDir: getenv("MUSIC_DIR", "/music"),
		DataDir:  getenv("DATA_DIR", "/data"),

		FFmpegPath:       getenv("FFMPEG_PATH", "/ffmpeg"),
		TranscodeCacheMB: getenvInt("TRANSCODE_CACHE_MB", 5000),
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
