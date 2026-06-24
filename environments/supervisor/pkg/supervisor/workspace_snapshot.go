// Copyright (c) 2020 Gitpod GmbH. All rights reserved.
// Licensed under the GNU Affero General Public License (AGPL).
// See License.AGPL.txt in the project root for license information.

// Package supervisor manages the workspace process lifecycle.
package supervisor

// workspace_snapshot.go — bdfs/bfg workspace snapshot lifecycle hooks.
//
// WorkspaceSnapshotter exposes two lifecycle methods called by the supervisor
// shutdown path:
//
//   - Snapshot — called when the workspace is paused (container frozen). Takes
//     a btr-fs-git snapshot of the workspace subvolume so the state at pause
//     time is recoverable.
//
//   - Demote — called when the workspace is deleted. Compresses the workspace
//     subvolume to a DwarFS archive via bdfs demote, then optionally pins the
//     archive to IPFS.
//
// All operations are no-ops when the required binary is absent, so the
// supervisor works normally on hosts without bfg or bdfs installed.

import (
	"context"
	"fmt"
	"log"
	"os/exec"
	"strings"
	"time"

	dwarfspin "gitlab.com/openos-project/git-management_deving/gitlab-enhanced/ipfs/dwarfs-pin"
)

// WorkspaceSnapshotter manages the bdfs/bfg lifecycle for a single workspace.
type WorkspaceSnapshotter struct {
	// workspacePath is the root of the workspace BTRFS subvolume.
	workspacePath string

	// snapshotOnPause controls whether Snapshot calls bfg local_commit.
	snapshotOnPause bool

	// demoteOnDelete controls whether Demote calls bdfs demote.
	demoteOnDelete bool

	// pruneKeep is the number of snapshots to retain after each Snapshot call.
	// 0 disables pruning.
	pruneKeep int

	// compression is the algorithm passed to bdfs demote --compression.
	// Defaults to "zstd".
	compression string

	// pinner, when non-nil, pins the DwarFS archive produced by Demote to IPFS.
	// A nil pinner skips pinning silently.
	pinner *dwarfspin.Pinner
}

// NewWorkspaceSnapshotter constructs a WorkspaceSnapshotter from the supervisor
// Config. Returns nil when all bdfs features are disabled, so callers can use
// a nil *WorkspaceSnapshotter without any conditional logic.
func NewWorkspaceSnapshotter(cfg *Config) (*WorkspaceSnapshotter, error) {
	if !cfg.BdfsSnapshotOnPause && !cfg.BdfsDemoteOnDelete && cfg.BdfsPruneKeep == 0 {
		return nil, nil
	}

	compression := cfg.BdfsCompression
	if compression == "" {
		compression = "zstd"
	}

	var pinner *dwarfspin.Pinner
	if cfg.DwarfsPinEnabled && cfg.DwarfsPinKuboAPI != "" {
		var err error
		pinner, err = dwarfspin.New(dwarfspin.Config{
			Enabled:     true,
			KuboAPI:     cfg.DwarfsPinKuboAPI,
			IndexPath:   cfg.DwarfsPinIndexPath,
		})
		if err != nil {
			return nil, fmt.Errorf("workspace snapshotter: init dwarfs-pin: %w", err)
		}
	}

	return &WorkspaceSnapshotter{
		workspacePath:   cfg.WorkspaceLocation,
		snapshotOnPause: cfg.BdfsSnapshotOnPause,
		demoteOnDelete:  cfg.BdfsDemoteOnDelete,
		pruneKeep:       cfg.BdfsPruneKeep,
		compression:     compression,
		pinner:          pinner,
	}, nil
}

// Close releases resources held by the snapshotter (IPFS index connection).
// Safe to call on a nil *WorkspaceSnapshotter.
func (ws *WorkspaceSnapshotter) Close() error {
	if ws == nil {
		return nil
	}
	return ws.pinner.Close()
}

