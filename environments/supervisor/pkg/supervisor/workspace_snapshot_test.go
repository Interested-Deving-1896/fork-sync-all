// Copyright (c) 2020 Gitpod GmbH. All rights reserved.
// Licensed under the GNU Affero General Public License (AGPL).
// See License.AGPL.txt in the project root for license information.
package supervisor

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// stubBin writes a shell script stub to dir/name and makes it executable.
// The script exits with exitCode and writes args to a sidecar file so tests
// can assert what arguments were passed.
func stubBin(t *testing.T, dir, name string, exitCode int) {
	t.Helper()
	argsFile := filepath.Join(dir, name+".args")
	script := "#!/bin/sh\n" +
		"echo \"$@\" > " + argsFile + "\n" +
		"exit " + itoa(exitCode) + "\n"
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("stubBin %s: %v", name, err)
	}
}

// readArgs reads the args file written by a stub binary.
func readArgs(t *testing.T, dir, name string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, name+".args"))
	if err != nil {
		t.Fatalf("readArgs %s: %v", name, err)
	}
	return strings.TrimSpace(string(data))
}

// argsFileExists reports whether the stub was invoked.
func argsFileExists(dir, name string) bool {
	_, err := os.Stat(filepath.Join(dir, name+".args"))
	return err == nil
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	s := ""
	neg := n < 0
	if neg {
		n = -n
	}
	for n > 0 {
		s = string(rune('0'+n%10)) + s
		n /= 10
	}
	if neg {
		s = "-" + s
	}
	return s
}

// minimalConfig returns a Config with only the workspace path set.
func minimalConfig(workspacePath string) *Config {
	return &Config{WorkspaceLocation: workspacePath}
}

// --- NewWorkspaceSnapshotter ---

func TestNewWorkspaceSnapshotter_AllDisabled(t *testing.T) {
	cfg := minimalConfig("/workspace")
	ws, err := NewWorkspaceSnapshotter(cfg)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ws != nil {
		t.Fatal("expected nil snapshotter when all features disabled")
	}
}

func TestNewWorkspaceSnapshotter_SnapshotOnly(t *testing.T) {
	cfg := minimalConfig("/workspace")
	cfg.BdfsSnapshotOnPause = true
	ws, err := NewWorkspaceSnapshotter(cfg)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ws == nil {
		t.Fatal("expected non-nil snapshotter")
	}
	if ws.compression != "zstd" {
		t.Errorf("default compression: got %q, want %q", ws.compression, "zstd")
	}
}

func TestNewWorkspaceSnapshotter_CustomCompression(t *testing.T) {
	cfg := minimalConfig("/workspace")
	cfg.BdfsDemoteOnDelete = true
	cfg.BdfsCompression = "lzma"
	ws, err := NewWorkspaceSnapshotter(cfg)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ws.compression != "lzma" {
		t.Errorf("compression: got %q, want %q", ws.compression, "lzma")
	}
}

func TestNewWorkspaceSnapshotter_PruneOnly(t *testing.T) {
	cfg := minimalConfig("/workspace")
	cfg.BdfsPruneKeep = 5
	ws, err := NewWorkspaceSnapshotter(cfg)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ws == nil {
		t.Fatal("expected non-nil snapshotter when pruneKeep > 0")
	}
	if ws.pruneKeep != 5 {
		t.Errorf("pruneKeep: got %d, want 5", ws.pruneKeep)
	}
}

// --- Snapshot ---

func TestSnapshot_NilSnapshotter(t *testing.T) {
	var ws *WorkspaceSnapshotter
	if err := ws.Snapshot(context.Background()); err != nil {
		t.Fatalf("nil snapshotter Snapshot should be no-op, got: %v", err)
	}
}

