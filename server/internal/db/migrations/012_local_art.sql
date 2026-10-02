-- Images that live in the library itself: an album folder's cover/folder/front
-- image, and an artist folder's artist/folder image. The local library leads,
-- so these beat anything an enrichment source fetched; only an explicit pick in
-- the editor beats them.
--
-- Rewritten wholesale by every scan from what the walk saw, so a deleted file
-- drops out on the next pass. Its own table rather than columns on `albums`:
-- Albums.Rebuild deletes and re-inserts that table after every scan.
--
-- Artist rows are keyed by album too, with the album artist tag the folder
-- belongs to in `name`: the API files each image under that name and under
-- whatever an edit or a MusicBrainz correction renames it to for that album.
CREATE TABLE local_art (
  kind  TEXT NOT NULL,    -- 'album' (key = albumId, its cover) | 'artist' (key = albumId, its artist's image)
  key   TEXT NOT NULL,
  path  TEXT NOT NULL,    -- relative to MUSIC_DIR
  mtime INTEGER NOT NULL, -- of the image; feeds the URL version so a replaced file reloads
  name  TEXT NOT NULL DEFAULT '', -- artist rows: the album artist tag; '' for covers
  PRIMARY KEY (kind, key)
);
