#!/usr/bin/env python3
"""A faithful port of server/internal/enrich/credits.go, so the expected
display artist for a release is COMPUTED from real MusicBrainz data rather
than asserted by eye.

    python3 display_artist.py <release-mbid>
"""
import json, sys
import probe


def role_of(rel_type):
    """roleOf() — '' means 'not a performance role we care about'."""
    t = rel_type or ""
    if t == "conductor":
        return "conductor"
    if t in ("instrument", "vocal"):
        return "soloist"
    if "orchestra" in t:
        return "orchestra"
    if "chorus" in t or "choir" in t:
        return "choir"
    if t == "performer":
        return "performer"
    return ""


RANK = {"soloist": 0, "conductor": 1, "orchestra": 2, "choir": 2, "performer": 3}


def split_artist_credit(ac):
    """splitArtistCredit() — split at the ';' joinphrase."""
    for i, c in enumerate(ac):
        if (c.get("joinphrase") or "").strip() == ";":
            return ac[:i + 1], ac[i + 1:]
    return [], ac


def credit_name(c):
    return c.get("name") or (c.get("artist") or {}).get("name") or ""


def display_artist(rel):
    """displayArtist() — returns (artist, composers, how)."""
    ac = rel.get("artist-credit") or []
    credited, performers = split_artist_credit(ac)
    composers = [credit_name(c) for c in credited]

    rank = {}
    for r in rel.get("relations") or []:
        a = r.get("artist") or {}
        if not a.get("id"):
            continue
        k = RANK.get(role_of(r.get("type")), 4)
        if k < 4 and (a["id"] not in rank or k < rank[a["id"]]):
            rank[a["id"]] = k

    best, best_rank = -1, 5
    for i, c in enumerate(performers):
        k = rank.get((c.get("artist") or {}).get("id"), 4)
        if k < best_rank:
            best, best_rank = i, k

    if best >= 0:
        how = ("credit ORDER (no usable relation)" if best_rank == 4
               else "relation rank=%d" % best_rank)
        return credit_name(performers[best]), composers, how
    if ac:
        return credit_name(ac[0]), composers, "fallback: first credit, no performers"
    return "", composers, "no credit at all"


ENSEMBLE_TYPES = {"Orchestra", "Choir", "Chorus", "Group"}


def artist_list(rel):
    """The album-header credit list, Qobuz convention: the lead performer, then
    ensembles, then the remaining people. MusicBrainz files the conductor before
    the orchestra; Qobuz shows the orchestra first, and artist.type is what lets
    us tell them apart on releases that publish no roles at all."""
    ac = rel.get("artist-credit") or []
    _, performers = split_artist_credit(ac)
    if not performers:
        return []
    lead, _, _ = display_artist(rel)
    rest = [c for c in performers if credit_name(c) != lead]
    is_ensemble = lambda c: ((c.get("artist") or {}).get("type") or "") in ENSEMBLE_TYPES
    return ([lead]
            + [credit_name(c) for c in rest if is_ensemble(c)]
            + [credit_name(c) for c in rest if not is_ensemble(c)])


if __name__ == "__main__":
    mbid = sys.argv[1]
    rel = probe.get("release/%s?inc=%s&fmt=json" % (mbid, probe.INC))
    if not rel:
        sys.exit("could not fetch %s" % mbid)
    artist, composers, how = display_artist(rel)

    ac = rel.get("artist-credit") or []
    print("release   : %s  (%s)" % (rel.get("title"), mbid))
    print("credit    : %s" % "".join(credit_name(c) + (c.get("joinphrase") or "") for c in ac))
    print("split     : composers=%s" % (composers or "NONE — no ';' joinphrase"))
    print("performers: %s" % [credit_name(c) for c in split_artist_credit(ac)[1]])

    rels = rel.get("relations") or []
    named = [(r.get("type"), role_of(r.get("type")), (r.get("artist") or {}).get("name"))
             for r in rels if r.get("artist")]
    print("rel-level artist relations: %d" % len(named))
    for t, role, name in named[:12]:
        print("   %-22s -> %-10s %s" % (t, role or "(ignored)", name))

    print("\n==> aria would display: %r   [%s]" % (artist, how))


def album_artists(rel, latin=None, deezer=None):
    """The album-header credit list: MusicBrainz's split, ordered Qobuz-style,
    supplemented with any Deezer contributor MB missed.

    Both the guard and the dedup compare LATINISED forms. Skipping that drops
    non-Latin artists silently: MB files Utada as 宇多田ヒカル and Deezer as
    'Hikaru Utada', so a raw comparison rejects a perfectly good match.
    """
    latin = latin or {}
    lat = lambda s: latin.get(s, s)
    ac = rel.get("artist-credit") or []
    credited, performers = split_artist_credit(ac)
    if not credited:
        return None                      # no ';' split: the header keeps the single name

    base = [lat(n) for n in artist_list(rel)]
    seen = {n.lower() for n in base}
    # a composer must never be appended as a performer — MB's own split already
    # said which side of the ';' they sit on. Filter on both the credit name
    # ('Bruch') and the artist name ('Max Bruch'); Deezer may use either.
    composers = {lat(credit_name(c)).lower() for c in credited}
    composers |= {lat((c.get("artist") or {}).get("name") or "").lower() for c in credited}

    # If any MB performer has not been latinised yet, skip the supplement for
    # now. Deezer publishes Latin names, so merging against an unresolved
    # Cyrillic entry lists the same person twice ('Василий Петренко' AND
    # 'Vasily Petrenko'). The names phase resolves it and the next pass merges
    # cleanly — self-healing, and never shows a duplicate in the meantime.
    if any(not _is_latin(n) for n in base):
        return base

    extra = [c for c in (deezer or [])
             if c.lower() not in seen and c.lower() not in composers and c.strip()]
    return base + extra


def _is_latin(s):
    return all(ord(ch) < 0x370 for ch in s)


def deezer_accepted(rel, contributors, latin=None):
    """Guard: trust a Deezer album only if it credits someone MusicBrainz also
    credits as a performer. Compared latinised, for the reason above."""
    latin = latin or {}
    lat = lambda s: latin.get(s, s)
    _, performers = split_artist_credit(rel.get("artist-credit") or [])
    mine = {lat(credit_name(c)).lower() for c in performers}
    return any(c.lower() in mine for c in (contributors or []))
