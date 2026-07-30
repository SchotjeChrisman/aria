#!/usr/bin/env python3
"""Capture what the server concluded about each test album, so before/after is
a mechanical diff rather than a reading exercise.

Per album: the match verdict and its distance breakdown, the enrichment blob's
artist fields, and — the thing the user actually sees — the displayed
albumArtist from /api/tracks.
"""
import json, sqlite3, sys, unicodedata, urllib.request

db_path, api, out_path, label = sys.argv[1:5]
manifest = {m["dir"]: m for m in json.load(open("manifest.json"))}


def api_get(path):
    try:
        with urllib.request.urlopen(api + path, timeout=120) as r:
            return json.load(r)
    except Exception as e:
        print("  !! %s -> %s" % (path, e), file=sys.stderr)
        return None


c = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True)
c.row_factory = sqlite3.Row

# albumId -> manifest key, via the folder each album's files live in
album_key, album_dir = {}, {}
def norm(s):  # the Japanese folder round-trips through the FS in a different form
    return unicodedata.normalize("NFC", s)


for r in c.execute("SELECT DISTINCT albumId, path FROM tracks"):
    p = norm(r["path"])
    for d, m in manifest.items():
        if p.startswith(norm(d) + "/"):
            album_key[r["albumId"]] = m["key"]
            album_dir[r["albumId"]] = d
            break

# what the client renders, straight off the API
displayed = {}
tracks = api_get("/api/tracks") or []
if isinstance(tracks, dict):
    tracks = tracks.get("tracks", [])
for t in tracks:
    aid = t.get("albumId")
    displayed.setdefault(aid, {
        "albumArtist": t.get("albumArtist"), "album": t.get("album"),
        "composer": t.get("composer"), "artist": t.get("artist"),
        "conductor": t.get("conductor"), "orchestra": t.get("orchestra"),
        "performers": [p.get("name") for p in (t.get("performers") or [])],
        "albumArtists": t.get("albumArtists"),
    })

# aria's own raw -> Latin map, so expectations stay self-consistent with
# whatever the names phase had resolved at snapshot time
latin = {}
for k, j in c.execute("SELECT key, json FROM enrich_cache WHERE kind='artist'"):
    try:
        d = json.loads(j)
    except Exception:
        continue
    if d.get("nameLatin") and d["nameLatin"] != k:
        latin[k] = d["nameLatin"]

snap = {"label": label, "latin": latin, "albums": {}}
for aid, key in sorted(album_key.items(), key=lambda kv: kv[1]):
    row = c.execute(
        "SELECT state, reason, distance, separation, releaseMbid, candidates "
        "FROM match_decisions WHERE albumId=?", (aid,)).fetchone()
    blob = c.execute(
        "SELECT json FROM enrich_cache WHERE kind='album' AND key=?", (aid,)).fetchone()
    a = json.loads(blob[0]) if blob and blob[0] else {}
    cands = json.loads(row["candidates"]) if row and row["candidates"] else []
    top = cands[0] if cands else {}
    exp = manifest[album_dir[aid]]
    snap["albums"][key] = {
        "albumId": aid,
        "expected_mbid": exp["mbid"],
        "expected_credit": exp["expect_mb_credit"],
        "tag_albumartist": exp["tag_albumartist"],
        "match": {
            "state": row["state"] if row else None,
            "reason": row["reason"] if row else None,
            "distance": round(row["distance"], 4) if row and row["distance"] is not None else None,
            "separation": round(row["separation"], 4) if row and row["separation"] is not None else None,
            "mbid": row["releaseMbid"] if row else None,
            "mbid_correct": (row["releaseMbid"] == exp["mbid"]) if row and row["releaseMbid"] else None,
        },
        "top_candidate": {
            "title": top.get("title"), "artist": top.get("artist"),
            "distance": round(top["distance"], 4) if top.get("distance") is not None else None,
            "why": {k: round(v, 4) for k, v in (top.get("why") or {}).items()},
        },
        "enrich_blob": {
            "albumArtist": a.get("albumArtist"),
            "displayArtist": a.get("displayArtist"),
            "composers": a.get("composers"),
            "performers": a.get("performers"),
            "deezer": a.get("dzContributors"),
            "v": a.get("v"),
        },
        "displayed": displayed.get(aid, {}),
    }

json.dump(snap, open(out_path, "w"), indent=1, ensure_ascii=False)

print("\n%s" % ("=" * 100))
print("SNAPSHOT: %s" % label)
print("=" * 100)
hdr = "%-26s %-8s %-7s %-6s %-5s %-22s %-22s"
print(hdr % ("album", "state", "dist", "artist", "ok", "displayed albumArtist", "MB displayArtist"))
print("-" * 100)
for key, s in snap["albums"].items():
    print(hdr % (
        key[:26], str(s["match"]["state"])[:8], str(s["match"]["distance"])[:7],
        str(s["top_candidate"]["why"].get("artist"))[:6],
        {True: "yes", False: "NO", None: "-"}[s["match"]["mbid_correct"]],
        str(s["displayed"].get("albumArtist"))[:22],
        str(s["enrich_blob"].get("displayArtist"))[:22]))
print("\nwrote %s" % out_path)
