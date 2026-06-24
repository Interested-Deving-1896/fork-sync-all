package dwarfspin

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// stubKubo starts a minimal HTTP server that mimics the Kubo API endpoints
// used by Pinner. It records which endpoints were called so tests can assert
// the correct sequence of API calls.
type stubKubo struct {
	srv      *httptest.Server
	calls    []string // endpoint paths called, in order
	dagCID   string   // CID returned by dag/import
	failDag  bool     // if true, dag/import returns 500
	failPin  bool     // if true, pin/add returns 500
	failUnpin bool    // if true, pin/rm returns 500
}

func newStubKubo(t *testing.T, dagCID string) *stubKubo {
	t.Helper()
	s := &stubKubo{dagCID: dagCID}
	mux := http.NewServeMux()

	mux.HandleFunc("/api/v0/dag/import", func(w http.ResponseWriter, r *http.Request) {
		s.calls = append(s.calls, "/api/v0/dag/import")
		if s.failDag {
			http.Error(w, `{"Message":"dag import failed"}`, http.StatusInternalServerError)
			return
		}
		// Drain the request body so the client doesn't get a broken pipe.
		_, _ = io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"Root": map[string]any{
				"Cid": map[string]string{"/": s.dagCID},
			},
		})
	})

	mux.HandleFunc("/api/v0/pin/add", func(w http.ResponseWriter, r *http.Request) {
		s.calls = append(s.calls, "/api/v0/pin/add")
		if s.failPin {
			http.Error(w, `{"Message":"pin failed"}`, http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"Pins": []string{s.dagCID}})
	})

	mux.HandleFunc("/api/v0/pin/rm", func(w http.ResponseWriter, r *http.Request) {
		s.calls = append(s.calls, "/api/v0/pin/rm")
		if s.failUnpin {
			http.Error(w, `{"Message":"unpin failed"}`, http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"Pins": []string{s.dagCID}})
	})

	s.srv = httptest.NewServer(mux)
	t.Cleanup(s.srv.Close)
	return s
}

func (s *stubKubo) called(endpoint string) bool {
	for _, c := range s.calls {
		if c == endpoint {
			return true
		}
	}
	return false
}

