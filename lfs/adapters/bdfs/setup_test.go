package bdfs

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeBin writes a shell script stub to dir/<name> and makes it executable.
func writeBin(t *testing.T, dir, name, script string) {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"+script), 0755); err != nil {
		t.Fatalf("writeBin %s: %v", name, err)
	}
}

// --- CheckSubvolume ---

func TestCheckSubvolume_NotExist(t *testing.T) {
	result := CheckSubvolume("/nonexistent/path/that/cannot/exist")
	if result.State != StateNotExist {
		t.Errorf("expected StateNotExist, got %s", result.State)
	}
}

func TestCheckSubvolume_BtrfsAbsent(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PATH", t.TempDir())

	result := CheckSubvolume(dir)
	if result.State != StateUnknown {
		t.Errorf("expected StateUnknown when btrfs absent, got %s", result.State)
	}
	if !strings.Contains(result.Detail, "btrfs-progs not found") {
		t.Errorf("expected detail to mention btrfs-progs, got: %q", result.Detail)
	}
}

func TestCheckSubvolume_PlainDir(t *testing.T) {
	dir := t.TempDir()
	stubBin := t.TempDir()
	writeBin(t, stubBin, "btrfs", "echo 'not a subvolume'\nexit 1\n")
	t.Setenv("PATH", stubBin)

	result := CheckSubvolume(dir)
	if result.State != StatePlainDir {
		t.Errorf("expected StatePlainDir, got %s", result.State)
	}
	if result.Path != dir {
		t.Errorf("expected Path=%s, got %s", dir, result.Path)
	}
}

func TestCheckSubvolume_IsSubvolume(t *testing.T) {
	dir := t.TempDir()
	stubBin := t.TempDir()
	writeBin(t, stubBin, "btrfs", "echo 'Name: lfs'\nexit 0\n")
	t.Setenv("PATH", stubBin)

	result := CheckSubvolume(dir)
	if result.State != StateSubvolume {
		t.Errorf("expected StateSubvolume, got %s", result.State)
	}
	if !result.Ready() {
		t.Error("Ready() should return true for StateSubvolume")
	}
}

func TestSubvolumeResult_Ready(t *testing.T) {
	cases := []struct {
		state SubvolumeState
		ready bool
	}{
		{StateSubvolume, true},
		{StatePlainDir, false},
		{StateNotExist, false},
		{StateUnknown, false},
	}
	for _, c := range cases {
		r := SubvolumeResult{State: c.state}
		if r.Ready() != c.ready {
			t.Errorf("state %s: Ready()=%v, want %v", c.state, r.Ready(), c.ready)
		}
	}
}

func TestSubvolumeState_String(t *testing.T) {
	cases := []struct {
		state SubvolumeState
		want  string
	}{
		{StateSubvolume, "subvolume"},
		{StatePlainDir, "plain directory"},
		{StateNotExist, "does not exist"},
		{StateUnknown, "unknown"},
	}
	for _, c := range cases {
		if got := c.state.String(); got != c.want {
			t.Errorf("state %d: String()=%q, want %q", c.state, got, c.want)
		}
	}
}

// --- ConvertToSubvolume ---

