// Copyright (c) 2020 Gitpod GmbH. All rights reserved.
// Licensed under the GNU Affero General Public License (AGPL).
// See License.AGPL.txt in the project root for license information.
package supervisor

// shutdown_hooks.go — wires WorkspaceSnapshotter into the supervisor shutdown
// path.
//
// The supervisor calls RunShutdownHooks before the workspace container is
// stopped. The reason parameter distinguishes pause (snapshot) from delete
// (demote). All hooks are best-effort: failures are logged but do not prevent
// the workspace from stopping.

import (
	"context"
	"log"
	"time"
)

// ShutdownReason describes why the workspace is being stopped.
type ShutdownReason int

const (
	// ShutdownReasonPause is used when the workspace is being paused (frozen).
	// The container will be resumed later; a snapshot preserves the current state.
	ShutdownReasonPause ShutdownReason = iota

	// ShutdownReasonDelete is used when the workspace is being permanently deleted.
	// A demote compresses the subvolume to a DwarFS archive before destruction.
	ShutdownReasonDelete

	// ShutdownReasonStop is a normal stop with no snapshot or demote.
	ShutdownReasonStop
)

// String returns a human-readable label for the shutdown reason.
func (r ShutdownReason) String() string {
	switch r {
	case ShutdownReasonPause:
		return "pause"
	case ShutdownReasonDelete:
		return "delete"
	default:
		return "stop"
	}
}

// shutdownHookTimeout is the maximum time allowed for all shutdown hooks to
// complete. Chosen to be long enough for large workspace demotes over a slow
// disk, but short enough to avoid blocking the workspace manager indefinitely.
const shutdownHookTimeout = 45 * time.Minute

// RunShutdownHooks executes the bdfs lifecycle hooks appropriate for reason.
//
// Called by the supervisor immediately before the workspace container is
// stopped. A nil snapshotter is a no-op. Hook failures are logged but do not
// propagate — the workspace must stop regardless.
func RunShutdownHooks(ctx context.Context, ws *WorkspaceSnapshotter, reason ShutdownReason) {
	if ws == nil {
		return
	}

	hookCtx, cancel := context.WithTimeout(ctx, shutdownHookTimeout)
	defer cancel()

	log.Printf("[shutdown-hooks] running hooks for reason=%s", reason)

	switch reason {
	case ShutdownReasonPause:
		if err := ws.Snapshot(hookCtx); err != nil {
			log.Printf("[shutdown-hooks] snapshot failed (non-fatal): %v", err)
		}

	case ShutdownReasonDelete:
		if err := ws.Demote(hookCtx); err != nil {
			log.Printf("[shutdown-hooks] demote failed (non-fatal): %v", err)
		}

	default:
		// ShutdownReasonStop — no snapshot or demote needed.
	}

	log.Printf("[shutdown-hooks] hooks complete for reason=%s", reason)
}

// InitSnapshotter constructs a WorkspaceSnapshotter from the supervisor Config
// and registers a deferred Close on the provided cleanup function. Returns nil
// when all bdfs features are disabled.
//
// Typical usage in the supervisor main loop:
//
//	var cleanups []func()
//	ws, err := InitSnapshotter(cfg, func(f func()) { cleanups = append(cleanups, f) })
//	if err != nil {
//	    return err
//	}
//	defer func() {
//	    for _, f := range cleanups { f() }
//	}()
func InitSnapshotter(cfg *Config, addCleanup func(func())) (*WorkspaceSnapshotter, error) {
	ws, err := NewWorkspaceSnapshotter(cfg)
	if err != nil {
		return nil, err
	}
	if ws != nil {
		addCleanup(func() {
			if err := ws.Close(); err != nil {
				log.Printf("[shutdown-hooks] snapshotter close error: %v", err)
			}
		})
	}
	return ws, nil
}
