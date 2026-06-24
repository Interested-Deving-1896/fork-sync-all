package bandwidth

// bdfs.go — bdfs-backed artifact eviction helper.
//
// When BdfsArchiveDir is set in Config, evictArtifact calls bdfs to demote
// the artifact path to a compressed DwarFS image before removing it.  If bdfs
// is absent or the demote fails the function falls back to os.Remove so that
// eviction always makes forward progress regardless of whether bdfs is
// installed.
//
// When a non-nil *dwarfspin.Pinner is provided, successfully demoted archives
// are pinned to IPFS immediately after creation. A failed pin is logged but
// does not prevent the artifact from being evicted.

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	dwarfspin "gitlab.com/openos-project/git-management_deving/gitlab-enhanced/ipfs/dwarfs-pin"
)

// bdfsAvailable returns the path to the bdfs binary, or "" if not found.
func bdfsAvailable() string {
	p, err := exec.LookPath("bdfs")
	if err != nil {
		return ""
	}
	return p
}

// demoteArtifact compresses the file at artifactPath into archiveDir as a
// DwarFS image, then removes the original.
//
// The archive filename is the artifact's base name with ".dwarfs" appended.
// Returns the path of the created archive on success, or an error.
// The original file is only removed after a successful demote.
func demoteArtifact(bdfs, artifactPath, archiveDir string) (string, error) {
	if err := os.MkdirAll(archiveDir, 0755); err != nil {
		return "", fmt.Errorf("bdfs: create archive dir %s: %w", archiveDir, err)
	}

	base := filepath.Base(artifactPath)
	stem := strings.TrimSuffix(base, filepath.Ext(base))
	archivePath := filepath.Join(archiveDir, stem+".dwarfs")

	cmd := exec.Command(bdfs,
		"demote",
		"--blend-path", artifactPath,
		"--image-name", archivePath,
		"--compression", "zstd",
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("bdfs demote %s: %w\n%s", artifactPath, err, strings.TrimSpace(string(out)))
	}

	if rmErr := os.Remove(artifactPath); rmErr != nil && !os.IsNotExist(rmErr) {
		log.Printf("[bandwidth] bdfs: demoted %s → %s but could not remove original: %v",
			artifactPath, archivePath, rmErr)
	}

	return archivePath, nil
}

// evictArtifactFile removes an artifact file, optionally archiving it first
// via bdfs when archiveDir is non-empty and bdfs is installed. When pinner is
// non-nil, a successfully created archive is pinned to IPFS.
//
// Returns true if the file was successfully removed (or archived+removed),
// false if it should be retried later.
func evictArtifactFile(artifactPath, archiveDir string, pinner *dwarfspin.Pinner) bool {
	if archiveDir != "" {
		if bdfs := bdfsAvailable(); bdfs != "" {
			archive, err := demoteArtifact(bdfs, artifactPath, archiveDir)
			if err != nil {
				log.Printf("[bandwidth] bdfs demote failed for %s, falling back to delete: %v",
					artifactPath, err)
				// Fall through to plain os.Remove below.
			} else {
				log.Printf("[bandwidth] archived artifact %s → %s", artifactPath, archive)

				// Pin the archive to IPFS when configured. Non-fatal on failure.
				if pinner != nil {
					ctx, cancel := context.WithTimeout(context.Background(), 10*60*1e9) // 10 min
					result, pinErr := pinner.Pin(ctx, archive)
					cancel()
					if pinErr != nil {
						log.Printf("[bandwidth] ipfs pin failed for %s: %v", archive, pinErr)
					} else if !result.Cached {
						log.Printf("[bandwidth] ipfs pinned %s → %s", archive, result.CID)
					}
				}

				return true
			}
		}
	}

	// Plain removal — either archiveDir is empty, bdfs is absent, or demote failed.
	if err := os.Remove(artifactPath); err != nil && !os.IsNotExist(err) {
		log.Printf("[bandwidth] remove artifact %s: %v", artifactPath, err)
		return false
	}
	return true
}