// newTestPinner creates a Pinner backed by a stub Kubo server and a temp index.
func newTestPinner(t *testing.T, kuboURL, indexPath string) *Pinner {
	t.Helper()
	p, err := New(Config{
		Enabled:     true,
		KuboAPI:     kuboURL,
		ChunkSizeKB: 64,
		IndexPath:   indexPath,
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(func() { p.Close() })
	return p
}

func tempArchive(t *testing.T, content string) string {
	t.Helper()
	f, err := os.CreateTemp(t.TempDir(), "*.dwarfs")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = f.WriteString(content)
	f.Close()
	return f.Name()
}

// --- New ---

func TestNew_Disabled(t *testing.T) {
	p, err := New(Config{Enabled: false})
	if err != nil {
		t.Fatalf("New(disabled) returned error: %v", err)
	}
	if p != nil {
		t.Error("expected nil Pinner when disabled")
	}
}

func TestNew_MissingKuboAPI(t *testing.T) {
	_, err := New(Config{Enabled: true, IndexPath: filepath.Join(t.TempDir(), "idx.db")})
	if err == nil {
		t.Fatal("expected error when KuboAPI is empty")
	}
}

func TestNew_DefaultsApplied(t *testing.T) {
	stub := newStubKubo(t, "QmTest")
	idx := filepath.Join(t.TempDir(), "idx.db")
	p, err := New(Config{Enabled: true, KuboAPI: stub.srv.URL, IndexPath: idx})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer p.Close()
	if p.cfg.ChunkSizeKB != defaultChunkSizeKB {
		t.Errorf("expected default ChunkSizeKB=%d, got %d", defaultChunkSizeKB, p.cfg.ChunkSizeKB)
	}
}

// --- Pin ---

func TestPin_NilPinner(t *testing.T) {
	var p *Pinner
	result, err := p.Pin(context.Background(), "/any/path.dwarfs")
	if err != nil {
		t.Fatalf("nil Pinner.Pin returned error: %v", err)
	}
	if result.CID != "" {
		t.Errorf("expected empty CID from nil Pinner, got %q", result.CID)
	}
}

func TestPin_Success(t *testing.T) {
	const wantCID = "QmPinnedArchive123"
	stub := newStubKubo(t, wantCID)
	idx := filepath.Join(t.TempDir(), "idx.db")
	p := newTestPinner(t, stub.srv.URL, idx)

	archive := tempArchive(t, "dwarfs-content")
	result, err := p.Pin(context.Background(), archive)
	if err != nil {
		t.Fatalf("Pin: %v", err)
	}
	if result.CID != wantCID {
		t.Errorf("CID = %q, want %q", result.CID, wantCID)
	}
	if result.Cached {
		t.Error("expected Cached=false on first pin")
	}
	if result.SizeBytes == 0 {
		t.Error("expected non-zero SizeBytes")
	}
	if !stub.called("/api/v0/dag/import") {
		t.Error("expected dag/import to be called")
	}
	if !stub.called("/api/v0/pin/add") {
		t.Error("expected pin/add to be called")
	}
}

func TestPin_CachedOnSecondCall(t *testing.T) {
	const wantCID = "QmCachedCID"
	stub := newStubKubo(t, wantCID)
	idx := filepath.Join(t.TempDir(), "idx.db")
	p := newTestPinner(t, stub.srv.URL, idx)

	archive := tempArchive(t, "content")

	// First call — hits Kubo.
	if _, err := p.Pin(context.Background(), archive); err != nil {
		t.Fatalf("first Pin: %v", err)
	}

	// Reset call log.
	stub.calls = nil

	// Second call — should return cached CID without calling Kubo.
	result, err := p.Pin(context.Background(), archive)
	if err != nil {
		t.Fatalf("second Pin: %v", err)
	}
	if !result.Cached {
		t.Error("expected Cached=true on second pin")
	}
	if result.CID != wantCID {
		t.Errorf("cached CID = %q, want %q", result.CID, wantCID)
	}
	if stub.called("/api/v0/dag/import") {
		t.Error("dag/import should not be called on cached pin")
	}
}

func TestPin_DagImportFails(t *testing.T) {
	stub := newStubKubo(t, "QmAny")
	stub.failDag = true
	idx := filepath.Join(t.TempDir(), "idx.db")
	p := newTestPinner(t, stub.srv.URL, idx)

	archive := tempArchive(t, "content")
	_, err := p.Pin(context.Background(), archive)
	if err == nil {
		t.Fatal("expected error when dag/import fails, got nil")
	}
	if !strings.Contains(err.Error(), "dag/import") {
		t.Errorf("error should mention dag/import, got: %v", err)
	}
}

func TestPin_PinAddFails(t *testing.T) {
	stub := newStubKubo(t, "QmAny")
	stub.failPin = true
	idx := filepath.Join(t.TempDir(), "idx.db")
	p := newTestPinner(t, stub.srv.URL, idx)

	archive := tempArchive(t, "content")
	_, err := p.Pin(context.Background(), archive)
	if err == nil {
		t.Fatal("expected error when pin/add fails, got nil")
	}
	if !strings.Contains(err.Error(), "pin/add") {
		t.Errorf("error should mention pin/add, got: %v", err)
	}
}

func TestPin_ArchiveNotFound(t *testing.T) {
	stub := newStubKubo(t, "QmAny")
	idx := filepath.Join(t.TempDir(), "idx.db")
	p := newTestPinner(t, stub.srv.URL, idx)

	_, err := p.Pin(context.Background(), "/nonexistent/archive.dwarfs")
	if err == nil {
		t.Fatal("expected error for missing archive, got nil")
	}
}

func TestPin_ContextCancelled(t *testing.T) {
	stub := newStubKubo(t, "QmAny")
	idx := filepath.Join(t.TempDir(), "idx.db")
	p := newTestPinner(t, stub.srv.URL, idx)

	archive := tempArchive(t, "content")
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // cancel immediately

	_, err := p.Pin(ctx, archive)
	if err == nil {
		t.Fatal("expected error with cancelled context, got nil")
	}
}

// --- Unpin ---

func TestUnpin_NilPinner(t *testing.T) {
	var p *Pinner
	if err := p.Unpin(context.Background(), "/any.dwarfs"); err != nil {
		t.Fatalf("nil Pinner.Unpin returned error: %v", err)
	}
}

func TestUnpin_NotInIndex(t *testing.T) {
	stub := newStubKubo(t, "QmAny")
	idx := filepath.Join(t.TempDir(), "idx.db")
	p := newTestPinner(t, stub.srv.URL, idx)

	err := p.Unpin(context.Background(), "/not/pinned.dwarfs")
	if err == nil {
		t.Fatal("expected error when path not in index, got nil")
	}
}

func TestUnpin_Success(t *testing.T) {
	const wantCID = "QmToUnpin"
	stub := newStubKubo(t, wantCID)
	idx := filepath.Join(t.TempDir(), "idx.db")
	p := newTestPinner(t, stub.srv.URL, idx)

	archive := tempArchive(t, "content")

	// Pin first.
	if _, err := p.Pin(context.Background(), archive); err != nil {
		t.Fatalf("Pin: %v", err)
	}

	// Unpin.
	if err := p.Unpin(context.Background(), archive); err != nil {
		t.Fatalf("Unpin: %v", err)
	}
	if !stub.called("/api/v0/pin/rm") {
		t.Error("expected pin/rm to be called")
	}

	// Index entry should be gone.
	cid, _ := p.index.Lookup(archive)
	if cid != "" {
		t.Errorf("expected index entry to be deleted after unpin, got CID %q", cid)
	}
}

func TestUnpin_PinRmFails(t *testing.T) {
	stub := newStubKubo(t, "QmAny")
	idx := filepath.Join(t.TempDir(), "idx.db")
	p := newTestPinner(t, stub.srv.URL, idx)

	archive := tempArchive(t, "content")
	if _, err := p.Pin(context.Background(), archive); err != nil {
		t.Fatalf("Pin: %v", err)
	}

	stub.failUnpin = true
	err := p.Unpin(context.Background(), archive)
	if err == nil {
		t.Fatal("expected error when pin/rm fails, got nil")
	}
}

// --- Stat ---

func TestStat_NilPinner(t *testing.T) {
	var p *Pinner
	_, err := p.Stat("/any.dwarfs")
	if err == nil {
		t.Fatal("expected error from nil Pinner.Stat")
	}
}

func TestStat_NotInIndex(t *testing.T) {
	stub := newStubKubo(t, "QmAny")
	idx := filepath.Join(t.TempDir(), "idx.db")
	p := newTestPinner(t, stub.srv.URL, idx)

	_, err := p.Stat("/not/pinned.dwarfs")
	if err == nil {
		t.Fatal("expected error for path not in index")
	}
}

func TestStat_Found(t *testing.T) {
	const wantCID = "QmStatTest"
	stub := newStubKubo(t, wantCID)
	idx := filepath.Join(t.TempDir(), "idx.db")
	p := newTestPinner(t, stub.srv.URL, idx)

	archive := tempArchive(t, "content")
	if _, err := p.Pin(context.Background(), archive); err != nil {
		t.Fatalf("Pin: %v", err)
	}

	cid, err := p.Stat(archive)
	if err != nil {
		t.Fatalf("Stat: %v", err)
	}
	if cid != wantCID {
		t.Errorf("Stat CID = %q, want %q", cid, wantCID)
	}
}

// --- Index ---

func TestIndex_RecordAndLookup(t *testing.T) {
	idx, err := OpenIndex(filepath.Join(t.TempDir(), "idx.db"))
	if err != nil {
		t.Fatalf("OpenIndex: %v", err)
	}
	defer idx.Close()

	if err := idx.Record("/path/to/archive.dwarfs", "QmTestCID"); err != nil {
		t.Fatalf("Record: %v", err)
	}

	cid, err := idx.Lookup("/path/to/archive.dwarfs")
	if err != nil {
		t.Fatalf("Lookup: %v", err)
	}
	if cid != "QmTestCID" {
		t.Errorf("Lookup = %q, want %q", cid, "QmTestCID")
	}
}

func TestIndex_LookupMissing(t *testing.T) {
	idx, err := OpenIndex(filepath.Join(t.TempDir(), "idx.db"))
	if err != nil {
		t.Fatalf("OpenIndex: %v", err)
	}
	defer idx.Close()

	cid, err := idx.Lookup("/not/there.dwarfs")
	if err != nil {
		t.Fatalf("Lookup on missing key returned error: %v", err)
	}
	if cid != "" {
		t.Errorf("expected empty CID for missing key, got %q", cid)
	}
}

func TestIndex_Delete(t *testing.T) {
	idx, err := OpenIndex(filepath.Join(t.TempDir(), "idx.db"))
	if err != nil {
		t.Fatalf("OpenIndex: %v", err)
	}
	defer idx.Close()

	_ = idx.Record("/archive.dwarfs", "QmToDelete")
	if err := idx.Delete("/archive.dwarfs"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	cid, _ := idx.Lookup("/archive.dwarfs")
	if cid != "" {
		t.Errorf("expected empty CID after delete, got %q", cid)
	}
}

func TestIndex_List(t *testing.T) {
	idx, err := OpenIndex(filepath.Join(t.TempDir(), "idx.db"))
	if err != nil {
		t.Fatalf("OpenIndex: %v", err)
	}
	defer idx.Close()

	_ = idx.Record("/a.dwarfs", "QmA")
	time.Sleep(time.Millisecond) // ensure distinct pinned_at timestamps
	_ = idx.Record("/b.dwarfs", "QmB")

	entries, err := idx.List()
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("expected 2 entries, got %d", len(entries))
	}
	// List is ordered by pinned_at DESC — most recent first.
	if entries[0].Path != "/b.dwarfs" {
		t.Errorf("expected /b.dwarfs first (most recent), got %s", entries[0].Path)
	}
}

func TestIndex_RecordIdempotent(t *testing.T) {
	idx, err := OpenIndex(filepath.Join(t.TempDir(), "idx.db"))
	if err != nil {
		t.Fatalf("OpenIndex: %v", err)
	}
	defer idx.Close()

	_ = idx.Record("/archive.dwarfs", "QmFirst")
	_ = idx.Record("/archive.dwarfs", "QmSecond") // replace

	cid, _ := idx.Lookup("/archive.dwarfs")
	if cid != "QmSecond" {
		t.Errorf("expected QmSecond after replace, got %q", cid)
	}
}

func TestIndex_PersistsAcrossReopen(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "idx.db")

	idx1, _ := OpenIndex(dbPath)
	_ = idx1.Record("/archive.dwarfs", "QmPersisted")
	idx1.Close()

	idx2, err := OpenIndex(dbPath)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer idx2.Close()

	cid, _ := idx2.Lookup("/archive.dwarfs")
	if cid != "QmPersisted" {
		t.Errorf("expected QmPersisted after reopen, got %q", cid)
	}
}
