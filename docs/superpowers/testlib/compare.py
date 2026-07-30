#!/usr/bin/env python3
"""Assert the artist-credits fix did what it claims, and broke nothing else.

    ./compare.py snap-before.json snap-after.json

Expectations are stated per album rather than as a blanket diff, because the
interesting part is that SOME albums must change and the rest must not.
"""
import json, sys

before = json.load(open(sys.argv[1]))["albums"]
after = json.load(open(sys.argv[2]))["albums"]

# Expectations are COMPUTED by display_artist.py — a port of credits.go — over
# the cached MusicBrainz shapes, never written by hand. Asserting them by eye is
# how the first version of this file came to expect the wrong Vivaldi performer.
# Expectations are recomputed here from the cached MusicBrainz shapes and the
# latin map the snapshot itself carried, so they always describe the same state
# the server was in. A stale expected.json is how the Vivaldi error survived.
import display_artist as da
shapes = json.load(open("shapes.json"))
latin = json.load(open(sys.argv[2])).get("latin", {})
expected = {}
for k, s_ in shapes.items():
    artist, composers, _ = da.display_artist(s_)
    expected[k] = {
        "displayArtist": artist if composers else None,
        "composers": composers or None,
        "artistList": da.album_artists(s_, latin, s_.get("deezer_contributors")),
    }
json.dump(expected, open("expected.json", "w"), indent=1, ensure_ascii=False)

# albums with a ';' composer split: each must gain a displayArtist naming the performer
EXPECT_DISPLAY_ARTIST = {k: v["displayArtist"] for k, v in expected.items()
                         if v["displayArtist"]}
# everything else must keep rendering exactly what it renders today
MUST_NOT_CHANGE_DISPLAY = [k for k, v in expected.items() if not v["displayArtist"]]

fails, notes = [], []


def check(cond, msg):
    (notes if cond else fails).append(("PASS" if cond else "FAIL", msg))


# 1. the root cause: the artist distance must stop being a constant
stuck = [k for k, a in after.items()
         if a["top_candidate"]["why"].get("artist") == 1
         and a["tag_albumartist"].lower() in (a["top_candidate"]["artist"] or "").lower()]
check(not stuck, "artist distance no longer maxed on albums whose tag matches the MB credit "
                 "(still stuck: %s)" % (stuck or "none"))

# Various Artists albums omit the artist component altogether (isVarious), so
# they were never affected by the dead signal and are excluded from this check.
scored = [(k, a) for k, a in before.items() if "artist" in a["top_candidate"]["why"]]
check(all(a["top_candidate"]["why"]["artist"] == 1 for _, a in scored),
      "BASELINE really did score every scored candidate artist:1 (the bug), %d albums" % len(scored))

# 2. no album may REGRESS. A matched album must stay matched on the same
#    release; an album already in review is free to improve (and should).
for k in sorted(before):
    b, a = before[k], after.get(k)
    if not a:
        fails.append(("FAIL", "%s vanished from the after-snapshot" % k)); continue
    if b["match"]["state"] == "matched":
        check(a["match"]["state"] == "matched",
              "%-26s still matched (was %s, now %s)" % (k, b["match"]["state"], a["match"]["state"]))
        check(a["match"]["mbid"] == b["match"]["mbid"],
              "%-26s same release chosen" % k)
    else:
        notes.append(("PASS", "%-26s was %s; now %s%s" % (
            k, b["match"]["state"], a["match"]["state"],
            " -> " + str(a["match"]["mbid_correct"]) if a["match"]["mbid"] else "")))

# 3. the classical split must now produce a performer
for k, want in EXPECT_DISPLAY_ARTIST.items():
    a = after.get(k, {})
    got = (a.get("enrich_blob") or {}).get("displayArtist")
    comps = (a.get("enrich_blob") or {}).get("composers")
    check(got == want, "%-26s displayArtist = %r (want %r)" % (k, got, want))
    check(bool(comps), "%-26s composers split off: %s" % (k, comps))
    check((a.get("displayed") or {}).get("albumArtist") == want,
          "%-26s renders the performer, not the composer" % k)
    # the album-header credit list: lead, then ensembles, then remaining people
    want_list = expected[k]["artistList"]
    got_list = (a.get("displayed") or {}).get("albumArtists")
    check(got_list == want_list,
          "%-26s artist list = %s (want %s)" % (k, got_list, " · ".join(want_list)))

# 4. and nothing else may move
for k in MUST_NOT_CHANGE_DISPLAY:
    b, a = before.get(k, {}), after.get(k, {})
    bd = (b.get("displayed") or {}).get("albumArtist")
    ad = (a.get("displayed") or {}).get("albumArtist")
    check(bd == ad, "%-26s display unchanged (%r)" % (k, bd))

# 5. the MB album-artist correction must now be written at all
wrote = [k for k, a in after.items() if (a.get("enrich_blob") or {}).get("albumArtist")]
check(len(wrote) == len(after),
      "all %d albums got an MB albumArtist (%d did)" % (len(after), len(wrote)))

print("\n%s\nARTIST-CREDIT FIX — VERIFICATION\n%s" % ("=" * 78, "=" * 78))
for status, msg in notes + fails:
    print("  %s  %s" % (status, msg))

print("\n%s" % ("-" * 78))
print("%-26s %-24s %-24s" % ("album", "before", "after"))
print("-" * 78)
for k in sorted(before):
    b = (before[k].get("displayed") or {}).get("albumArtist")
    a = (after.get(k, {}).get("displayed") or {}).get("albumArtist")
    mark = "  ->" if b != a else "    "
    print("%-26s %-24s %s%-24s" % (k, str(b)[:24], mark, str(a)[:24]))

print("\n%d passed, %d failed" % (len(notes), len(fails)))
sys.exit(1 if fails else 0)