func TestConvertToSubvolume_AlreadySubvolume(t *testing.T) {
	dir := t.TempDir()
	stubBin := t.TempDir()
	writeBin(t, stubBin, "btrfs", "exit 0\n")
	t.Setenv("PATH", stubBin)

	err := ConvertToSubvolume(dir)
	if err == nil {
		t.Fatal("expected error when path is already a subvolume, got nil")
	}
	if !strings.Contains(err.Error(), "already a BTRFS subvolume") {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestConvertToSubvolume_BtrfsAbsent(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PATH", t.TempDir())

	err := ConvertToSubvolume(dir)
	if err == nil {
		t.Fatal("expected error when btrfs absent, got nil")
	}
}

func TestConvertToSubvolume_NotExist_Creates(t *testing.T) {
	base := t.TempDir()
	target := filepath.Join(base, "lfs-store")
	rec := filepath.Join(t.TempDir(), "calls.txt")

	stubBin := t.TempDir()
	writeBin(t, stubBin, "btrfs", `printf '%s\n' "$@" >> `+rec+`
if [ "$1" = "subvolume" ] && [ "$2" = "create" ]; then
  mkdir -p "$3"
fi
exit 0
`)
	t.Setenv("PATH", stubBin)

	if err := ConvertToSubvolume(target); err != nil {
		t.Fatalf("ConvertToSubvolume on non-existent path: %v", err)
	}

	data, _ := os.ReadFile(rec)
	args := string(data)
	if !strings.Contains(args, "subvolume") || !strings.Contains(args, "create") {
		t.Errorf("expected btrfs subvolume create to be called, got: %q", args)
	}
	if !strings.Contains(args, target) {
		t.Errorf("expected target path in btrfs args, got: %q", args)
	}
}

func TestConvertToSubvolume_PlainDir_CopiesContents(t *testing.T) {
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "object1.bin"), []byte("lfs-data-1"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(src, "ab", "cd"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "ab", "cd", "object2.bin"), []byte("lfs-data-2"), 0644); err != nil {
		t.Fatal(err)
	}

	stubBin := t.TempDir()
	// Ensure rsync and cp are absent so we exercise the pure-Go path.
	writeBin(t, stubBin, "btrfs", `if [ "$1" = "subvolume" ] && [ "$2" = "show" ]; then
  exit 1
fi
if [ "$1" = "subvolume" ] && [ "$2" = "create" ]; then
  mkdir -p "$3"
  exit 0
fi
exit 0
`)
	t.Setenv("PATH", stubBin) // no rsync, no cp

	if err := ConvertToSubvolume(src); err != nil {
		t.Fatalf("ConvertToSubvolume: %v", err)
	}

	for _, rel := range []string{"object1.bin", filepath.Join("ab", "cd", "object2.bin")} {
		data, err := os.ReadFile(filepath.Join(src, rel))
		if err != nil {
			t.Errorf("expected %s to exist after conversion: %v", rel, err)
			continue
		}
		if !strings.Contains(string(data), "lfs-data") {
			t.Errorf("file %s has unexpected content: %q", rel, data)
		}
	}

	backup := src + ".bak"
	if _, err := os.Stat(backup); !os.IsNotExist(err) {
		t.Errorf("backup directory %s should have been removed after successful conversion", backup)
	}
}

func TestConvertToSubvolume_PlainDir_CreateFails_BackupPreserved(t *testing.T) {
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "important.bin"), []byte("do-not-lose"), 0644); err != nil {
		t.Fatal(err)
	}

	stubBin := t.TempDir()
	writeBin(t, stubBin, "btrfs", `if [ "$1" = "subvolume" ] && [ "$2" = "show" ]; then
  exit 1
fi
if [ "$1" = "subvolume" ] && [ "$2" = "create" ]; then
  exit 1
fi
exit 0
`)
	t.Setenv("PATH", stubBin)

	err := ConvertToSubvolume(src)
	if err == nil {
		t.Fatal("expected error when btrfs subvolume create fails, got nil")
	}

	backup := src + ".bak"
	data, readErr := os.ReadFile(filepath.Join(backup, "important.bin"))
	if readErr != nil {
		t.Fatalf("backup not preserved after failed create: %v", readErr)
	}
	if string(data) != "do-not-lose" {
		t.Errorf("backup data corrupted: %q", data)
	}
}

// --- checkDiskSpace ---

func TestCheckDiskSpace_SufficientSpace(t *testing.T) {
	// A temp dir on a real filesystem will always have more free space than
	// the tiny files we write, so this should always pass.
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "small.bin"), []byte("x"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := checkDiskSpace(dir); err != nil {
		t.Errorf("checkDiskSpace on small dir returned unexpected error: %v", err)
	}
}

func TestCheckDiskSpace_NonExistentPath(t *testing.T) {
	// Non-existent path — dirSize will fail, function should return nil (non-fatal).
	err := checkDiskSpace("/nonexistent/path/xyz")
	if err != nil {
		t.Errorf("checkDiskSpace on non-existent path should return nil, got: %v", err)
	}
}

// --- formatBytes ---

func TestFormatBytes(t *testing.T) {
	cases := []struct {
		input uint64
		want  string
	}{
		{0, "0 B"},
		{512, "512 B"},
		{1023, "1023 B"},
		{1024, "1.0 KiB"},
		{1536, "1.5 KiB"},
		{1024 * 1024, "1.0 MiB"},
		{1024 * 1024 * 1024, "1.0 GiB"},
		{uint64(2.5 * float64(1<<30)), "2.5 GiB"},
	}
	for _, c := range cases {
		got := formatBytes(c.input)
		if got != c.want {
			t.Errorf("formatBytes(%d) = %q, want %q", c.input, got, c.want)
		}
	}
}

// --- cpSupportsArchive ---

func TestCpSupportsArchive_Supported(t *testing.T) {
	// Stub cp that prints --archive in its help output.
	stubBin := t.TempDir()
	writeBin(t, stubBin, "cp", `echo "Usage: cp [--archive] ..."
exit 0
`)
	cp := filepath.Join(stubBin, "cp")
	if !cpSupportsArchive(cp) {
		t.Error("expected cpSupportsArchive=true when --archive in help output")
	}
}

