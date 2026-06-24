package bdfs

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeBin writes a shell script stub to dir/<name> and makes it executable.
// exitCode controls the stub's exit status.
// recordFile, when non-empty, is a path the stub appends its arguments to so
// tests can assert which flags were passed.
func writeBin(t *testing.T, dir, name string, exitCode int, recordFile string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	var sb strings.Builder
	sb.WriteString("#!/bin/sh\n")
	if recordFile != "" {
		sb.WriteString(`echo "$@" >> `)
		sb.WriteString(recordFile)
		sb.WriteString("\n")
	}
	sb.WriteString("exit ")
	sb.WriteString(strings.TrimSpace(strings.Repeat("0", 1-exitCode) + strings.Repeat("1", exitCode)))
	// simpler: just write the literal exit code
	sb.Reset()
	sb.WriteString("#!/bin/sh\n")
	if recordFile != "" {
		sb.WriteString(`printf '%s\n' "$@" >> `)
		sb.WriteString(recordFile)
		sb.WriteString("\n")
	}
	if exitCode == 0 {
		sb.WriteString("exit 0\n")
	} else {
		sb.WriteString("exit 1\n")
	}
	if err := os.WriteFile(p, []byte(sb.String()), 0755); err != nil {
		t.Fatalf("writeBin %s: %v", name, err)
	}
	return p
}

// stubPATH creates a temp bin dir, writes the requested stubs into it, sets
// PATH to that dir only, and returns the dir path.
func stubPATH(t *testing.T, stubs map[string]int, recordFile string) string {
	t.Helper()
	bin := t.TempDir()
	for name, code := range stubs {
		writeBin(t, bin, name, code, recordFile)
	}
	t.Setenv("PATH", bin)
	return bin
}

// --- Snapshot ---

func TestSnapshot_DisabledByConfig(t *testing.T) {
	// SnapshotOnServe=false — bfg must never be called even if present.
	bin := t.TempDir()
	rec := filepath.Join(t.TempDir(), "calls.txt")
	writeBin(t, bin, "bfg", 0, rec)
	t.Setenv("PATH", bin)

	lc := New(Config{StoragePath: "/lfs", SnapshotOnServe: false})
	if err := lc.Snapshot(); err != nil {
		t.Fatalf("Snapshot() returned error when disabled: %v", err)
	}
	if _, err := os.Stat(rec); !os.IsNotExist(err) {
		t.Error("bfg was called despite SnapshotOnServe=false")
	}
}

func TestSnapshot_BfgAbsent(t *testing.T) {
	// bfg not on PATH — should return nil, not an error.
	t.Setenv("PATH", t.TempDir())
	lc := New(Config{StoragePath: "/lfs", SnapshotOnServe: true})
	if err := lc.Snapshot(); err != nil {
		t.Fatalf("Snapshot() returned error when bfg absent: %v", err)
	}
}

func TestSnapshot_BfgSucceeds(t *testing.T) {
	rec := filepath.Join(t.TempDir(), "calls.txt")
	stubPATH(t, map[string]int{"bfg": 0}, rec)

	lc := New(Config{StoragePath: "/var/lfs", SnapshotOnServe: true})
	if err := lc.Snapshot(); err != nil {
		t.Fatalf("Snapshot() unexpected error: %v", err)
	}

	data, _ := os.ReadFile(rec)
	args := string(data)
	if !strings.Contains(args, "local_commit") {
		t.Errorf("expected bfg to be called with local_commit, got: %q", args)
	}
	if !strings.Contains(args, "/var/lfs") {
		t.Errorf("expected bfg to receive StoragePath, got: %q", args)
	}
}

func TestSnapshot_BfgFails(t *testing.T) {
	stubPATH(t, map[string]int{"bfg": 1}, "")

	lc := New(Config{StoragePath: "/var/lfs", SnapshotOnServe: true})
	err := lc.Snapshot()
	if err == nil {
		t.Fatal("Snapshot() expected error when bfg exits non-zero, got nil")
	}
	if !strings.Contains(err.Error(), "bfg local_commit") {
		t.Errorf("error message should mention bfg local_commit, got: %v", err)
	}
}

// --- Demote ---

func TestDemote_BdfsAbsent(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	lc := New(Config{StoragePath: "/var/lfs"})
	if err := lc.Demote(); err != nil {
		t.Fatalf("Demote() returned error when bdfs absent: %v", err)
	}
}

func TestDemote_BdfsSucceeds(t *testing.T) {
	rec := filepath.Join(t.TempDir(), "calls.txt")
	stubPATH(t, map[string]int{"bdfs": 0}, rec)

	lc := New(Config{StoragePath: "/var/lfs", Compression: "zstd"})
	if err := lc.Demote(); err != nil {
		t.Fatalf("Demote() unexpected error: %v", err)
	}

	data, _ := os.ReadFile(rec)
	args := string(data)
	if !strings.Contains(args, "demote") {
		t.Errorf("expected bdfs demote subcommand, got: %q", args)
	}
	if !strings.Contains(args, "/var/lfs") {
		t.Errorf("expected StoragePath in args, got: %q", args)
	}
	if !strings.Contains(args, "zstd") {
		t.Errorf("expected compression=zstd in args, got: %q", args)
	}
	// Image name should be StoragePath + ".dwarfs"
	if !strings.Contains(args, "/var/lfs.dwarfs") {
		t.Errorf("expected image-name=/var/lfs.dwarfs in args, got: %q", args)
	}
}

