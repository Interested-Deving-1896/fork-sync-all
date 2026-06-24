package bandwidth

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func newTestService(t *testing.T, cfg Config) *Service {
	t.Helper()
	cfg.Enabled = true
	if cfg.DBPath == "" {
		cfg.DBPath = filepath.Join(t.TempDir(), "bandwidth.db")
	}
	svc, err := New(cfg)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(func() { svc.db.Close() })
	return svc
}

func TestNewService(t *testing.T) {
	svc := newTestService(t, Config{ListenAddr: "127.0.0.1:0"})
	if svc.cfg.CompressionLevel == 0 {
		t.Error("expected default compression level to be set")
	}
}

func TestDisabledService(t *testing.T) {
	_, err := New(Config{Enabled: false})
	if err == nil {
		t.Error("expected error when bandwidth disabled, got nil")
	}
}

func TestRegisterArtifactSizeLimit(t *testing.T) {
	svc := newTestService(t, Config{ArtifactMaxSizeMB: 10})

	// Under limit — should succeed
	err := svc.RegisterArtifact(ArtifactRecord{
		Path:      "/tmp/small.zip",
		SizeBytes: 5 * 1024 * 1024,
		CreatedAt: time.Now(),
	})
	if err != nil {
		t.Errorf("expected no error for small artifact, got: %v", err)
	}

	// Over limit — should fail
	err = svc.RegisterArtifact(ArtifactRecord{
		Path:      "/tmp/large.zip",
		SizeBytes: 20 * 1024 * 1024,
		CreatedAt: time.Now(),
	})
	if err == nil {
		t.Error("expected error for oversized artifact, got nil")
	}
}

func TestEvictExpiredArtifacts(t *testing.T) {
	dir := t.TempDir()
	artifactPath := filepath.Join(dir, "old-artifact.zip")
	if err := os.WriteFile(artifactPath, []byte("data"), 0644); err != nil {
		t.Fatal(err)
	}

	svc := newTestService(t, Config{ArtifactRetentionDays: 30})

	// Register an artifact created 60 days ago
	if err := svc.RegisterArtifact(ArtifactRecord{
		Path:      artifactPath,
		SizeBytes: 4,
		CreatedAt: time.Now().AddDate(0, 0, -60),
	}); err != nil {
		t.Fatal(err)
	}

	svc.evictArtifacts()

	// File should be deleted
	if _, err := os.Stat(artifactPath); !os.IsNotExist(err) {
		t.Error("expected artifact file to be deleted")
	}

	// DB record should be gone
	var count int
	_ = svc.db.QueryRow(`SELECT COUNT(*) FROM artifacts`).Scan(&count)
	if count != 0 {
		t.Errorf("expected 0 artifact records after eviction, got %d", count)
	}
}

func TestArtifactPersistenceAcrossRestart(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "bandwidth.db")

	svc1 := newTestService(t, Config{DBPath: dbPath})
	if err := svc1.RegisterArtifact(ArtifactRecord{
		Path:      "/tmp/artifact.zip",
		SizeBytes: 1024,
		CreatedAt: time.Now(),
		ProjectID: 5,
		JobID:     99,
	}); err != nil {
		t.Fatal(err)
	}
	svc1.db.Close()

	svc2 := newTestService(t, Config{DBPath: dbPath})
	var count int
	_ = svc2.db.QueryRow(`SELECT COUNT(*) FROM artifacts`).Scan(&count)
	if count != 1 {
		t.Errorf("expected 1 artifact after restart, got %d", count)
	}
}

func TestIsCompressible(t *testing.T) {
	cases := []struct {
		ct       string
		expected bool
	}{
		{"text/html; charset=utf-8", true},
		{"application/json", true},
		{"application/javascript", true},
		{"image/png", false},
		{"application/octet-stream", false},
		{"video/mp4", false},
	}
	for _, c := range cases {
		got := isCompressible(c.ct)
		if got != c.expected {
			t.Errorf("isCompressible(%q) = %v, want %v", c.ct, got, c.expected)
		}
	}
}

// --- bdfs eviction tests ---

// TestEvictArtifactFile_NoBdfsArchiveDir verifies that when BdfsArchiveDir is
// empty the file is removed directly without attempting to call bdfs.
func TestEvictArtifactFile_NoBdfsArchiveDir(t *testing.T) {
	dir := t.TempDir()
	f := filepath.Join(dir, "artifact.zip")
	if err := os.WriteFile(f, []byte("payload"), 0644); err != nil {
		t.Fatal(err)
	}

	ok := evictArtifactFile(f, "")
	if !ok {
		t.Fatal("evictArtifactFile returned false, expected true")
	}
	if _, err := os.Stat(f); !os.IsNotExist(err) {
		t.Error("expected file to be removed")
	}
}

// TestEvictArtifactFile_BdfsAbsent verifies that when BdfsArchiveDir is set
// but bdfs is not on PATH, eviction falls back to plain os.Remove.
func TestEvictArtifactFile_BdfsAbsent(t *testing.T) {
	dir := t.TempDir()
	f := filepath.Join(dir, "artifact.zip")
	if err := os.WriteFile(f, []byte("payload"), 0644); err != nil {
		t.Fatal(err)
	}
	archiveDir := filepath.Join(dir, "archives")

	// Ensure bdfs is not findable by restricting PATH to an empty temp dir.
	emptyBin := t.TempDir()
	t.Setenv("PATH", emptyBin)

	ok := evictArtifactFile(f, archiveDir)
	if !ok {
		t.Fatal("evictArtifactFile returned false, expected true (fallback delete)")
	}
	if _, err := os.Stat(f); !os.IsNotExist(err) {
		t.Error("expected file to be removed via fallback delete")
	}
	// Archive dir should not have been created — bdfs was never called.
	if _, err := os.Stat(archiveDir); !os.IsNotExist(err) {
		t.Error("archive dir should not exist when bdfs is absent")
	}
}

