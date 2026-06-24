package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/spf13/cobra"
	"gitlab.com/openos-project/git-management_deving/gitlab-enhanced/abstraction/config"
	dwarfspin "gitlab.com/openos-project/git-management_deving/gitlab-enhanced/ipfs/dwarfs-pin"
	lfsabstraction "gitlab.com/openos-project/git-management_deving/gitlab-enhanced/lfs/abstraction"
	lfsbdfs "gitlab.com/openos-project/git-management_deving/gitlab-enhanced/lfs/adapters/bdfs"
)

func newLFSCmd(cfgRoot *string) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "lfs",
		Short: "Manage the Git LFS server",
	}
	cmd.AddCommand(
		newLFSServeCmd(cfgRoot),
		newLFSStatusCmd(cfgRoot),
		newLFSDemoteCmd(cfgRoot),
		newLFSSetupCmd(cfgRoot),
	)
	return cmd
}

// lfs serve ---------------------------------------------------------------

func newLFSServeCmd(cfgRoot *string) *cobra.Command {
	var (
		addr   string
		server string
	)
	cmd := &cobra.Command{
		Use:   "serve",
		Short: "Start the LFS server in the foreground",
		Long: `Starts the configured LFS server (rudolfs or giftless) in the foreground.

For production use, run 'gitlab-enhanced up' which manages the server as an
Incus container.

When lfs.bdfs_snapshot_on_serve is true and bfg is installed, a btr-fs-git
snapshot of the LFS store is taken before the server starts. When
lfs.bdfs_prune_keep is non-zero and bdfs is installed, old snapshots are
pruned (and archived as DwarFS images) after the server exits. When
lfs.bdfs_demote_on_shutdown is true, the entire LFS store is compressed to a
DwarFS image after the server exits.

Run 'gitlab-enhanced lfs setup' first to verify lfs.path is a BTRFS subvolume.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runLFSServe(*cfgRoot, addr, server)
		},
	}
	cmd.Flags().StringVar(&addr, "addr", "0.0.0.0:8080", "listen address")
	cmd.Flags().StringVar(&server, "server", "", "LFS server to use (overrides config: rudolfs|giftless)")
	return cmd
}

func runLFSServe(root, addr, serverOverride string) error {
	cfg, err := loadConfig(root)
	if err != nil {
		return err
	}

	server := cfg.LFS.Server
	if serverOverride != "" {
		server = serverOverride
	}

	printSection("LFS server")
	printInfo(fmt.Sprintf("server:  %s", server))
	printInfo(fmt.Sprintf("backend: %s", cfg.LFS.Backend))
	printInfo(fmt.Sprintf("path:    %s", cfg.LFS.Path))
	printInfo(fmt.Sprintf("addr:    %s", addr))
	if cfg.LFS.BdfsSnapshotOnServe {
		printInfo("bdfs:    snapshot-on-serve enabled")
	}
	if cfg.LFS.BdfsPruneKeep > 0 {
		printInfo(fmt.Sprintf("bdfs:    prune keep=%d after serve", cfg.LFS.BdfsPruneKeep))
	}
	if cfg.LFS.BdfsDemoteOnShutdown {
		printInfo("bdfs:    demote-on-shutdown enabled")
	}
	fmt.Println()

	pinner, err := newLFSPinner(cfg)
	if err != nil {
		return fmt.Errorf("lfs serve: %w", err)
	}
	defer pinner.Close()
	if pinner != nil {
		printInfo(fmt.Sprintf("dwarfs-pin: enabled (kubo: %s)", cfg.IPFS.Node))
	}

	lifecycle := lfsbdfs.New(lfsbdfs.Config{
		StoragePath:     cfg.LFS.Path,
		SnapshotOnServe: cfg.LFS.BdfsSnapshotOnServe,
		PruneKeep:       cfg.LFS.BdfsPruneKeep,
		PrunePattern:    cfg.LFS.BdfsPrunePattern,
		Compression:     cfg.LFS.BdfsCompression,
		Pinner:          pinner,
	})

	// Option B — pre-serve snapshot.
	// Failure is logged but does not block the server from starting.
	if err := lifecycle.Snapshot(); err != nil {
		log.Printf("[lfs] pre-serve snapshot failed (continuing): %v", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var serveErr error
	switch server {
	case "rudolfs":
		serveErr = runRudolfs(ctx, addr, cfg.LFS.Path, cfg.LFS.Encryption)
	case "giftless":
		serveErr = runGiftless(ctx, addr, cfg.LFS.Path)
	case "lfs-test-server":
		serveErr = runLFSTestServer(ctx, addr, cfg.LFS.Path)
	default:
		return fmt.Errorf("unknown LFS server %q — supported: rudolfs, giftless, lfs-test-server", server)
	}

	// Option B — post-serve prune. Runs on all exits (clean or signal).
	if pruneErr := lifecycle.Prune(); pruneErr != nil {
		log.Printf("[lfs] post-serve prune failed: %v", pruneErr)
	}

	// Option B — post-serve demote (optional, off by default).
	if cfg.LFS.BdfsDemoteOnShutdown {
		if demoteErr := lifecycle.Demote(); demoteErr != nil {
			log.Printf("[lfs] post-serve demote failed: %v", demoteErr)
		}
	}

	return serveErr
}

// lfs status --------------------------------------------------------------

func newLFSStatusCmd(cfgRoot *string) *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Check LFS server health",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runLFSStatus(*cfgRoot)
		},
	}
}

func runLFSStatus(root string) error {
	cfg, err := loadConfig(root)
	if err != nil {
		return err
	}

	printSection("LFS server status")
	printInfo(fmt.Sprintf("configured server: %s", cfg.LFS.Server))
	printInfo(fmt.Sprintf("backend:           %s", cfg.LFS.Backend))
	printInfo(fmt.Sprintf("storage path:      %s", cfg.LFS.Path))
	if cfg.LFS.BdfsSnapshotOnServe {
		printInfo("bdfs snapshot-on-serve:  enabled")
	}
	if cfg.LFS.BdfsPruneKeep > 0 {
		printInfo(fmt.Sprintf("bdfs prune keep:         %d", cfg.LFS.BdfsPruneKeep))
	}
	if cfg.LFS.BdfsDemoteOnShutdown {
		printInfo("bdfs demote-on-shutdown: enabled")
	}

	endpoints := []string{
		"http://localhost:8080/",
		"http://localhost:8080/healthz",
		"http://localhost:8080/_health",
	}
	client := &http.Client{Timeout: 3 * time.Second}
	reachable := false
	for _, ep := range endpoints {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, ep, nil)
		resp, err := client.Do(req)
		cancel()
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode < 500 {
				printOK(fmt.Sprintf("LFS server reachable at %s (HTTP %d)", ep, resp.StatusCode))
				reachable = true
				break
			}
		}
	}
	if !reachable {
		printWarn("LFS server not reachable on localhost:8080 — run 'gitlab-enhanced lfs serve' or 'gitlab-enhanced up'")
	}
	return nil
}

// lfs demote --------------------------------------------------------------

func newLFSDemoteCmd(cfgRoot *string) *cobra.Command {
	var compression string
	cmd := &cobra.Command{
		Use:   "demote",
		Short: "Compress the LFS store to a DwarFS image",
		Long: `Compresses the LFS object store subvolume to a DwarFS image at
<lfs.path>.dwarfs using bdfs demote.

Use this before archiving a project or reclaiming disk space.

Requires bdfs to be installed and lfs.path to be a BTRFS subvolume.
Run 'gitlab-enhanced lfs setup' to verify the prerequisite is met.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runLFSDemote(*cfgRoot, compression)
		},
	}
	cmd.Flags().StringVar(&compression, "compression", "",
		"DwarFS compression algorithm (zstd|lzma|lz4|brotli|none); defaults to lfs.bdfs_compression")
	return cmd
}

