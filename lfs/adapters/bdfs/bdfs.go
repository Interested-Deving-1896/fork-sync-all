// Package bdfs provides storage lifecycle management for the GitLab-Enhanced
// LFS object store, backed by btr-fs-git (BFG) and btrfs-dwarfs-framework.
//
// It does not replace the LFS server. It manages the BTRFS subvolume that the
// server's StoragePath lives on: snapshotting before serve, pruning after, and
// demoting cold snapshots to compressed DwarFS images on demand.
//
// All operations are no-ops when the required binary (bfg or bdfs) is absent,
// so the LFS server works normally on hosts without these tools installed.
package bdfs

import (
	"context"
	"fmt"
	"log"
	"os/exec"
	"strings"
	"time"

	dwarfspin "gitlab.com/openos-project/git-management_deving/gitlab-enhanced/ipfs/dwarfs-pin"
)

// Config holds the bdfs adapter configuration, populated from LFSConfig.
type Config struct {
	// StoragePath is the LFS object store root (cfg.LFS.Path).
	// Must be a BTRFS subvolume for Snapshot and Prune to have effect.
	StoragePath string

	// SnapshotOnServe controls whether Snapshot() is called before the LFS
	// server starts. When false, Snapshot() is a no-op regardless of whether
	// bfg is installed.
	SnapshotOnServe bool

	// PruneKeep is the number of snapshots to retain after lfs serve exits.
	// 0 disables post-serve pruning.
	PruneKeep int

	// PrunePattern is passed to bdfs snapshot prune --pattern.
	// Empty string matches all snapshots under StoragePath.
	PrunePattern string

	// Compression is the algorithm passed to bdfs demote and bdfs snapshot
	// prune --demote-first. Valid values: zstd | lzma | lz4 | brotli | none.
	// Defaults to "zstd" when empty.
	Compression string

	// Pinner, when non-nil, is called after a successful Demote() to pin the
	// resulting .dwarfs archive to IPFS. A nil Pinner skips pinning silently.
	Pinner *dwarfspin.Pinner
}

// StorageLifecycle manages the BTRFS subvolume backing the LFS object store.
type StorageLifecycle struct {
	cfg Config
}

// New constructs a StorageLifecycle from cfg. It does not validate that the
// required binaries are installed or that StoragePath is a BTRFS subvolume —
// those checks happen lazily at call time so construction never fails.
func New(cfg Config) *StorageLifecycle {
	if cfg.Compression == "" {
		cfg.Compression = "zstd"
	}
	return &StorageLifecycle{cfg: cfg}
}

// Snapshot creates a local btr-fs-git commit of the LFS store subvolume.
// Equivalent to: bfg local_commit --SUBVOLUME=<StoragePath>
//
// Returns nil when bfg is absent or SnapshotOnServe is false.
// A non-nil error means bfg ran but exited non-zero; callers should log and
// continue — the LFS server must not be blocked by a snapshot failure.
func (s *StorageLifecycle) Snapshot() error {
	if !s.cfg.SnapshotOnServe {
		return nil
	}
	bfg, err := exec.LookPath("bfg")
	if err != nil {
		log.Printf("[lfs/bdfs] bfg not found, skipping pre-serve snapshot")
		return nil
	}
	log.Printf("[lfs/bdfs] snapshotting LFS store at %s", s.cfg.StoragePath)
	out, err := exec.Command(bfg,
		"--YES=true",
		"local_commit",
		"--SUBVOLUME="+s.cfg.StoragePath,
	).CombinedOutput()
	if err != nil {
		return fmt.Errorf("bfg local_commit %s: %w\n%s",
			s.cfg.StoragePath, err, strings.TrimSpace(string(out)))
	}
	log.Printf("[lfs/bdfs] snapshot complete")
	return nil
}

// Demote compresses the LFS store subvolume to a DwarFS image alongside it.
// The image is written to <StoragePath>.dwarfs.
//
// When cfg.Pinner is non-nil, the resulting archive is pinned to IPFS after a
// successful demote. A failed pin is logged but does not cause Demote to
// return an error — the archive is still available locally.
//
// Returns nil when bdfs is absent.
func (s *StorageLifecycle) Demote() error {
	bdfs, err := exec.LookPath("bdfs")
	if err != nil {
		log.Printf("[lfs/bdfs] bdfs not found, skipping demote")
		return nil
	}
	imageName := s.cfg.StoragePath + ".dwarfs"
	log.Printf("[lfs/bdfs] demoting LFS store %s → %s (compression: %s)",
		s.cfg.StoragePath, imageName, s.cfg.Compression)
	out, err := exec.Command(bdfs,
		"demote",
		"--blend-path", s.cfg.StoragePath,
		"--image-name", imageName,
		"--compression", s.cfg.Compression,
	).CombinedOutput()
	if err != nil {
		return fmt.Errorf("bdfs demote %s: %w\n%s",
			s.cfg.StoragePath, err, strings.TrimSpace(string(out)))
	}
	log.Printf("[lfs/bdfs] demote complete → %s", imageName)

	// Pin the archive to IPFS when configured. Non-fatal on failure.
	if s.cfg.Pinner != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
		defer cancel()
		result, pinErr := s.cfg.Pinner.Pin(ctx, imageName)
		if pinErr != nil {
			log.Printf("[lfs/bdfs] ipfs pin failed for %s: %v", imageName, pinErr)
		} else if !result.Cached {
			log.Printf("[lfs/bdfs] ipfs pinned %s → %s", imageName, result.CID)
		}
	}

	return nil
}

// Prune removes old snapshots of the LFS store, keeping the most recent
// PruneKeep. Snapshots beyond the keep count are archived as DwarFS images
// before deletion (--demote-first).
//
// Returns nil when bdfs is absent or PruneKeep is 0.
func (s *StorageLifecycle) Prune() error {
	if s.cfg.PruneKeep == 0 {
		return nil
	}
	bdfs, err := exec.LookPath("bdfs")
	if err != nil {
		log.Printf("[lfs/bdfs] bdfs not found, skipping prune")
		return nil
	}
	args := []string{
		"snapshot", "prune",
		"--btrfs-mount", s.cfg.StoragePath,
		"--keep", fmt.Sprintf("%d", s.cfg.PruneKeep),
		"--demote-first",
		"--compression", s.cfg.Compression,
	}
	if s.cfg.PrunePattern != "" {
		args = append(args, "--pattern", s.cfg.PrunePattern)
	}
	log.Printf("[lfs/bdfs] pruning LFS snapshots at %s (keep=%d)",
		s.cfg.StoragePath, s.cfg.PruneKeep)
	out, err := exec.Command(bdfs, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("bdfs snapshot prune %s: %w\n%s",
			s.cfg.StoragePath, err, strings.TrimSpace(string(out)))
	}
	log.Printf("[lfs/bdfs] prune complete")
	return nil
}