func TestCpSupportsArchive_NotSupported(t *testing.T) {
	// Stub cp that does not mention --archive (macOS-style).
	stubBin := t.TempDir()
	writeBin(t, stubBin, "cp", `echo "usage: cp [-R] source target"
exit 0
`)
	cp := filepath.Join(stubBin, "cp")
	if cpSupportsArchive(cp) {
		t.Error("expected cpSupportsArchive=false when --archive absent from help output")
	}
}

// --- copyContents backend selection ---

func TestCopyContents_PrefersRsync(t *testing.T) {
	src := t.TempDir()
	dst := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "file.bin"), []byte("data"), 0644); err != nil {
		t.Fatal(err)
	}

	rec := filepath.Join(t.TempDir(), "calls.txt")
	stubBin := t.TempDir()
	// rsync stub: record invocation, copy files manually so the test can verify.
	writeBin(t, stubBin, "rsync", `printf 'rsync %s\n' "$@" >> `+rec+`
# Minimal copy so dst is populated
cp -r "$1"* "$2" 2>/dev/null || true
exit 0
`)
	// cp stub also present — rsync should be preferred.
	writeBin(t, stubBin, "cp", `printf 'cp %s\n' "$@" >> `+rec+`
exit 0
`)
	t.Setenv("PATH", stubBin)

	if err := copyContents(src, dst); err != nil {
		t.Fatalf("copyContents: %v", err)
	}

	data, _ := os.ReadFile(rec)
	if !strings.HasPrefix(string(data), "rsync") {
		t.Errorf("expected rsync to be called first, got: %q", string(data))
	}
}

func TestCopyContents_FallsBackToCp(t *testing.T) {
	src := t.TempDir()
	dst := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "file.bin"), []byte("data"), 0644); err != nil {
		t.Fatal(err)
	}

	rec := filepath.Join(t.TempDir(), "calls.txt")
	stubBin := t.TempDir()
	// No rsync; cp supports --archive.
	writeBin(t, stubBin, "cp", `printf 'cp %s\n' "$@" >> `+rec+`
if [ "$1" = "--help" ]; then
  echo "--archive"
  exit 0
fi
exit 0
`)
	t.Setenv("PATH", stubBin)

	if err := copyContents(src, dst); err != nil {
		t.Fatalf("copyContents: %v", err)
	}

	data, _ := os.ReadFile(rec)
	if !strings.Contains(string(data), "--archive") {
		t.Errorf("expected cp --archive to be called, got: %q", string(data))
	}
}

func TestCopyContents_FallsBackToPureGo(t *testing.T) {
	src := t.TempDir()
	dst := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "file.bin"), []byte("hello"), 0644); err != nil {
		t.Fatal(err)
	}

	// No rsync, no cp — pure-Go path.
	t.Setenv("PATH", t.TempDir())

	if err := copyContents(src, dst); err != nil {
		t.Fatalf("copyContents pure-Go fallback: %v", err)
	}

	data, err := os.ReadFile(filepath.Join(dst, "file.bin"))
	if err != nil {
		t.Fatalf("file not copied: %v", err)
	}
	if string(data) != "hello" {
		t.Errorf("unexpected file content: %q", data)
	}
}

// --- copyDir / copyFile ---

func TestCopyDir_PreservesNestedStructure(t *testing.T) {
	src := t.TempDir()
	dst := t.TempDir()

	if err := os.MkdirAll(filepath.Join(src, "a", "b"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "a", "b", "file.txt"), []byte("hello"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "root.txt"), []byte("root"), 0644); err != nil {
		t.Fatal(err)
	}

	if err := copyDir(src, dst); err != nil {
		t.Fatalf("copyDir: %v", err)
	}

	for _, rel := range []string{filepath.Join("a", "b", "file.txt"), "root.txt"} {
		if _, err := os.Stat(filepath.Join(dst, rel)); err != nil {
			t.Errorf("expected %s in dst: %v", rel, err)
		}
	}
}

func TestCopyDir_PreservesSymlinks(t *testing.T) {
	src := t.TempDir()
	dst := t.TempDir()

	target := filepath.Join(src, "real.txt")
	if err := os.WriteFile(target, []byte("data"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(src, "link.txt")); err != nil {
		t.Skip("symlinks not supported on this platform")
	}

	if err := copyDir(src, dst); err != nil {
		t.Fatalf("copyDir: %v", err)
	}

	fi, err := os.Lstat(filepath.Join(dst, "link.txt"))
	if err != nil {
		t.Fatalf("link not copied: %v", err)
	}
	if fi.Mode()&os.ModeSymlink == 0 {
		t.Error("expected symlink in dst, got regular file")
	}
}
