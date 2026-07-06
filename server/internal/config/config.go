// Package config reads server configuration from the environment.
package config

import "os"

type Config struct {
	Port     string
	MusicDir string
	DataDir  string
}

func FromEnv() Config {
	return Config{
		Port:     getenv("PORT", "3000"),
		MusicDir: getenv("MUSIC_DIR", "/music"),
		DataDir:  getenv("DATA_DIR", "/data"),
	}
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
