package api

import (
	"io"
	"net/http/httptest"
	"strings"
	"testing"
)

// readerFromRecorder wraps ResponseRecorder with an io.ReaderFrom so the
// delegation path (sendfile in production) is observable.
type readerFromRecorder struct {
	*httptest.ResponseRecorder
	readFromCalled bool
}

func (r *readerFromRecorder) ReadFrom(src io.Reader) (int64, error) {
	r.readFromCalled = true
	return io.Copy(r.ResponseRecorder, src)
}

// ReadFrom must delegate to the wrapped writer's io.ReaderFrom (keeping
// sendfile for /api/stream, /api/art, booklet ServeContent) and still record
// the status set before the copy.
func TestStatusRecorderReadFromDelegates(t *testing.T) {
	under := &readerFromRecorder{ResponseRecorder: httptest.NewRecorder()}
	rec := &statusRecorder{ResponseWriter: under, status: 200}
	rec.WriteHeader(206)
	n, err := rec.ReadFrom(strings.NewReader("audio bytes"))
	if err != nil || n != 11 {
		t.Fatalf("ReadFrom = %d, %v; want 11, nil", n, err)
	}
	if !under.readFromCalled {
		t.Fatal("wrapped io.ReaderFrom was not used")
	}
	if rec.status != 206 {
		t.Fatalf("status = %d, want 206", rec.status)
	}
	if got := under.Body.String(); got != "audio bytes" {
		t.Fatalf("body = %q", got)
	}
}

// Without an underlying io.ReaderFrom the fallback io.Copy path must still
// write through and preserve the recorded status.
func TestStatusRecorderReadFromFallback(t *testing.T) {
	under := httptest.NewRecorder()
	rec := &statusRecorder{ResponseWriter: under, status: 200}
	n, err := rec.ReadFrom(strings.NewReader("ok"))
	if err != nil || n != 2 {
		t.Fatalf("ReadFrom = %d, %v; want 2, nil", n, err)
	}
	if rec.status != 200 {
		t.Fatalf("status = %d, want 200", rec.status)
	}
	if got := under.Body.String(); got != "ok" {
		t.Fatalf("body = %q", got)
	}
}
