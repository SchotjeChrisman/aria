#!/usr/bin/env bash
# Test-server harness for the artist-credits fix.
#
#   ./testserver.sh build          rebuild the binary from the working tree
#   ./testserver.sh reset          wipe the data dir (library files are kept)
#   ./testserver.sh start          run the server, scan, wait for enrichment
#   ./testserver.sh stop
#   ./testserver.sh snapshot NAME  dump match verdicts + display artists
#   ./testserver.sh run NAME       reset + start + wait + snapshot + stop
set -uo pipefail
cd "$(dirname "$0")"

HERE=$PWD
BIN=$HERE/aria-server
SRC=/home/dev/projects/aria/server
export PORT=${PORT:-3999}
export MUSIC_DIR=$HERE/testlib
export DATA_DIR=$HERE/testdata
export FFMPEG_PATH=$(command -v ffmpeg)
export FPCALC_PATH=/nonexistent          # keeps the AcoustID path dark
export SCAN_INTERVAL=0                   # no background cadence; scans are manual
export FULL_SCAN_INTERVAL=0
API=http://127.0.0.1:$PORT

case "${1:-}" in
build)
  cd "$SRC" && go build -o "$BIN" ./cmd/aria && echo "built $BIN"
  ;;

reset)
  rm -rf "$DATA_DIR"; mkdir -p "$DATA_DIR"; echo "data dir wiped: $DATA_DIR"
  ;;

start)
  mkdir -p "$DATA_DIR"
  "$BIN" >"$HERE/server.log" 2>&1 &
  echo $! >"$HERE/server.pid"
  for _ in $(seq 1 60); do
    curl -sf "$API/healthz" >/dev/null 2>&1 && break
    sleep 0.5
  done
  curl -sf "$API/healthz" >/dev/null || { echo "server did not come up"; tail -20 "$HERE/server.log"; exit 1; }
  echo "up on $API (pid $(cat "$HERE/server.pid"))"
  ;;

stop)
  [ -f "$HERE/server.pid" ] && kill "$(cat "$HERE/server.pid")" 2>/dev/null
  rm -f "$HERE/server.pid"; echo stopped
  ;;

scan)
  curl -sf -X POST "$API/api/scan" >/dev/null && echo "scan triggered"
  ;;

# Enrichment is the slow part: one MusicBrainz request per candidate at a
# polite 1/s. Wait for the phase to go idle rather than guessing a duration.
wait)
  last=""; idle=0
  for i in $(seq 1 "${2:-1200}"); do
    s=$(curl -sf "$API/api/enrich/status" 2>/dev/null)
    [ -z "$s" ] && { sleep 2; continue; }
    running=$(printf '%s' "$s" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("running"))' 2>/dev/null)
    phase=$(printf '%s' "$s" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("%s %s/%s"%(d.get("phase"),d.get("done"),d.get("total")))' 2>/dev/null)
    [ "$phase" != "$last" ] && { echo "  $phase"; last=$phase; }
    # 'people' is the portrait/bio long tail — ~100 requests that say nothing
    # about matching or album credit. Reaching it means the phases under test
    # (matching -> albums -> sources) have all finished.
    case "$phase" in people*) echo "reached people phase; matching+albums done"; exit 0;; esac
    if [ "$running" = "False" ] || [ "$running" = "false" ]; then
      idle=$((idle+1)); [ $idle -ge 3 ] && { echo "enrichment idle"; exit 0; }
    else idle=0; fi
    sleep 2
  done
  echo "timed out waiting for enrichment"
  ;;

snapshot)
  name=${2:?usage: snapshot NAME}
  python3 snapshot.py "$DATA_DIR/aria.db" "$API" "snap-$name.json" "$name"
  ;;

run)
  name=${2:?usage: run NAME}
  "$0" stop >/dev/null 2>&1
  "$0" reset && "$0" start && "$0" scan && sleep 3 && "$0" wait && "$0" snapshot "$name"
  "$0" stop
  ;;

*)
  sed -n '2,10p' "$0"; exit 1
  ;;
esac
