package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"

	"aria/internal/repo"
)

type builtinStation struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	URL     string `json:"url"`
	Genre   string `json:"genre"`
	Builtin bool   `json:"builtin"`
}

var builtinStations = []builtinStation{
	{"rp-main", "Radio Paradise Main (FLAC)", "https://stream.radioparadise.com/flacm", "Eclectic", true},
	{"rp-mellow", "Radio Paradise Mellow (FLAC)", "https://stream.radioparadise.com/mellow-flacm", "Eclectic", true},
	{"rp-rock", "Radio Paradise Rock (FLAC)", "https://stream.radioparadise.com/rock-flacm", "Rock", true},
	{"rp-global", "Radio Paradise Global (FLAC)", "https://stream.radioparadise.com/global-flacm", "World", true},
	{"soma-gs", "SomaFM Groove Salad", "https://ice1.somafm.com/groovesalad-256-mp3", "Ambient", true},
	{"soma-drone", "SomaFM Drone Zone", "https://ice1.somafm.com/dronezone-256-mp3", "Ambient", true},
	{"soma-dso", "SomaFM Deep Space One", "https://ice1.somafm.com/deepspaceone-128-mp3", "Ambient", true},
	{"soma-fluid", "SomaFM Fluid", "https://ice1.somafm.com/fluid-128-mp3", "Electronic", true},
	{"soma-sa", "SomaFM Secret Agent", "https://ice1.somafm.com/secretagent-128-mp3", "Lounge", true},
	{"soma-lush", "SomaFM Lush", "https://ice1.somafm.com/lush-128-mp3", "Lounge", true},
	{"soma-su", "SomaFM Sonic Universe", "https://ice1.somafm.com/sonicuniverse-256-mp3", "Jazz", true},
	{"soma-ipr", "SomaFM Indie Pop Rocks!", "https://ice1.somafm.com/indiepop-128-mp3", "Indie", true},
	{"soma-u80s", "SomaFM Underground 80s", "https://ice1.somafm.com/u80s-256-mp3", "Retro", true},
	{"soma-boot", "SomaFM Boot Liquor", "https://ice1.somafm.com/bootliquor-128-mp3", "Americana", true},
	{"soma-trip", "SomaFM The Trip", "https://ice1.somafm.com/thetrip-128-mp3", "Electronic", true},
	{"kexp", "KEXP Seattle", "https://kexp.streamguys1.com/kexp320.aac", "Indie", true},
	{"fip", "FIP", "https://icecast.radiofrance.fr/fip-hifi.aac", "Eclectic", true},
	{"fip-jazz", "FIP Jazz", "https://icecast.radiofrance.fr/fipjazz-midfi.mp3", "Jazz", true},
	{"fip-rock", "FIP Rock", "https://icecast.radiofrance.fr/fiprock-midfi.mp3", "Rock", true},
	{"fip-electro", "FIP Electro", "https://icecast.radiofrance.fr/fipelectro-midfi.mp3", "Electronic", true},
	{"fip-monde", "FIP Monde", "https://icecast.radiofrance.fr/fipworld-midfi.mp3", "World", true},
	{"naim", "Naim Radio (FLAC)", "http://mscp3.live-streams.nl:8360/flac.flac", "Eclectic", true},
	{"naim-jazz", "Naim Jazz (FLAC)", "http://mscp3.live-streams.nl:8340/jazz-flac.flac", "Jazz", true},
	{"naim-class", "Naim Classical (FLAC)", "http://mscp3.live-streams.nl:8250/class-flac.flac", "Classical", true},
	{"swiss-class", "Radio Swiss Classic", "https://stream.srg-ssr.ch/m/rsc_de/aacp_96", "Classical", true},
	{"swiss-jazz", "Radio Swiss Jazz", "https://stream.srg-ssr.ch/m/rsj/aacp_96", "Jazz", true},
	{"swiss-pop", "Radio Swiss Pop", "https://stream.srg-ssr.ch/m/rsp/aacp_96", "Pop", true},
	{"jazz24", "Jazz24", "https://live.amperwave.net/direct/ppm-jazz24aac256-ibc1", "Jazz", true},
	{"nightride", "Nightride FM", "https://stream.nightride.fm/nightride.ogg", "Synthwave", true},
	{"asp", "Ambient Sleeping Pill", "https://radio.stereoscenic.com/asp-h", "Ambient", true},
}

var stationURLRE = regexp.MustCompile(`(?i)^https?://`)

func init() { register(registerRadio) }

func registerRadio(mux *http.ServeMux, d *Deps) {
	mux.HandleFunc("GET /api/radio", func(w http.ResponseWriter, r *http.Request) {
		user, err := d.Radio.List(r.Context())
		if err != nil {
			fail(w, err)
			return
		}
		out := make([]any, 0, len(builtinStations)+len(user))
		for _, s := range builtinStations {
			out = append(out, s)
		}
		for _, s := range user { // user stations carry no "builtin" field, as before
			out = append(out, s)
		}
		writeJSON(w, http.StatusOK, out)
	})

	mux.HandleFunc("POST /api/radio", func(w http.ResponseWriter, r *http.Request) {
		var b struct {
			Name  json.RawMessage `json:"name"`
			URL   json.RawMessage `json:"url"`
			Genre json.RawMessage `json:"genre"`
		}
		if err := readJSON(w, r, &b); err != nil {
			httpError(w, http.StatusBadRequest, "invalid json")
			return
		}
		name, ok := asStr(b.Name)
		if !ok || !nameOK(name, 200) {
			httpError(w, http.StatusBadRequest, "invalid name")
			return
		}
		u, ok := asStr(b.URL)
		if !ok || !stationURLRE.MatchString(u) {
			httpError(w, http.StatusBadRequest, "invalid url")
			return
		}
		var genre *string
		if b.Genre != nil && !bytes.Equal(bytes.TrimSpace(b.Genre), []byte("null")) {
			g, ok := asStr(b.Genre)
			g = strings.TrimSpace(g)
			if !ok || g == "" || utf8.RuneCountInString(g) > 40 {
				httpError(w, http.StatusBadRequest, "invalid genre")
				return
			}
			genre = &g
		}
		st := repo.Station{ID: uuid.NewString(), Name: name, URL: u, Genre: genre, CreatedAt: isoNow()}
		if err := d.Radio.Create(r.Context(), st); err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, http.StatusOK, st)
	})

	mux.HandleFunc("DELETE /api/radio/{id}", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		for _, s := range builtinStations {
			if s.ID == id {
				httpError(w, http.StatusBadRequest, "builtin")
				return
			}
		}
		existed, err := d.Radio.Delete(r.Context(), id)
		if err != nil {
			fail(w, err)
			return
		}
		if !existed {
			http.Error(w, "Not Found", http.StatusNotFound)
			return
		}
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	})
}