func TestSnapshot_DisabledFlag(t *testing.T) {
	dir := t.TempDir()
	stubBin(t, dir, "bfg", 0)
	t.Setenv("PATH", dir)

	ws := &WorkspaceSnapshotter{
		workspacePath:   dir,
		snapshotOnPause: false,
	}
	if err := ws.Snapshot(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if argsFileExists(dir, "bfg") {
		t.Error("bfg should not be called when snapshotOnPause=false")
	}
}

func TestSnapshot_BfgNotInPath(t *testing.T) {
	t.Setenv("PATH", t.TempDir()) // empty dir — no bfg

	ws := &WorkspaceSnapshotter{
		workspacePath:   "/workspace",
		snapshotOnPause: true,
	}
	// Should return nil (graceful no-op), not an error.
	if err := ws.Snapshot(context.Background()); err != nil {
		t.Fatalf("missing bfg should be a no-op, got: %v", err)
	}
}

func TestSnapshot_Success(t *testing.T) {
	dir := t.TempDir()
	stubBin(t, dir, "bfg", 0)
	t.Setenv("PATH", dir)

	ws := &WorkspaceSnapshotter{
		workspacePath:   "/workspace/myws",
		snapshotOnPause: true,
	}
	if err := ws.Snapshot(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	args := readArgs(t, dir, "bfg")
	if !strings.Contains(args, "local_commit") {
		t.Errorf("expected bfg local_commit in args, got: %q", args)
	}
	if !strings.Contains(args, "--SUBVOLUME=/workspace/myws") {
		t.Errorf("expected --SUBVOLUME in args, got: %q", args)
	}
}

func TestSnapshot_BfgFailure(t *testing.T) {
	dir := t.TempDir()
	stubBin(t, dir, "bfg", 1) // exit 1 = failure
	t.Setenv("PATH", dir)

	ws := &WorkspaceSnapshotter{
		workspacePath:   "/workspace/myws",
		snapshotOnPause: true,
	}
	err := ws.Snapshot(context.Background())
	if err == nil {
		t.Fatal("expected error when bfg exits non-zero")
	}
	if !strings.Contains(err.Error(), "bfg local_commit") {
		t.Errorf("error should mention bfg local_commit, got: %v", err)
	}
}

func TestSnapshot_PruneCalledAfterSuccess(t *testing.T) {
	dir := t.TempDir()
	stubBin(t, dir, "bfg", 0)
	stubBin(t, dir, "bdfs", 0)
	t.Setenv("PATH", dir)

	ws := &WorkspaceSnapshotter{
		workspacePath:   "/workspace/myws",
		snapshotOnPause: true,
		pruneKeep:       3,
		compression:     "zstd",
	}
	if err := ws.Snapshot(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !argsFileExists(dir, "bdfs") {
		t.Error("expected bdfs prune to be called after successful snapshot")
	}
	args := readArgs(t, dir, "bdfs")
	if !strings.Contains(args, "snapshot") || !strings.Contains(args, "prune") {
		t.Errorf("expected bdfs snapshot prune in args, got: %q", args)
	}
	if !strings.Contains(args, "--keep") {
		t.Errorf("expected --keep in prune args, got: %q", args)
	}
}

func TestSnapshot_PruneNotCalledWhenKeepZero(t *testing.T) {
	dir := t.TempDir()
	stubBin(t, dir, "bfg", 0)
	stubBin(t, dir, "bdfs", 0)
	t.Setenv("PATH", dir)

	ws := &WorkspaceSnapshotter{
		workspacePath:   "/workspace/myws",
		snapshotOnPause: true,
		pruneKeep:       0, // disabled
	}
	if err := ws.Snapshot(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if argsFileExists(dir, "bdfs") {
		t.Error("bdfs should not be called when pruneKeep=0")
	}
}

// --- Demote ---

func TestDemote_NilSnapshotter(t *testing.T) {
	var ws *WorkspaceSnapshotter
	if err := ws.Demote(context.Background()); err != nil {
		t.Fatalf("nil snapshotter Demote should be no-op, got: %v", err)
	}
}

func TestDemote_DisabledFlag(t *testing.T) {
	dir := t.TempDir()
	stubBin(t, dir, "bdfs", 0)
	t.Setenv("PATH", dir)

	ws := &WorkspaceSnapshotter{
		workspacePath:  dir,
		demoteOnDelete: false,
	}
	if err := ws.Demote(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if argsFileExists(dir, "bdfs") {
		t.Error("bdfs should not be called when demoteOnDelete=false")
	}
}

func TestDemote_BdfsNotInPath(t *testing.T) {
	t.Setenv("PATH", t.TempDir())

	ws := &WorkspaceSnapshotter{
		workspacePath:  "/workspace",
		demoteOnDelete: true,
	}
	if err := ws.Demote(context.Background()); err != nil {
		t.Fatalf("missing bdfs should be a no-op, got: %v", err)
	}
}

func TestDemote_Success(t *testing.T) {
	dir := t.TempDir()
	stubBin(t, dir, "bdfs", 0)
	t.Setenv("PATH", dir)

	ws := &WorkspaceSnapshotter{
		workspacePath:  "/workspace/myws",
		demoteOnDelete: true,
		compression:    "zstd",
	}
	if err := ws.Demote(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	args := readArgs(t, dir, "bdfs")
	if !strings.Contains(args, "demote") {
		t.Errorf("expected bdfs demote in args, got: %q", args)
	}
	if !strings.Contains(args, "--blend-path") {
		t.Errorf("expected --blend-path in args, got: %q", args)
	}
	if !strings.Contains(args, "--image-name") {
		t.Errorf("expected --image-name in args, got: %q", args)
	}
	if !strings.Contains(args, "--compression") {
		t.Errorf("expected --compression in args, got: %q", args)
	}
	if !strings.Contains(args, "zstd") {
		t.Errorf("expected compression algorithm in args, got: %q", args)
	}
}

func TestDemote_ImageNameDerivedFromWorkspacePath(t *testing.T) {
	dir := t.TempDir()
	stubBin(t, dir, "bdfs", 0)
	t.Setenv("PATH", dir)

	ws := &WorkspaceSnapshotter{
		workspacePath:  "/workspace/myws",
		demoteOnDelete: true,
		compression:    "zstd",
	}
	if err := ws.Demote(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	args := readArgs(t, dir, "bdfs")
	if !strings.Contains(args, "/workspace/myws.dwarfs") {
		t.Errorf("expected image name /workspace/myws.dwarfs in args, got: %q", args)
	}
}

func TestDemote_BdfsFailure(t *testing.T) {
	dir := t.TempDir()
	stubBin(t, dir, "bdfs", 1)
	t.Setenv("PATH", dir)

	ws := &WorkspaceSnapshotter{
		workspacePath:  "/workspace/myws",
		demoteOnDelete: true,
		compression:    "zstd",
	}
	err := ws.Demote(context.Background())
	if err == nil {
		t.Fatal("expected error when bdfs exits non-zero")
	}
	if !strings.Contains(err.Error(), "bdfs demote") {
		t.Errorf("error should mention bdfs demote, got: %v", err)
	}
}

// --- Close ---

func TestClose_NilSnapshotter(t *testing.T) {
	var ws *WorkspaceSnapshotter
	if err := ws.Close(); err != nil {
		t.Fatalf("nil snapshotter Close should be no-op, got: %v", err)
	}
}

func TestClose_NilPinner(t *testing.T) {
	ws := &WorkspaceSnapshotter{pinner: nil}
	if err := ws.Close(); err != nil {
		t.Fatalf("Close with nil pinner should be no-op, got: %v", err)
	}
}
