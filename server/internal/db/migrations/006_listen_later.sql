-- Listen Later: albums the user does not own yet, saved so they don't have to
-- be written down somewhere else.
--
-- id is a universal album identity, preferring the MusicBrainz release-group
-- MBID ("rg:<uuid>") and falling back to the Deezer album id ("dz:<id>") for
-- records MusicBrainz has not ingested yet — which is the normal case for the
-- first weeks of a release, exactly the window this feature lives in.
--
-- Release-group, not release: buying the remaster clears an entry added from
-- the original pressing. upc and deezerId ride along as the cross-service
-- bridge (Deezer, MusicBrainz and Qobuz all carry the barcode), so a lookup in
-- another catalogue never needs a re-key or a migration.
--
-- artist/title/titleKey/cover/date/type are denormalized so the list renders
-- and the ownership fallback works without a network round trip.
CREATE TABLE listen_later (
  id        TEXT NOT NULL,
  profileId TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  artist    TEXT NOT NULL,
  title     TEXT NOT NULL,
  titleKey  TEXT NOT NULL,
  upc       TEXT,
  deezerId  INTEGER,
  cover     TEXT,
  date      TEXT,
  type      TEXT NOT NULL,
  releases  TEXT,
  addedAt   TEXT NOT NULL,
  PRIMARY KEY (profileId, id)
);
CREATE INDEX idx_listen_later_profileId ON listen_later(profileId);
