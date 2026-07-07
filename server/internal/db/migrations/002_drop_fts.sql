-- No API endpoint queries tracks_fts; the virtual table and its sync
-- triggers were dead weight on every tracks write.
DROP TRIGGER IF EXISTS tracks_ai;
DROP TRIGGER IF EXISTS tracks_ad;
DROP TRIGGER IF EXISTS tracks_au;
DROP TABLE IF EXISTS tracks_fts;
