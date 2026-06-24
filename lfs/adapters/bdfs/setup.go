package bdfs

// setup.go — BTRFS subvolume prerequisite check and conversion for the LFS
// object store.
//
// lfs.path must be a BTRFS subvolume (not a plain directory) for Snapshot and
// Prune to have any effect. This file provides:
//
//   - SubvolumeStatus  — inspect whether a path is already a subvolume.
//   - CheckSubvolume   — return a structured result an operator can act on.
//   - ConvertToSubvolume — disk-space-checked, xattr-aware copy-out / create /
//     copy-back conversion.
//
// Copy backend preference (highest to lowest):
//
//  1. rsync -aX   — preserves xattrs, ACLs, hard links, sparse files
//  2. cp --archive — preserves xattrs on GNU coreutils; not available on macOS
//  3. pure-Go copyDir — portable fallback; does NOT preserve xattrs or ACLs

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

// diskSpaceHeadroom is the multiplier applied to the current store size when
// checking free space before conversion. 1.1 provides 10% headroom for
// filesystem metadata and the brief period where both path.bak and the new
// subvolume coexist on the same filesystem.
const diskSpaceHeadroom = 1.1

// SubvolumeState describes the BTRFS subvolume state of a path.
type SubvolumeState int

const (
	// StateSubvolume means the path is already a BTRFS subvolume.
	StateSubvolume SubvolumeState = iota
	// StatePlainDir means the path exists but is a plain directory.
	StatePlainDir
	// StateNotExist means the path does not exist yet.
	StateNotExist
	// StateUnknown means btrfs-progs is not installed or the check failed.
	StateUnknown
)

func (s SubvolumeState) String() string {
	switch s {
	case StateSubvolume:
		return "subvolume"
	case StatePlainDir:
		return "plain directory"
	case StateNotExist:
		return "does not exist"
	default:
		return "unknown"
	}
}

// SubvolumeResult is returned by CheckSubvolume.
type SubvolumeResult struct {
	Path  string
	State SubvolumeState
	// Detail holds the raw output of `btrfs subvolume show` or the error
	// message when State is StateUnknown.
	Detail string
}

// Ready reports whether the path is already a BTRFS subvolume and no action
// is needed.
func (r SubvolumeResult) Ready() bool { return r.State == StateSubvolume }

// CheckSubvolume inspects path and returns its SubvolumeResult.
// It never returns an error — problems are encoded in SubvolumeResult.State.
func CheckSubvolume(path string) SubvolumeResult {
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return SubvolumeResult{Path: path, State: StateNotExist}
	}

	btrfs, err := exec.LookPath("btrfs")
	if err != nil {
		return SubvolumeResult{
			Path:   path,
			State:  StateUnknown,
			Detail: "btrfs-progs not found in PATH — cannot determine subvolume status",
		}
	}

	out, err := exec.Command(btrfs, "subvolume", "show", path).CombinedOutput()
	detail := strings.TrimSpace(string(out))
	if err != nil {
		// `btrfs subvolume show` exits non-zero for plain directories.
		return SubvolumeResult{Path: path, State: StatePlainDir, Detail: detail}
	}
	return SubvolumeResult{Path: path, State: StateSubvolume, Detail: detail}
}

// ConvertToSubvolume converts a plain directory at path into a BTRFS subvolume
// in-place using a copy-out / create / copy-back strategy:
//
//  1. Pre-flight: verify sufficient free space on the filesystem.
//  2. Rename path → path.bak  (atomic on same filesystem).
//  3. btrfs subvolume create path.
//  4. Copy all contents from path.bak into path (rsync > cp > pure-Go).
//  5. Remove path.bak.
//
// The backup directory (path.bak) is left in place if any step after (2)
// fails, so the original data is always recoverable.
//
// Returns an error if:
//   - path is already a subvolume (caller should check first)
//   - btrfs-progs is not installed
//   - insufficient free space
//   - any filesystem operation fails
func ConvertToSubvolume(path string) error {
	result := CheckSubvolume(path)
	switch result.State {
	case StateSubvolume:
		return fmt.Errorf("%s is already a BTRFS subvolume", path)
	case StateUnknown:
		return fmt.Errorf("cannot convert %s: %s", path, result.Detail)
	case StateNotExist:
		return createSubvolume(path)
	}

	// StatePlainDir — perform the copy-out / create / copy-back.
	btrfs, err := exec.LookPath("btrfs")
	if err != nil {
		return fmt.Errorf("btrfs-progs not found in PATH")
	}

	// Step 1: pre-flight disk space check.
	if err := checkDiskSpace(path); err != nil {
		return err
	}

	backup := path + ".bak"

	// Step 2: rename the existing directory to a backup location.
	if err := os.Rename(path, backup); err != nil {
		return fmt.Errorf("rename %s → %s: %w", path, backup, err)
	}

	// Steps 3-5 run with the backup in place. On any failure we return the
	// error; the backup remains so the operator can recover manually.

	// Step 3: create the subvolume at the original path.
	if out, err := exec.Command(btrfs, "subvolume", "create", path).CombinedOutput(); err != nil {
		return fmt.Errorf("btrfs subvolume create %s: %w\n%s",
			path, err, strings.TrimSpace(string(out)))
	}

	// Step 4: copy contents from backup into the new subvolume.
	if err := copyContents(backup, path); err != nil {
		return fmt.Errorf("copy %s → %s: %w", backup, path, err)
	}

	// Step 5: remove the backup directory.
	if err := os.RemoveAll(backup); err != nil {
		// Non-fatal: the subvolume is ready; the backup is just leftover.
		return fmt.Errorf("subvolume created successfully but could not remove backup %s: %w", backup, err)
	}

	return nil
}

