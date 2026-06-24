// Package dwarspin pins DwarFS archives produced by bdfs demote to IPFS,
// making evicted artifacts and demoted LFS snapshots retrievable by CID.
//
// Archives are streamed to the Kubo HTTP API as chunked CAR data via
// /api/v0/dag/import, then pinned via /api/v0/pin/add. A local SQLite index
// records the path → CID mapping so repeated calls are idempotent.
package dwarfspin

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"mime/multipart"
	"net/http"
	"os"
	"time"
)

const (
	// defaultChunkSizeKB is the CAR chunk size used when Config.ChunkSizeKB is 0.
	defaultChunkSizeKB = 256

	// defaultIndexPath is the SQLite index file used when Config.IndexPath is empty.
	defaultIndexPath = "/var/lib/gitlab-enhanced/dwarfs-pin.db"

	// kuboTimeout is the HTTP client timeout for Kubo API calls.
	// dag/import of a large archive can take minutes; this is a per-request
	// deadline set on the context by callers, not a transport timeout.
	kuboTimeout = 30 * time.Second
)

// Config holds dwarfs-pin configuration, populated from IPFSConfig.DwarfsPin.
type Config struct {
	// Enabled must be true for Pin to do anything. When false, Pin is a no-op.
	Enabled bool

	// KuboAPI is the base URL of the Kubo HTTP RPC API (e.g. http://127.0.0.1:5001).
	KuboAPI string

	// ChunkSizeKB is the size of each CAR chunk in KiB. Defaults to 256 KiB.
	ChunkSizeKB int

	// IndexPath is the path to the SQLite index file.
	// Defaults to /var/lib/gitlab-enhanced/dwarfs-pin.db.
	IndexPath string
}

// PinResult is returned by Pin on success.
type PinResult struct {
	// CID is the root IPFS CID of the pinned archive.
	CID string
	// Cached is true when the CID was returned from the local index without
	// contacting Kubo (the archive was already pinned).
	Cached bool
	// SizeBytes is the size of the archive file that was pinned.
	SizeBytes int64
}

// Pinner pins DwarFS archives to IPFS via the Kubo HTTP API.
// A nil *Pinner is safe to use — all methods return nil immediately.
type Pinner struct {
	cfg    Config
	index  *Index
	client *http.Client
}

// New constructs a Pinner. Returns nil when cfg.Enabled is false, so callers
// can use a nil *Pinner without any conditional logic.
func New(cfg Config) (*Pinner, error) {
	if !cfg.Enabled {
		return nil, nil //nolint:nilnil // intentional: nil Pinner = disabled
	}
	if cfg.KuboAPI == "" {
		return nil, fmt.Errorf("dwarfs-pin: KuboAPI must be set when enabled")
	}
	if cfg.ChunkSizeKB == 0 {
		cfg.ChunkSizeKB = defaultChunkSizeKB
	}
	if cfg.IndexPath == "" {
		cfg.IndexPath = defaultIndexPath
	}

	idx, err := OpenIndex(cfg.IndexPath)
	if err != nil {
		return nil, fmt.Errorf("dwarfs-pin: open index %s: %w", cfg.IndexPath, err)
	}

	return &Pinner{
		cfg:   cfg,
		index: idx,
		client: &http.Client{
			// No global timeout — callers pass a context with their own deadline.
			Transport: &http.Transport{
				MaxIdleConns:    4,
				IdleConnTimeout: 90 * time.Second,
			},
		},
	}, nil
}

// Close releases resources held by the Pinner (SQLite connection).
func (p *Pinner) Close() error {
	if p == nil {
		return nil
	}
	return p.index.Close()
}

// Pin pins the DwarFS archive at archivePath to IPFS.
//
// If the path is already recorded in the local index, the cached CID is
// returned without contacting Kubo. Otherwise the archive is streamed as a
// chunked CAR to /api/v0/dag/import, the root CID is pinned, and the mapping
// is recorded in the index.
//
// A nil *Pinner returns (PinResult{}, nil) immediately.
func (p *Pinner) Pin(ctx context.Context, archivePath string) (PinResult, error) {
	if p == nil {
		return PinResult{}, nil
	}

	// Check the local index first — avoid re-pinning already-pinned archives.
	if cid, err := p.index.Lookup(archivePath); err == nil && cid != "" {
		log.Printf("[dwarfs-pin] %s already pinned as %s (cached)", archivePath, cid)
		return PinResult{CID: cid, Cached: true}, nil
	}

	fi, err := os.Stat(archivePath)
	if err != nil {
		return PinResult{}, fmt.Errorf("dwarfs-pin: stat %s: %w", archivePath, err)
	}

	log.Printf("[dwarfs-pin] pinning %s (%.1f MiB) to %s",
		archivePath, float64(fi.Size())/(1<<20), p.cfg.KuboAPI)

	cid, err := p.dagImport(ctx, archivePath)
	if err != nil {
		return PinResult{}, fmt.Errorf("dwarfs-pin: dag/import %s: %w", archivePath, err)
	}

	if err := p.pinAdd(ctx, cid); err != nil {
		return PinResult{}, fmt.Errorf("dwarfs-pin: pin/add %s: %w", cid, err)
	}

	if err := p.index.Record(archivePath, cid); err != nil {
		// Non-fatal: the archive is pinned; only the index entry is missing.
		log.Printf("[dwarfs-pin] warning: could not record %s → %s in index: %v",
			archivePath, cid, err)
	}

	log.Printf("[dwarfs-pin] pinned %s → %s", archivePath, cid)
	return PinResult{CID: cid, SizeBytes: fi.Size()}, nil
}