// TestEvictArtifactFile_BdfsSucceeds verifies that when a stub bdfs binary is
// present and exits 0, the original file is removed and the archive path is
// logged (we verify the original is gone; the stub writes the archive itself).
func TestEvictArtifactFile_BdfsSucceeds(t *testing.T) {
	dir := t.TempDir()
	f := filepath.Join(dir, "artifact.zip")
	if err := os.WriteFile(f, []byte("payload"), 0644); err != nil {
		t.Fatal(err)
	}
	archiveDir := filepath.Join(dir, "archives")

	// Write a stub bdfs that creates the expected .dwarfs file and exits 0.
	// The stub mimics `bdfs demote --blend-path <src> --image-name <dst> ...`
	// by simply writing a placeholder file at the --image-name path.
	stubBin := t.TempDir()
	stubPath := filepath.Join(stubBin, "bdfs")
	stubScript := `#!/bin/sh
# Parse --image-name from args
while [ $# -gt 0 ]; do
  case "$1" in
    --image-name) shift; IMAGE="$1" ;;
  esac
  shift
done
mkdir -p "$(dirname "$IMAGE")"
echo "stub-dwarfs" > "$IMAGE"
exit 0
`
	if err := os.WriteFile(stubPath, []byte(stubScript), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", stubBin)

	ok := evictArtifactFile(f, archiveDir)
	if !ok {
		t.Fatal("evictArtifactFile returned false, expected true")
	}

	// Original should be gone.
	if _, err := os.Stat(f); !os.IsNotExist(err) {
		t.Error("expected original artifact to be removed after successful demote")
	}

	// Archive directory should exist and contain a .dwarfs file.
	entries, err := os.ReadDir(archiveDir)
	if err != nil {
		t.Fatalf("archive dir not created: %v", err)
	}
	if len(entries) == 0 {
		t.Error("expected at least one .dwarfs file in archive dir")
	}
}

// TestEvictArtifactFile_BdfsFails verifies that when bdfs exits non-zero,
// eviction falls back to plain os.Remove so the artifact is still cleaned up.
func TestEvictArtifactFile_BdfsFails(t *testing.T) {
	dir := t.TempDir()
	f := filepath.Join(dir, "artifact.zip")
	if err := os.WriteFile(f, []byte("payload"), 0644); err != nil {
		t.Fatal(err)
	}
	archiveDir := filepath.Join(dir, "archives")

	// Stub bdfs that always fails.
	stubBin := t.TempDir()
	stubPath := filepath.Join(stubBin, "bdfs")
	if err := os.WriteFile(stubPath, []byte("#!/bin/sh\nexit 1\n"), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", stubBin)

	ok := evictArtifactFile(f, archiveDir)
	if !ok {
		t.Fatal("evictArtifactFile returned false, expected true (fallback delete)")
	}

	// Original should still be removed via the fallback path.
	if _, err := os.Stat(f); !os.IsNotExist(err) {
		t.Error("expected artifact to be removed via fallback delete after bdfs failure")
	}
}

// TestEvictExpiredArtifacts_WithBdfsArchiveDir exercises the full eviction
// pipeline through Service.evictArtifacts with BdfsArchiveDir set and a
// stub bdfs on PATH.
func TestEvictExpiredArtifacts_WithBdfsArchiveDir(t *testing.T) {
	dir := t.TempDir()
	artifactPath := filepath.Join(dir, "old-artifact.zip")
	if err := os.WriteFile(artifactPath, []byte("data"), 0644); err != nil {
		t.Fatal(err)
	}
	archiveDir := filepath.Join(dir, "archives")

	// Stub bdfs that creates the archive file and exits 0.
	stubBin := t.TempDir()
	stubPath := filepath.Join(stubBin, "bdfs")
	stubScript := `#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    --image-name) shift; IMAGE="$1" ;;
  esac
  shift
done
mkdir -p "$(dirname "$IMAGE")"
echo "stub-dwarfs" > "$IMAGE"
exit 0
`
	if err := os.WriteFile(stubPath, []byte(stubScript), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", stubBin)

	svc := newTestService(t, Config{
		ArtifactRetentionDays: 30,
		BdfsArchiveDir:        archiveDir,
	})

	if err := svc.RegisterArtifact(ArtifactRecord{
		Path:      artifactPath,
		SizeBytes: 4,
		CreatedAt: time.Now().AddDate(0, 0, -60),
	}); err != nil {
		t.Fatal(err)
	}

	svc.evictArtifacts()

	// Original file should be gone.
	if _, err := os.Stat(artifactPath); !os.IsNotExist(err) {
		t.Error("expected artifact file to be removed after bdfs demote")
	}

	// DB record should be gone.
	var count int
	_ = svc.db.QueryRow(`SELECT COUNT(*) FROM artifacts`).Scan(&count)
	if count != 0 {
		t.Errorf("expected 0 artifact records after eviction, got %d", count)
	}

	// Archive should exist.
	entries, err := os.ReadDir(archiveDir)
	if err != nil {
		t.Fatalf("archive dir not created: %v", err)
	}
	if len(entries) == 0 {
		t.Error("expected a .dwarfs archive to be created")
	}

	// Stats counter should be incremented.
	if svc.stats.snapshot().ArtifactsEvicted != 1 {
		t.Errorf("expected ArtifactsEvicted=1, got %d", svc.stats.snapshot().ArtifactsEvicted)
	}
}
