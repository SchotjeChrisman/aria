FROM golang:1.26-alpine AS build

WORKDIR /src

# fpcalc computes the AcoustID (Chromaprint) fingerprints. The bundled ffmpeg
# cannot: mwader/static-ffmpeg is not configured with --enable-chromaprint
# (checked its configure line — 51 --enable-lib* flags, chromaprint absent), so
# the chromaprint muxer does not exist in that binary.
#
# Fetched in this stage because it is the only one with a network already
# (go mod download), and before the go.mod COPY so a Go source change never
# re-downloads it. TARGETARCH is amd64|arm64, the release assets are named
# x86_64|arm64, hence the map. Checksums are pinned: this is a binary pulled off
# the internet straight into the shipped image.
ARG TARGETARCH
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) a=x86_64; s=fc16cd37a70168040bc9ceb45f1d4d1216f5a75bc4c9cf8564bea70ac6a45733 ;; \
      arm64) a=arm64;  s=7eaf5d655c4aa172ab28e3c870b8bb61dd2c327ac94de145676f88842cf6215a ;; \
      *) echo "no fpcalc release asset for $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    wget -qO /tmp/fpcalc.tgz \
      "https://github.com/acoustid/chromaprint/releases/download/v1.6.1/chromaprint-fpcalc-1.6.1-linux-$a.tar.gz"; \
    echo "$s  /tmp/fpcalc.tgz" | sha256sum -c -; \
    tar xzf /tmp/fpcalc.tgz -C /tmp; \
    mkdir -p /out; \
    mv /tmp/chromaprint-fpcalc-*/fpcalc /out/fpcalc

COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
# VERSION is the release tag with its leading "v" stripped, passed by
# release.yml. Linking it in beats a hand-bumped constant, which is exactly how
# /api/status came to report 3.0.0 for three releases running. Unset (a plain
# `docker build`) leaves main.version at its "dev" default.
ARG VERSION
RUN CGO_ENABLED=0 go build -trimpath \
    -ldflags="-s -w ${VERSION:+-X main.version=$VERSION}" -o /out/aria ./cmd/aria
# distroless can't mkdir; pre-made dirs COPY'd in with nonroot ownership (65532)
RUN mkdir -p /out/empty

# distroless/cc, not /static: the arm64 fpcalc release binary is dynamically
# linked (ld-linux-aarch64.so.1, libc, libm, libstdc++, libgcc_s) even though the
# x86_64 one is static, and /static has neither a loader nor a libc — fpcalc
# would not exec at all there. cc-debian12 is base plus libstdc++6/libgcc-s1,
# exactly fpcalc's ldd list, and is still nonroot and shell-less. Costs ~20 MB on
# an image already carrying an 80 MB static ffmpeg.
FROM gcr.io/distroless/cc-debian12:nonroot

ENV PORT=3000 MUSIC_DIR=/music DATA_DIR=/data
# fully-static ffmpeg for the high/low transcode tiers and the loudness/MD5
# analysis pass. Only /ffmpeg needed (no ffprobe: duration is in the DB).
COPY --from=mwader/static-ffmpeg:7.1 /ffmpeg /ffmpeg
COPY --from=build /out/fpcalc /fpcalc
COPY --from=build /out/aria /aria
COPY --from=build --chown=nonroot:nonroot /out/empty /data
COPY --from=build /out/empty /music

USER nonroot
VOLUME ["/music", "/data"]
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s CMD ["/aria", "-healthcheck"]

ENTRYPOINT ["/aria"]