// Unpin removes the IPFS pin for archivePath and deletes the index entry.
// A nil *Pinner returns nil immediately.
func (p *Pinner) Unpin(ctx context.Context, archivePath string) error {
	if p == nil {
		return nil
	}

	cid, err := p.index.Lookup(archivePath)
	if err != nil || cid == "" {
		return fmt.Errorf("dwarfs-pin: %s not found in index", archivePath)
	}

	if err := p.pinRm(ctx, cid); err != nil {
		return fmt.Errorf("dwarfs-pin: pin/rm %s: %w", cid, err)
	}

	if err := p.index.Delete(archivePath); err != nil {
		log.Printf("[dwarfs-pin] warning: could not remove index entry for %s: %v", archivePath, err)
	}

	log.Printf("[dwarfs-pin] unpinned %s (%s)", archivePath, cid)
	return nil
}

// Stat returns the CID recorded for archivePath, or an error if not found.
// A nil *Pinner returns an error.
func (p *Pinner) Stat(archivePath string) (string, error) {
	if p == nil {
		return "", fmt.Errorf("dwarfs-pin: not configured")
	}
	cid, err := p.index.Lookup(archivePath)
	if err != nil {
		return "", err
	}
	if cid == "" {
		return "", fmt.Errorf("dwarfs-pin: %s not in index", archivePath)
	}
	return cid, nil
}

// --- Kubo HTTP API calls ---

// dagImport streams archivePath as a chunked CAR to /api/v0/dag/import and
// returns the root CID reported by Kubo.
//
// Requires Kubo 0.10 or later. Earlier versions do not expose the
// /api/v0/dag/import endpoint. If you are running an older node, upgrade
// Kubo or disable dwarfs_pin — there is no fallback to /api/v0/add because
// that endpoint does not return a stable root CID for multi-block imports.
//
// The file is read in chunks of cfg.ChunkSizeKB KiB and written into a
// multipart/form-data body. This keeps memory usage bounded regardless of
// archive size.
func (p *Pinner) dagImport(ctx context.Context, archivePath string) (string, error) {
	f, err := os.Open(archivePath)
	if err != nil {
		return "", err
	}
	defer f.Close()

	// Build the multipart body with a pipe so we stream directly from disk
	// without buffering the entire file in memory.
	pr, pw := io.Pipe()
	mw := multipart.NewWriter(pw)

	go func() {
		part, err := mw.CreateFormFile("file", "archive.car")
		if err != nil {
			pw.CloseWithError(err)
			return
		}
		chunkSize := int64(p.cfg.ChunkSizeKB) * 1024
		buf := make([]byte, chunkSize)
		if _, err := io.CopyBuffer(part, f, buf); err != nil {
			pw.CloseWithError(err)
			return
		}
		mw.Close()
		pw.Close()
	}()

	url := p.cfg.KuboAPI + "/api/v0/dag/import?pin-roots=false"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, pr)
	if err != nil {
		pr.CloseWithError(err)
		return "", err
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())

	resp, err := p.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return "", fmt.Errorf("kubo dag/import returned HTTP %d: %s", resp.StatusCode, body)
	}

	// Kubo returns one JSON object per root, newline-delimited.
	// We read the first (and typically only) root CID.
	var result struct {
		Root struct {
			Cid struct {
				Slash string `json:"/"`
			} `json:"Cid"`
		} `json:"Root"`
	}
	dec := json.NewDecoder(resp.Body)
	if err := dec.Decode(&result); err != nil {
		return "", fmt.Errorf("decode dag/import response: %w", err)
	}
	cid := result.Root.Cid.Slash
	if cid == "" {
		return "", fmt.Errorf("dag/import returned empty CID")
	}
	return cid, nil
}

// pinAdd calls /api/v0/pin/add to pin cid on the Kubo node.
func (p *Pinner) pinAdd(ctx context.Context, cid string) error {
	url := p.cfg.KuboAPI + "/api/v0/pin/add?arg=" + cid + "&recursive=true"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, nil)
	if err != nil {
		return err
	}
	resp, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("kubo pin/add returned HTTP %d: %s", resp.StatusCode, body)
	}
	return nil
}

// pinRm calls /api/v0/pin/rm to unpin cid from the Kubo node.
func (p *Pinner) pinRm(ctx context.Context, cid string) error {
	url := p.cfg.KuboAPI + "/api/v0/pin/rm?arg=" + cid + "&recursive=true"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, nil)
	if err != nil {
		return err
	}
	resp, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("kubo pin/rm returned HTTP %d: %s", resp.StatusCode, body)
	}
	return nil
}

// kuboError is a helper that reads a Kubo error response body for logging.
func kuboError(body []byte) string {
	var e struct{ Message string }
	if err := json.Unmarshal(body, &e); err == nil && e.Message != "" {
		return e.Message
	}
	return string(bytes.TrimSpace(body))
}