func TestDemote_BdfsFails(t *testing.T) {
	stubPATH(t, map[string]int{"bdfs": 1}, "")

	lc := New(Config{StoragePath: "/var/lfs"})
	err := lc.Demote()
	if err == nil {
		t.Fatal("Demote() expected error when bdfs exits non-zero, got nil")
	}
	if !strings.Contains(err.Error(), "bdfs demote") {
		t.Errorf("error message should mention bdfs demote, got: %v", err)
	}
}

func TestDemote_DefaultCompression(t *testing.T) {
	// When Compression is empty, New() should default to "zstd".
	rec := filepath.Join(t.TempDir(), "calls.txt")
	stubPATH(t, map[string]int{"bdfs": 0}, rec)

	lc := New(Config{StoragePath: "/var/lfs"}) // Compression intentionally empty
	if err := lc.Demote(); err != nil {
		t.Fatalf("Demote() unexpected error: %v", err)
	}
	data, _ := os.ReadFile(rec)
	if !strings.Contains(string(data), "zstd") {
		t.Errorf("expected default compression zstd, got: %q", string(data))
	}
}

// --- Prune ---

func TestPrune_DisabledWhenKeepZero(t *testing.T) {
	// PruneKeep=0 — bdfs must never be called.
	bin := t.TempDir()
	rec := filepath.Join(t.TempDir(), "calls.txt")
	writeBin(t, bin, "bdfs", 0, rec)
	t.Setenv("PATH", bin)

	lc := New(Config{StoragePath: "/var/lfs", PruneKeep: 0})
	if err := lc.Prune(); err != nil {
		t.Fatalf("Prune() returned error when keep=0: %v", err)
	}
	if _, err := os.Stat(rec); !os.IsNotExist(err) {
		t.Error("bdfs was called despite PruneKeep=0")
	}
}

func TestPrune_BdfsAbsent(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	lc := New(Config{StoragePath: "/var/lfs", PruneKeep: 5})
	if err := lc.Prune(); err != nil {
		t.Fatalf("Prune() returned error when bdfs absent: %v", err)
	}
}

func TestPrune_BdfsSucceeds_NoPattern(t *testing.T) {
	rec := filepath.Join(t.TempDir(), "calls.txt")
	stubPATH(t, map[string]int{"bdfs": 0}, rec)

	lc := New(Config{StoragePath: "/var/lfs", PruneKeep: 5, Compression: "zstd"})
	if err := lc.Prune(); err != nil {
		t.Fatalf("Prune() unexpected error: %v", err)
	}

	data, _ := os.ReadFile(rec)
	args := string(data)
	for _, want := range []string{"snapshot", "prune", "--btrfs-mount", "/var/lfs", "--keep", "5", "--demote-first", "zstd"} {
		if !strings.Contains(args, want) {
			t.Errorf("expected %q in bdfs args, got: %q", want, args)
		}
	}
	// --pattern should NOT appear when PrunePattern is empty
	if strings.Contains(args, "--pattern") {
		t.Errorf("--pattern should not appear when PrunePattern is empty, got: %q", args)
	}
}

func TestPrune_BdfsSucceeds_WithPattern(t *testing.T) {
	rec := filepath.Join(t.TempDir(), "calls.txt")
	stubPATH(t, map[string]int{"bdfs": 0}, rec)

	lc := New(Config{
		StoragePath:  "/var/lfs",
		PruneKeep:    3,
		PrunePattern: "lfs-snap-*",
		Compression:  "lzma",
	})
	if err := lc.Prune(); err != nil {
		t.Fatalf("Prune() unexpected error: %v", err)
	}

	data, _ := os.ReadFile(rec)
	args := string(data)
	if !strings.Contains(args, "--pattern") {
		t.Errorf("expected --pattern in args, got: %q", args)
	}
	if !strings.Contains(args, "lfs-snap-*") {
		t.Errorf("expected pattern value in args, got: %q", args)
	}
	if !strings.Contains(args, "lzma") {
		t.Errorf("expected compression=lzma in args, got: %q", args)
	}
}

func TestPrune_BdfsFails(t *testing.T) {
	stubPATH(t, map[string]int{"bdfs": 1}, "")

	lc := New(Config{StoragePath: "/var/lfs", PruneKeep: 5})
	err := lc.Prune()
	if err == nil {
		t.Fatal("Prune() expected error when bdfs exits non-zero, got nil")
	}
	if !strings.Contains(err.Error(), "bdfs snapshot prune") {
		t.Errorf("error message should mention bdfs snapshot prune, got: %v", err)
	}
}