func runLFSDemote(root, compressionOverride string) error {
	cfg, err := loadConfig(root)
	if err != nil {
		return err
	}

	compression := cfg.LFS.BdfsCompression
	if compressionOverride != "" {
		compression = compressionOverride
	}

	printSection("LFS store demote")
	printInfo(fmt.Sprintf("path:        %s", cfg.LFS.Path))
	printInfo(fmt.Sprintf("image:       %s.dwarfs", cfg.LFS.Path))
	printInfo(fmt.Sprintf("compression: %s", compression))
	fmt.Println()

	// Verify the subvolume prerequisite before attempting demote.
	result := lfsbdfs.CheckSubvolume(cfg.LFS.Path)
	if !result.Ready() {
		printWarn(fmt.Sprintf("lfs.path is %s — run 'gitlab-enhanced lfs setup' first", result.State))
		return fmt.Errorf("lfs.path is not a BTRFS subvolume")
	}

	pinner, err := newLFSPinner(cfg)
	if err != nil {
		return fmt.Errorf("lfs demote: %w", err)
	}
	defer pinner.Close()
	if pinner != nil {
		printInfo(fmt.Sprintf("dwarfs-pin: enabled (kubo: %s)", cfg.IPFS.Node))
	}

	lifecycle := lfsbdfs.New(lfsbdfs.Config{
		StoragePath: cfg.LFS.Path,
		Compression: compression,
		Pinner:      pinner,
	})

	if err := lifecycle.Demote(); err != nil {
		return fmt.Errorf("demote failed: %w", err)
	}

	printOK(fmt.Sprintf("LFS store demoted → %s.dwarfs", cfg.LFS.Path))
	if pinner != nil {
		printOK(fmt.Sprintf("archive pinned to IPFS (see: gitlab-enhanced ipfs dwarfs-pin stat %s.dwarfs)", cfg.LFS.Path))
	}
	return nil
}

