FROM golang:1.26-alpine AS build

WORKDIR /src
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/aria ./cmd/aria
# distroless can't mkdir; pre-made dirs COPY'd in with nonroot ownership (65532)
RUN mkdir -p /out/empty

FROM gcr.io/distroless/static:nonroot

ENV PORT=3000 MUSIC_DIR=/music DATA_DIR=/data
COPY --from=build /out/aria /aria
COPY --from=build --chown=nonroot:nonroot /out/empty /data
COPY --from=build /out/empty /music

USER nonroot
VOLUME ["/music", "/data"]
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s CMD ["/aria", "-healthcheck"]

ENTRYPOINT ["/aria"]
