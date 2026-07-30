#!/usr/bin/env python3
"""Probe MusicBrainz releases for the properties that make them hard for aria's
matcher, so the test library is picked on evidence rather than vibes."""
import json, sys, time, urllib.parse, urllib.request

UA = "aria-testlib/1.0 ( https://github.com/aria )"
BASE = "https://musicbrainz.org/ws/2/"
INC = "artist-credits+recordings+recording-level-rels+work-rels+work-level-rels+artist-rels"


def get(path):
    req = urllib.request.Request(BASE + path, headers={"User-Agent": UA})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except Exception as e:
            if attempt == 3:
                print("  !! %s -> %s" % (path[:70], e), file=sys.stderr)
                return None
            time.sleep(2 * (attempt + 1))
    return None


def search(artist, title, limit=5):
    q = 'release:"%s"' % title
    if artist:
        q += ' AND artist:"%s"' % artist
    d = get("release/?query=%s&limit=%d&fmt=json" % (urllib.parse.quote(q), limit))
    return (d or {}).get("releases", [])


def shape(mbid):
    """The properties that decide whether this release exercises the fix."""
    d = get("release/%s?inc=%s&fmt=json" % (mbid, INC))
    if not d:
        return None
    ac = d.get("artist-credit") or []
    joins = [c.get("joinphrase", "") for c in ac]
    roles = {}
    for r in d.get("relations") or []:
        if r.get("artist"):
            roles.setdefault(r.get("type"), []).append(r["artist"]["name"])
    tracks = []
    for m in d.get("media") or []:
        for t in m.get("tracks") or []:
            rec = t.get("recording") or {}
            rec_roles = [x.get("type") for x in (rec.get("relations") or []) if x.get("artist")]
            tracks.append({
                "medium": m.get("position"), "pos": t.get("position"),
                "title": t.get("title"),
                "length": t.get("length") or rec.get("length"),
                "artist": "".join((c.get("name", "") + c.get("joinphrase", ""))
                                  for c in (t.get("artist-credit") or [])),
                "rec_artist_rels": rec_roles,
            })
    return {
        "mbid": mbid, "title": d.get("title"), "date": d.get("date"),
        "country": d.get("country"),
        "credit": "".join((c.get("name", "") + c.get("joinphrase", "")) for c in ac),
        "credit_parts": [c.get("name") for c in ac],
        "joinphrases": joins,
        "has_composer_split": any(j.strip() == ";" for j in joins),
        "release_artist_rels": roles,
        "mediums": len(d.get("media") or []),
        "track_count": len(tracks),
        "has_feat": any("feat" in j.lower() for j in joins),
        "per_track_artists": len({t["artist"] for t in tracks}),
        "tracks": tracks,
        # kept raw so the expected display artist can be COMPUTED offline by
        # display_artist.py rather than asserted by eye
        "artist-credit": ac,
        "relations": d.get("relations") or [],
    }


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "search":
        for rel in search(sys.argv[2] or None, sys.argv[3]):
            ac = "".join((c.get("name", "") + c.get("joinphrase", ""))
                         for c in (rel.get("artist-credit") or []))
            print("%s  %-42s %-38s %s tracks  %s" % (
                rel["id"], rel.get("title", "")[:42], ac[:38],
                rel.get("track-count"), rel.get("date", "")))
    else:
        out = shape(sys.argv[2])
        print(json.dumps(out, indent=1, ensure_ascii=False)[:3000])
