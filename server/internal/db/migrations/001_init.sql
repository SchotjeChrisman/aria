-- Field set mirrors the legacy scanner.js index.json entries, plus mtime/size
-- for incremental rescans. id = sha1(path relative to MUSIC_DIR),
-- albumId = sha1(lower(albumArtist) || char(0) || lower(album)).
CREATE TABLE tracks (
  id              TEXT PRIMARY KEY,
  path            TEXT NOT NULL UNIQUE,
  mtime           INTEGER NOT NULL DEFAULT 0,
  size            INTEGER NOT NULL DEFAULT 0,
  addedAt         TEXT NOT NULL,
  title           TEXT NOT NULL,
  artist          TEXT NOT NULL,
  albumArtist     TEXT NOT NULL,
  album           TEXT NOT NULL,
  albumId         TEXT NOT NULL,
  trackNo         INTEGER,
  discNo          INTEGER,
  year            INTEGER,
  genre           TEXT,
  composer        TEXT,
  conductor       TEXT,
  work            TEXT,
  movement        TEXT,
  mbAlbumId       TEXT,
  mbRecordingId   TEXT,
  mbAlbumArtistId TEXT,
  duration        REAL,
  format          TEXT NOT NULL DEFAULT '',
  sampleRate      INTEGER,
  bitsPerSample   INTEGER,
  channels        INTEGER,
  lossless        INTEGER NOT NULL DEFAULT 0,
  hasArt          INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_tracks_albumId ON tracks(albumId);
CREATE INDEX idx_tracks_artist ON tracks(artist);
CREATE INDEX idx_tracks_albumArtist ON tracks(albumArtist);

-- Derived from tracks after each scan (Albums.Rebuild); never edited directly.
CREATE TABLE albums (
  albumId     TEXT PRIMARY KEY,
  album       TEXT NOT NULL,
  albumArtist TEXT NOT NULL,
  year        INTEGER,
  genre       TEXT,
  trackCount  INTEGER NOT NULL DEFAULT 0,
  duration    REAL NOT NULL DEFAULT 0,
  hasArt      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE profiles (
  id        TEXT PRIMARY KEY,
  name      TEXT NOT NULL,
  color     TEXT NOT NULL,
  createdAt TEXT NOT NULL
);

-- trackId intentionally not a FK: plays outlive rescans; stale ids still count
-- toward totalPlays (legacy semantics).
CREATE TABLE plays (
  id        INTEGER PRIMARY KEY,
  trackId   TEXT NOT NULL,
  profileId TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  at        TEXT NOT NULL
);
CREATE INDEX idx_plays_profileId ON plays(profileId);
CREATE INDEX idx_plays_trackId ON plays(trackId);

CREATE TABLE tags (
  id        TEXT PRIMARY KEY,
  name      TEXT NOT NULL,
  parent    TEXT REFERENCES tags(id),
  createdAt TEXT NOT NULL
);

-- key: track id, albumId, or free-form artist name (any name is a door).
CREATE TABLE tag_items (
  tagId TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  kind  TEXT NOT NULL CHECK (kind IN ('track','album','artist')),
  key   TEXT NOT NULL,
  PRIMARY KEY (tagId, kind, key)
);

CREATE TABLE playlists (
  id        TEXT PRIMARY KEY,
  profileId TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  name      TEXT NOT NULL,
  type      TEXT NOT NULL CHECK (type IN ('manual','smart')),
  rules     TEXT,
  createdAt TEXT NOT NULL,
  updatedAt TEXT NOT NULL
);
CREATE INDEX idx_playlists_profileId ON playlists(profileId);

-- pos is append-only (max+1); gaps after removals are fine, order-by-pos holds.
-- Duplicate trackIds allowed (legacy semantics), hence pos in the PK.
CREATE TABLE playlist_tracks (
  playlistId TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
  pos        INTEGER NOT NULL,
  trackId    TEXT NOT NULL,
  PRIMARY KEY (playlistId, pos)
);

-- Metadata overrides; json is an object of field -> value (legacy edits.json).
CREATE TABLE edits (
  kind TEXT NOT NULL CHECK (kind IN ('track','album','artist')),
  key  TEXT NOT NULL,
  json TEXT NOT NULL,
  PRIMARY KEY (kind, key)
);

-- json may be the literal 'null': a negative-cache entry (looked up, nothing found).
CREATE TABLE enrich_cache (
  kind      TEXT NOT NULL,
  key       TEXT NOT NULL,
  json      TEXT NOT NULL,
  fetchedAt TEXT NOT NULL,
  PRIMARY KEY (kind, key)
);

CREATE TABLE settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- User stations only; builtins live in code.
CREATE TABLE radio (
  id        TEXT PRIMARY KEY,
  name      TEXT NOT NULL,
  url       TEXT NOT NULL,
  genre     TEXT,
  createdAt TEXT NOT NULL
);

CREATE VIRTUAL TABLE tracks_fts USING fts5(
  title, artist, albumArtist, album, composer,
  content='tracks', content_rowid='rowid'
);

CREATE TRIGGER tracks_ai AFTER INSERT ON tracks BEGIN
  INSERT INTO tracks_fts(rowid, title, artist, albumArtist, album, composer)
  VALUES (new.rowid, new.title, new.artist, new.albumArtist, new.album, new.composer);
END;

CREATE TRIGGER tracks_ad AFTER DELETE ON tracks BEGIN
  INSERT INTO tracks_fts(tracks_fts, rowid, title, artist, albumArtist, album, composer)
  VALUES ('delete', old.rowid, old.title, old.artist, old.albumArtist, old.album, old.composer);
END;

CREATE TRIGGER tracks_au AFTER UPDATE ON tracks BEGIN
  INSERT INTO tracks_fts(tracks_fts, rowid, title, artist, albumArtist, album, composer)
  VALUES ('delete', old.rowid, old.title, old.artist, old.albumArtist, old.album, old.composer);
  INSERT INTO tracks_fts(rowid, title, artist, albumArtist, album, composer)
  VALUES (new.rowid, new.title, new.artist, new.albumArtist, new.album, new.composer);
END;