// lfs setup ---------------------------------------------------------------

func newLFSSetupCmd(cfgRoot *string) *cobra.Command {
	var convert bool
	cmd := &cobra.Command{
		Use:   "setup",
		Short: "Verify and prepare lfs.path as a BTRFS subvolume",
		Long: `Checks whether lfs.path is a BTRFS subvolume, which is required for
bdfs snapshot, prune, and demote operations.

Without --convert, this command only reports the current state and exits
non-zero if lfs.path is not a subvolume.

With --convert, if lfs.path is a plain directory its contents are moved to a
temporary backup (lfs.path.bak), a new BTRFS subvolume is created at lfs.path,
the contents are copied back, and the backup is removed. The backup is
preserved if any step fails so data is always recoverable.

If lfs.path does not exist yet, the subvolume is created directly.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runLFSSetup(*cfgRoot, convert)
		},
	}
	cmd.Flags().BoolVar(&convert, "convert", false,
		"convert lfs.path from a plain directory to a BTRFS subvolume")
	return cmd
}

func runLFSSetup(root string, convert bool) error {
	cfg, err := loadConfig(root)
	if err != nil {
		return err
	}

	printSection("LFS storage setup")
	printInfo(fmt.Sprintf("lfs.path: %s", cfg.LFS.Path))
	fmt.Println()

	result := lfsbdfs.CheckSubvolume(cfg.LFS.Path)

	switch result.State {
	case lfsbdfs.StateSubvolume:
		printOK("lfs.path is a BTRFS subvolume — no action needed")
		if result.Detail != "" {
			fmt.Println()
			fmt.Println(result.Detail)
		}
		return nil

	case lfsbdfs.StateNotExist:
		if !convert {
			printWarn("lfs.path does not exist")
			printInfo("Run with --convert to create a BTRFS subvolume at lfs.path")
			return fmt.Errorf("lfs.path does not exist")
		}
		printInfo("lfs.path does not exist — creating BTRFS subvolume")
		if err := lfsbdfs.ConvertToSubvolume(cfg.LFS.Path); err != nil {
			return fmt.Errorf("create subvolume: %w", err)
		}
		printOK(fmt.Sprintf("BTRFS subvolume created at %s", cfg.LFS.Path))
		return nil

	case lfsbdfs.StatePlainDir:
		printWarn("lfs.path is a plain directory, not a BTRFS subvolume")
		printInfo("bdfs snapshot, prune, and demote will not work until it is converted")
		if !convert {
			printInfo("Run with --convert to convert it in-place (data is preserved via a backup)")
			return fmt.Errorf("lfs.path is not a BTRFS subvolume")
		}
		printInfo(fmt.Sprintf("Converting %s to a BTRFS subvolume...", cfg.LFS.Path))
		printInfo(fmt.Sprintf("Backup will be created at %s.bak during conversion", cfg.LFS.Path))
		fmt.Println()
		printWarn("ACLs and extended attributes (SELinux labels, capabilities, xattrs) are")
		printWarn("not preserved by the pure-Go fallback copy. If your LFS store has ACLs,")
		printWarn("run: getfattr -Rn . " + cfg.LFS.Path + "  before proceeding.")
		printWarn("When rsync or cp is available they are used automatically and do preserve xattrs.")
		fmt.Println()
		if err := lfsbdfs.ConvertToSubvolume(cfg.LFS.Path); err != nil {
			printWarn(fmt.Sprintf("Conversion failed: %v", err))
			printInfo(fmt.Sprintf("Original data is preserved in %s.bak", cfg.LFS.Path))
			return err
		}
		printOK(fmt.Sprintf("Converted %s to a BTRFS subvolume", cfg.LFS.Path))
		return nil

	default: // StateUnknown
		printWarn(fmt.Sprintf("Cannot determine subvolume status: %s", result.Detail))
		printInfo("Ensure btrfs-progs is installed: apt install btrfs-progs / dnf install btrfs-progs")
		return fmt.Errorf("subvolume check failed: %s", result.Detail)
	}
}

// newLFSPinner constructs a *dwarfspin.Pinner from the IPFS config when both
// ipfs.enabled and ipfs.dwarfs_pin.enabled are true. Returns nil otherwise,
// which is safe to pass into lfsbdfs.Config — Demote() skips pinning silently
// when Pinner is nil.
func newLFSPinner(cfg *config.Config) (*dwarfspin.Pinner, error) {
	if !cfg.IPFS.Enabled || !cfg.IPFS.DwarfsPin.Enabled {
		return nil, nil
	}
	if cfg.IPFS.Node == "" {
		return nil, fmt.Errorf("ipfs.node must be set when ipfs.dwarfs_pin.enabled=true")
	}
	pinner, err := dwarfspin.New(dwarfspin.Config{
		Enabled:     true,
		KuboAPI:     cfg.IPFS.Node,
		ChunkSizeKB: cfg.IPFS.DwarfsPin.ChunkSizeKB,
		IndexPath:   cfg.IPFS.DwarfsPin.IndexPath,
	})
	if err != nil {
		return nil, fmt.Errorf("dwarfs-pin: %w", err)
	}
	return pinner, nil
}

// LFS server runners ------------------------------------------------------

func runLFSServer(ctx context.Context, binary, addr string, args []string) error {
	if err := checkBinary(binary); err != nil {
		return err
	}
	printOK(fmt.Sprintf("starting %s on %s", binary, addr))
	srv := lfsabstraction.NewExecServer(binary, addr, args)
	return srv.Start(ctx, lfsabstraction.Config{})
}

func runRudolfs(ctx context.Context, addr, storagePath string, encryption bool) error {
	args := []string{"--host", addr, "--cache-dir", storagePath}
	if encryption {
		args = append(args, "--encrypt")
	}
	return runLFSServer(ctx, "rudolfs", addr, args)
}

func runGiftless(ctx context.Context, addr, storagePath string) error {
	return runLFSServer(ctx, "giftless-server", addr, []string{
		"--host", addr,
		"--storage-path", storagePath,
	})
}

func runLFSTestServer(ctx context.Context, addr, storagePath string) error {
	return runLFSServer(ctx, "lfs-test-server", addr, []string{
		"-host", addr,
		"-dir", storagePath,
	})
}
