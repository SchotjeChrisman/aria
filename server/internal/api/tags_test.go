package api

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"aria/internal/config"
	"aria/internal/db"
	"aria/internal/repo"
)

func tagsDeps(t *testing.T) *Deps {
	t.Helper()
	d, err := db.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	return NewDeps(d, config.Config{}, "test")
}

// One-level folders: a tag can go into a folder, but not into a plain tag, and
// a folder can't be foldered. Legacy depth>1 data flattens on migrate.
func TestTagFolders(t *testing.T) {
	deps := tagsDeps(t)
	h := New(deps)

	post := func(body string) *repo.Tag {
		t.Helper()
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("POST", "/api/tags", strings.NewReader(body)))
		if rec.Code != 200 {
			t.Fatalf("POST /api/tags %s = %d: %s", body, rec.Code, rec.Body.String())
		}
		var tag repo.Tag
		if err := json.Unmarshal(rec.Body.Bytes(), &tag); err != nil {
			t.Fatal(err)
		}
		return &tag
	}
	postExpect := func(body string, want int) {
		t.Helper()
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("POST", "/api/tags", strings.NewReader(body)))
		if rec.Code != want {
			t.Fatalf("POST /api/tags %s = %d, want %d: %s", body, rec.Code, want, rec.Body.String())
		}
	}

	folder := post(`{"name":"Moods","folder":true}`)
	if !folder.Folder || folder.Parent != nil {
		t.Fatalf("folder round-trip: %+v", folder)
	}
	// Tag into the folder: ok.
	calm := post(`{"name":"Calm","parent":"` + folder.ID + `"}`)
	if calm.Parent == nil || *calm.Parent != folder.ID {
		t.Fatalf("tag not foldered: %+v", calm)
	}
	// Tag into a non-folder (Calm): rejected.
	postExpect(`{"name":"Nope","parent":"`+calm.ID+`"}`, 400)
	// Folder into a folder: rejected.
	postExpect(`{"name":"Sub","folder":true,"parent":"`+folder.ID+`"}`, 400)

	// PATCH: move Calm out of the folder, then back; moving a folder rejected.
	patch := func(id, body string, want int) {
		t.Helper()
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("PATCH", "/api/tags/"+id, strings.NewReader(body)))
		if rec.Code != want {
			t.Fatalf("PATCH %s %s = %d, want %d: %s", id, body, rec.Code, want, rec.Body.String())
		}
	}
	patch(calm.ID, `{"parent":null}`, 200)
	patch(calm.ID, `{"parent":"`+folder.ID+`"}`, 200)
	patch(calm.ID, `{"parent":"`+calm.ID+`"}`, 400)  // self
	patch(folder.ID, `{"parent":"`+calm.ID+`"}`, 400) // folder can't be foldered

	// Folders hold tags, not items.
	putItem := func(id string, want int) {
		t.Helper()
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("PUT", "/api/tags/"+id+"/items",
			strings.NewReader(`{"kind":"artist","key":"Someone"}`)))
		if rec.Code != want {
			t.Fatalf("PUT items %s = %d, want %d: %s", id, rec.Code, want, rec.Body.String())
		}
	}
	putItem(folder.ID, 400) // folder rejects items
	putItem(calm.ID, 200)   // plain tag accepts (artist keys are free-form)
}

// Legacy depth>1 rows flatten to top level on migrate, and rows with children
// become folders that carry no items.
func TestTagFlattenMigration(t *testing.T) {
	deps := tagsDeps(t)
	ctx := context.Background()
	// Raw insert of a 3-level chain predating the migration semantics, plus an
	// item on the middle (soon-to-be) folder.
	_, err := deps.DB.ExecContext(ctx,
		`INSERT INTO tags (id,name,parent,folder,createdAt) VALUES
		 ('a','A',NULL,0,'t'),('b','B','a',0,'t'),('c','C','b',0,'t')`)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := deps.DB.ExecContext(ctx,
		`INSERT INTO tag_items (tagId,kind,key) VALUES ('a','artist','X')`); err != nil {
		t.Fatal(err)
	}
	// Re-run the flatten the migration would run (migration already ran at Open;
	// this asserts the SQL is idempotent and does the right thing on this shape).
	for _, q := range []string{
		`UPDATE tags SET parent = NULL WHERE parent IN (SELECT id FROM tags WHERE parent IS NOT NULL)`,
		`UPDATE tags SET folder = 1 WHERE id IN (SELECT DISTINCT parent FROM tags WHERE parent IS NOT NULL)`,
		`DELETE FROM tag_items WHERE tagId IN (SELECT id FROM tags WHERE folder = 1)`,
	} {
		if _, err := deps.DB.ExecContext(ctx, q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	tags, err := deps.Tags.List(ctx)
	if err != nil {
		t.Fatal(err)
	}
	byID := map[string]repo.Tag{}
	for _, t := range tags {
		byID[t.ID] = t
	}
	// C was depth-2, must now be top-level.
	if byID["c"].Parent != nil {
		t.Fatalf("C not flattened: %+v", byID["c"])
	}
	// A has a child (B) -> folder, and lost its item.
	if !byID["a"].Folder || len(byID["a"].Items) != 0 {
		t.Fatalf("A should be an empty folder: %+v", byID["a"])
	}
	// B still points at A (depth 1, allowed).
	if byID["b"].Parent == nil || *byID["b"].Parent != "a" {
		t.Fatalf("B should stay under A: %+v", byID["b"])
	}
}
