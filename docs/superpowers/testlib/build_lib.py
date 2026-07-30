#!/usr/bin/env python3
"""Build a synthetic aria test library from probed MusicBrainz shapes.

The point of this library is that the FILE TAGS ARE DELIBERATELY IMPERFECT, in
exactly the ways real rips are. Tagging the files with MusicBrainz's own truth
would make every match trivial and test nothing. Each album's `tags` policy
below records the specific lie the matcher has to see through.
"""
import json, os, subprocess, sys, unicodedata
from mutagen.flac import FLAC

ROOT = sys.argv[1] if len(sys.argv) > 1 else "testlib"
SHAPES = json.load(open("shapes.json"))

# folder, and the tag policy. `albumartist` is the interesting field: for the
# classical albums it is the COMPOSER, which is what rippers write and what
# MusicBrainz disagrees with — that disagreement is the bug under test.
PLAN = {
    "baseline-acdc": dict(
        mbid_tagged=True,
        dir="AC-DC/Back in Black", album="Back in Black", albumartist="AC/DC",
        artist="AC/DC", split=False,
        lie="none — tags agree with MB. Control case."),
    "baseline-portishead": dict(
        mbid_tagged=False,
        dir="Portishead/Dummy", album="Dummy", albumartist="Portishead",
        artist="Portishead", split=False,
        lie="none — second control, different era/genre."),
    "classical-barber": dict(
        mbid_tagged=True,
        dir="Samuel Barber/Barber, Bruch", album="Barber, Bruch",
        albumartist="Samuel Barber", artist=None, composer=True, split=False,
        lie="albumArtist is a COMPOSER; MB's performer is Esther Yoo. Exact live-server tags."),
    "classical-toscanini": dict(
        mbid_tagged=True,
        dir="Ludwig van Beethoven/Symphony no. 9",
        album="Symphony no. 9", albumartist="Ludwig van Beethoven",
        artist=None, composer=True, split=False,
        lie="albumArtist is the composer; MB's performer is the conductor Toscanini."),
    "trap-vivaldi": dict(
        mbid_tagged=False,
        dir="Antonio Vivaldi/The Four Seasons", album="The Four Seasons",
        albumartist="Antonio Vivaldi", artist=None, composer=True, split=False,
        lie="composer-only tags on a work MusicBrainz holds ELEVEN near-identical "
            "Janine Jansen releases of. The artist signal cannot separate them, so this "
            "album guards against the fix manufacturing false confidence."),
    "compilation-trainspotting": dict(
        mbid_tagged=False,
        dir="Various Artists/Trainspotting", album="Trainspotting",
        albumartist="Various Artists", artist=None, split=False,
        lie="albumArtist is the VA placeholder; every track has a real, different artist."),
    "multidisc-wall": dict(
        mbid_tagged=True,
        dir="Pink Floyd/The Wall", album="The Wall", albumartist="Pink Floyd",
        artist="Pink Floyd", split=True,
        lie="split across CD1/CD2 folders, so albumId folding has to run before matching."),
    "nonlatin-utada": dict(
        mbid_tagged=True,
        dir="宇多田ヒカル/First Love", album="First Love", albumartist="宇多田ヒカル",
        artist="宇多田ヒカル", split=True,
        lie="original-script credit; the new albumArtist correction must store it raw "
            "and only latinise at display time."),
    "selftitled-weezer94": dict(
        mbid_tagged=False,
        dir="Weezer/Weezer (1994)", album="Weezer", albumartist="Weezer",
        artist="Weezer", split=False,
        lie="album == artist, and tags are IDENTICAL to the 2001 album below. "
            "Only the tracklist and the folder can separate them."),
    "selftitled-weezer01": dict(
        mbid_tagged=False,
        dir="Weezer/Weezer (2001)", album="Weezer", albumartist="Weezer",
        artist="Weezer", split=False,
        lie="see above — the pair is the test."),
}


def safe(s):
    """Filesystem-safe path segment; keeps non-Latin script intact."""
    s = unicodedata.normalize("NFC", s or "")
    for ch in '/\\:*?"<>|':
        s = s.replace(ch, "-")
    return s.strip(" .") or "Untitled"


def main():
    total = 0
    manifest = []
    for key, plan in PLAN.items():
        shape = SHAPES[key]
        year = (shape.get("date") or "")[:4]
        for t in shape["tracks"]:
            secs = round((t["length"] or 180000) / 1000.0, 3)
            sub = ""
            if plan["split"] and shape["mediums"] > 1:
                sub = "CD%d/" % t["medium"]
            d = os.path.join(ROOT, plan["dir"], sub.rstrip("/")) if sub else \
                os.path.join(ROOT, plan["dir"])
            os.makedirs(d, exist_ok=True)
            name = "%02d - %s.flac" % (t["pos"], safe(t["title"])[:70])
            path = os.path.join(d, name)
            if not os.path.exists(path):
                # a distinct tone per track keeps decoded-audio MD5s unique, so
                # the duplicate detector does not light up on 120 identical files
                freq = 110 + (total * 7) % 800
                subprocess.run(
                    ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                     "-i", "sine=frequency=%d:duration=%s:sample_rate=8000" % (freq, secs),
                     "-ac", "1", "-c:a", "flac", "-y", path], check=True)
            f = FLAC(path)
            f["title"] = t["title"]
            f["album"] = plan["album"]
            f["albumartist"] = plan["albumartist"]
            f["artist"] = plan["artist"] or t["artist"] or plan["albumartist"]
            f["tracknumber"] = str(t["pos"])
            f["discnumber"] = str(t["medium"])
            if year:
                f["date"] = year
            # 89%% of the live library is Picard-tagged; carrying the release
            # MBID lets the matcher seed a "tag" candidate and skip search
            # entirely. Withholding it forces the search+score path instead.
            if plan["mbid_tagged"]:
                f["musicbrainz_albumid"] = shape["mbid"]
            if plan.get("composer"):
                f["composer"] = t["artist"] or ""
            f.save()
            total += 1
        manifest.append({
            "key": key, "dir": plan["dir"], "mbid": shape["mbid"],
            "expect_mb_credit": shape["credit"],
            "tag_albumartist": plan["albumartist"],
            "tracks": shape["track_count"], "mediums": shape["mediums"],
            "composer_split": shape["has_composer_split"],
            "release_artist_rels": sum(len(v) for v in shape["release_artist_rels"].values()),
            "lie": plan["lie"], "why": shape["why"],
            "mbid_tagged": plan["mbid_tagged"],
        })
        print("%-26s %3d tracks  mbid_tag=%-5s %s" % (
            key, shape["track_count"], plan["mbid_tagged"], plan["dir"]))
    json.dump(manifest, open("manifest.json", "w"), indent=1, ensure_ascii=False)
    print("\n%d files under %s" % (total, ROOT))


if __name__ == "__main__":
    main()