// Snapshot takes a btr-fs-git snapshot of the workspace subvolume.
//
// Called when the workspace is paused (container frozen). A failed snapshot is
// logged but does not prevent the pause from completing — the workspace must be
// pauseable regardless of snapshot tool availability.
func (ws *WorkspaceSnapshotter) Snapshot(ctx context.Context) error {
	if ws == nil || !ws.snapshotOnPause {
		return nil
	}

	bfg, err := exec.LookPath("bfg")
	if err != nil {
		log.Printf("[workspace-snapshot] bfg not found, skipping pause snapshot")
		return nil
	}

	log.Printf("[workspace-snapshot] snapshotting workspace at %s", ws.workspacePath)
	out, err := exec.CommandContext(ctx, bfg,
		"--YES=true",
		"local_commit",
		"--SUBVOLUME="+ws.workspacePath,
	).CombinedOutput()
	if err != nil {
		return fmt.Errorf("bfg local_commit %s: %w\n%s",
			ws.workspacePath, err, strings.TrimSpace(string(out)))
	}
	log.Printf("[workspace-snapshot] pause snapshot complete")

	// Prune old snapshots after taking a new one, if configured.
	if ws.pruneKeep > 0 {
		if pruneErr := ws.prune(ctx); pruneErr != nil {
			log.Printf("[workspace-snapshot] prune after snapshot failed (non-fatal): %v", pruneErr)
		}
	}

	return nil
}

// Demote compresses the workspace subvolume to a DwarFS archive via bdfs demote
// and optionally pins the archive to IPFS.
//
// Called when the workspace is deleted. A failed demote is logged but does not
// prevent deletion.
func (ws *WorkspaceSnapshotter) Demote(ctx context.Context) error {
	if ws == nil || !ws.demoteOnDelete {
		return nil
	}

	bdfs, err := exec.LookPath("bdfs")
	if err != nil {
		log.Printf("[workspace-snapshot] bdfs not found, skipping delete demote")
		return nil
	}

	imageName := ws.workspacePath + ".dwarfs"
	log.Printf("[workspace-snapshot] demoting workspace %s → %s (compression: %s)",
		ws.workspacePath, imageName, ws.compression)

	out, err := exec.CommandContext(ctx, bdfs,
		"demote",
		"--blend-path", ws.workspacePath,
		"--image-name", imageName,
		"--compression", ws.compression,
	).CombinedOutput()
	if err != nil {
		return fmt.Errorf("bdfs demote %s: %w\n%s",
			ws.workspacePath, err, strings.TrimSpace(string(out)))
	}
	log.Printf("[workspace-snapshot] delete demote complete → %s", imageName)

	// Pin the archive to IPFS when configured. Non-fatal on failure.
	if ws.pinner != nil {
		pinCtx, cancel := context.WithTimeout(ctx, 30*time.Minute)
		defer cancel()
		result, pinErr := ws.pinner.Pin(pinCtx, imageName)
		if pinErr != nil {
			log.Printf("[workspace-snapshot] IPFS pin failed (non-fatal): %v", pinErr)
		} else if !result.Cached {
			log.Printf("[workspace-snapshot] pinned %s → %s (%.1f MiB)",
				imageName, result.CID, float64(result.SizeBytes)/(1<<20))
		}
	}

	return nil
}

// prune removes old bfg snapshots, keeping at most ws.pruneKeep.
func (ws *WorkspaceSnapshotter) prune(ctx context.Context) error {
	bdfs, err := exec.LookPath("bdfs")
	if err != nil {
		return nil // bdfs absent — skip pruning silently
	}

	args := []string{
		"snapshot", "prune",
		"--blend-path", ws.workspacePath,
		"--keep", fmt.Sprintf("%d", ws.pruneKeep),
	}
	if ws.compression != "" {
		args = append(args, "--compression", ws.compression)
	}

	out, err := exec.CommandContext(ctx, bdfs, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("bdfs snapshot prune: %w\n%s", err, strings.TrimSpace(string(out)))
	}
	return nil
}
