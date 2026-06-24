package dwarfspin

// index.go — SQLite-backed index mapping archive paths to IPFS CIDs.
//
// The index is the source of truth for which archives have been pinned and
// what their CIDs are. It is consulted before every Pin call so that already-
// pinned archives are not re-uploaded to Kubo.
//
// Schema:
//
//	CREATE TABLE pins (
//	    path       TEXT PRIMARY KEY,
//	    cid        TEXT NOT NULL,
//	    pinned_at  TEXT NOT NULL   -- RFC3339 UTC
//	);

import (
	"database/sql"
	"fmt"
	"time"

	_ "modernc.org/sqlite" // pure-Go SQLite driver, no cgo required
)

// Index is a SQLite-backed store of path → CID mappings.
type Index struct {
	db *sql.DB
}

// OpenIndex opens (or creates) the SQLite index at path.
func OpenIndex(path string) (*Index, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("ping %s: %w", path, err)
	}
	if err := migrate(db); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate %s: %w", path, err)
	}
	return &Index{db: db}, nil
}

// Close releases the database connection.
func (idx *Index) Close() error {
	if idx == nil || idx.db == nil {
		return nil
	}
	return idx.db.Close()
}

// Lookup returns the CID recorded for path, or ("", nil) if not found.
func (idx *Index) Lookup(path string) (string, error) {
	var cid string
	err := idx.db.QueryRow(`SELECT cid FROM pins WHERE path = ?`, path).Scan(&cid)
	if err == sql.ErrNoRows {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("index lookup %s: %w", path, err)
	}
	return cid, nil
}

// Record inserts or replaces the path → cid mapping with the current UTC time.
func (idx *Index) Record(path, cid string) error {
	_, err := idx.db.Exec(
		`INSERT OR REPLACE INTO pins (path, cid, pinned_at) VALUES (?, ?, ?)`,
		path, cid, time.Now().UTC().Format(time.RFC3339),
	)
	if err != nil {
		return fmt.Errorf("index record %s → %s: %w", path, cid, err)
	}
	return nil
}

// Delete removes the index entry for path.
func (idx *Index) Delete(path string) error {
	_, err := idx.db.Exec(`DELETE FROM pins WHERE path = ?`, path)
	if err != nil {
		return fmt.Errorf("index delete %s: %w", path, err)
	}
	return nil
}

// List returns all recorded path → CID pairs, ordered by pinned_at descending.
func (idx *Index) List() ([]PinEntry, error) {
	rows, err := idx.db.Query(
		`SELECT path, cid, pinned_at FROM pins ORDER BY pinned_at DESC`,
	)
	if err != nil {
		return nil, fmt.Errorf("index list: %w", err)
	}
	defer rows.Close()

	var entries []PinEntry
	for rows.Next() {
		var e PinEntry
		var pinnedAt string
		if err := rows.Scan(&e.Path, &e.CID, &pinnedAt); err != nil {
			return nil, err
		}
		e.PinnedAt, _ = time.Parse(time.RFC3339, pinnedAt)
		entries = append(entries, e)
	}
	return entries, rows.Err()
}

// PinEntry is a single record from the index.
type PinEntry struct {
	Path     string
	CID      string
	PinnedAt time.Time
}

// migrate creates the pins table if it does not already exist.
func migrate(db *sql.DB) error {
	_, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS pins (
			path      TEXT PRIMARY KEY,
			cid       TEXT NOT NULL,
			pinned_at TEXT NOT NULL
		)`)
	return err
}