// checkDiskSpace verifies that the filesystem containing path has at least as
// many free bytes as the directory currently occupies. This catches the common
// case where a large LFS store would exhaust the filesystem during copy-back.
func checkDiskSpace(path string) error {
	used, err := dirSize(path)
	if err != nil {
		// Non-fatal: if we can't measure, proceed and let the copy fail
		// naturally with a clear OS error.
		return nil
	}

	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return nil // same: proceed and let the OS report the real error
	}

	// Bavail is the blocks available to unprivileged users.
	free := stat.Bavail * uint64(stat.Bsize)

	required := uint64(float64(used) * diskSpaceHeadroom)
	if free < required {
		return fmt.Errorf(
			"insufficient disk space for conversion: need ~%s free, have %s (path: %s)",
			formatBytes(required), formatBytes(free), path,
		)
	}
	return nil
}

// dirSize returns the total size in bytes of all regular files under path.
func dirSize(path string) (int64, error) {
	var total int64
	err := filepath.Walk(path, func(_ string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() {
			total += info.Size()
		}
		return nil
	})
	return total, err
}

// formatBytes formats a byte count as a human-readable string (GiB/MiB/KiB/B).
func formatBytes(b uint64) string {
	switch {
	case b >= 1<<30:
		return fmt.Sprintf("%.1f GiB", float64(b)/(1<<30))
	case b >= 1<<20:
		return fmt.Sprintf("%.1f MiB", float64(b)/(1<<20))
	case b >= 1<<10:
		return fmt.Sprintf("%.1f KiB", float64(b)/(1<<10))
	default:
		return fmt.Sprintf("%d B", b)
	}
}

// copyContents copies the contents of src into dst using the best available
// tool: rsync (preserves xattrs/ACLs) > cp --archive (GNU, preserves xattrs)
// > pure-Go copyDir (portable, no xattr support).
func copyContents(src, dst string) error {
	if rsync, err := exec.LookPath("rsync"); err == nil {
		return copyWithRsync(rsync, src, dst)
	}
	if cp, err := exec.LookPath("cp"); err == nil {
		if cpSupportsArchive(cp) {
			return copyWithCp(cp, src, dst)
		}
	}
	return copyDir(src, dst)
}

// copyWithRsync runs: rsync -aX src/ dst/
// -a  = archive (preserves permissions, timestamps, symlinks, hard links)
// -X  = preserve extended attributes (xattrs, ACLs)
func copyWithRsync(rsync, src, dst string) error {
	// Trailing slash on src tells rsync to copy the *contents* of src, not
	// src itself, so files land directly in dst.
	out, err := exec.Command(rsync,
		"-aX",
		"--no-whole-file",
		src+"/",
		dst+"/",
	).CombinedOutput()
	if err != nil {
		return fmt.Errorf("rsync: %w\n%s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// cpSupportsArchive probes whether the cp binary accepts --archive by running
// `cp --help` and checking for the flag in the output. GNU coreutils cp
// supports --archive; macOS cp does not.
//
// The error from `cp --help` is intentionally discarded: some implementations
// (including older GNU coreutils) exit non-zero for --help even when they
// print valid output. CombinedOutput captures both stdout and stderr, so the
// probe is reliable regardless of which stream the help text is written to.
func cpSupportsArchive(cp string) bool {
	out, _ := exec.Command(cp, "--help").CombinedOutput()
	return strings.Contains(string(out), "--archive")
}

// copyWithCp runs: cp --archive src/. dst/
// --archive = equivalent to -dR --preserve=all (GNU coreutils)
func copyWithCp(cp, src, dst string) error {
	// src/. copies the contents of src into dst without creating a src
	// subdirectory inside dst.
	out, err := exec.Command(cp, "--archive", src+"/.", dst).CombinedOutput()
	if err != nil {
		return fmt.Errorf("cp --archive: %w\n%s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// createSubvolume runs `btrfs subvolume create path` for a path that does not
// yet exist.
func createSubvolume(path string) error {
	btrfs, err := exec.LookPath("btrfs")
	if err != nil {
		return fmt.Errorf("btrfs-progs not found in PATH")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return fmt.Errorf("create parent of %s: %w", path, err)
	}
	out, err := exec.Command(btrfs, "subvolume", "create", path).CombinedOutput()
	if err != nil {
		return fmt.Errorf("btrfs subvolume create %s: %w\n%s",
			path, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// copyDir recursively copies the contents of src into dst using pure Go.
// dst must already exist. Symlinks are copied as symlinks.
// File permissions are preserved. Extended attributes and ACLs are NOT
// preserved — use copyWithRsync or copyWithCp when xattr fidelity is required.
func copyDir(src, dst string) error {
	return filepath.Walk(src, func(srcPath string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, srcPath)
		if err != nil {
			return err
		}
		dstPath := filepath.Join(dst, rel)

		switch {
		case info.Mode()&os.ModeSymlink != 0:
			target, err := os.Readlink(srcPath)
			if err != nil {
				return err
			}
			return os.Symlink(target, dstPath)
		case info.IsDir():
			if srcPath == src {
				return nil // dst itself already exists
			}
			return os.MkdirAll(dstPath, info.Mode())
		default:
			return copyFile(srcPath, dstPath, info.Mode())
		}
	})
}

// copyFile copies a single regular file from src to dst, preserving mode.
func copyFile(src, dst string, mode os.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	defer out.Close()

	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return out.Close()
}
