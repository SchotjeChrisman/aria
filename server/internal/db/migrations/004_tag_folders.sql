-- Tags no longer nest arbitrarily; they live in one-level folders. A folder is
-- a tag row with folder=1 (holds tags via child.parent, never items itself).
ALTER TABLE tags ADD COLUMN folder INTEGER NOT NULL DEFAULT 0;

-- Flatten legacy depth>1: any tag whose parent is itself parented moves to top.
-- One pass suffices for the shallow data in the wild; deeper chains just lose a
-- level per apply, which is fine (folders are one level now).
UPDATE tags SET parent = NULL
 WHERE parent IN (SELECT id FROM tags WHERE parent IS NOT NULL);

-- Any tag that still has children becomes a folder (that's what having children
-- now means), and a folder carries no items.
UPDATE tags SET folder = 1
 WHERE id IN (SELECT DISTINCT parent FROM tags WHERE parent IS NOT NULL);
DELETE FROM tag_items WHERE tagId IN (SELECT id FROM tags WHERE folder = 1);
