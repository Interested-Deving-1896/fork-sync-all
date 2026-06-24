package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/spf13/cobra"
	"gitlab.com/openos-project/git-management_deving/gitlab-enhanced/abstraction/config"
	"gitlab.com/openos-project/git-management_deving/gitlab-enhanced/bandwidth"
)

func newBandwidthCmd(cfgRoot *string) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "bandwidth",
		Short: "Manage server-side bandwidth optimisation",
		Long: `Manage the bandwidth optimisation service.

Three mechanisms work together to reduce transfer sizes and disk usage:

  1. Compression proxy — gzip middleware in front of GitLab and LFS endpoints
     (typically 60-80% reduction for text payloads like API responses and diffs)

  2. LFS deduplication — content-addressed hardlinks for identical LFS objects
     across repositories (saves disk when multiple repos store the same file)

  3. CI artifact policies — size limits and retention windows to prevent
     unbounded disk growth from CI artifacts and caches

Enable in config/local.yaml:

  bandwidth:
    enabled: true
    compression_level: 6
    lfs_dedup_enabled: true
    artifact_max_size_mb: 500
    artifact_retention_days: 30
    bdfs_archive_dir: /var/lib/gitlab-enhanced/artifact-archives`,
	}

	cmd.AddCommand(
		newBandwidthServeCmd(cfgRoot),
		newBandwidthStatusCmd(cfgRoot),
		newBandwidthStatsCmd(cfgRoot),
		newBandwidthDedupCmd(cfgRoot),
		newBandwidthEvictCmd(cfgRoot),
		newBandwidthPolicyCmd(cfgRoot),
	)
	return cmd
}

// bandwidth serve — start the bandwidth proxy service
func newBandwidthServeCmd(cfgRoot *string) *cobra.Command {
	return &cobra.Command{
		Use:   "serve",
		Short: "Start the bandwidth proxy service",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := loadConfig(*cfgRoot)
			if err != nil {
				return err
			}
			if !cfg.Bandwidth.Enabled {
				return fmt.Errorf("bandwidth service is disabled — set bandwidth.enabled: true in config/local.yaml")
			}

			svc, err := bandwidth.New(bandwidth.Config{
				Enabled:               cfg.Bandwidth.Enabled,
				ListenAddr:            cfg.Bandwidth.ListenAddr,
				CompressionLevel:      cfg.Bandwidth.CompressionLevel,
				LFSDedupEnabled:       cfg.Bandwidth.LFSDedupEnabled,
				LFSStorePath:          cfg.LFS.Path,
				ArtifactMaxSizeMB:     cfg.Bandwidth.ArtifactMaxSizeMB,
				ArtifactRetentionDays: cfg.Bandwidth.ArtifactRetentionDays,
				CacheMaxSizeGB:        cfg.Bandwidth.CacheMaxSizeGB,
				UpstreamGitLab:        bandwidthUpstream(cfg),
				DBPath:                cfg.Bandwidth.DBPath,
				BdfsArchiveDir:        cfg.Bandwidth.BdfsArchiveDir,
			})
			if err != nil {
				return err
			}

			ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
			defer stop()

			printSection("Starting bandwidth service")
			printInfo(fmt.Sprintf("Listen:      http://%s", cfg.Bandwidth.ListenAddr))
			printInfo(fmt.Sprintf("Upstream:    http://%s", cfg.GitLab.Domain))
			printInfo(fmt.Sprintf("Compression: level %d", cfg.Bandwidth.CompressionLevel))
			printInfo(fmt.Sprintf("LFS dedup:   %v", cfg.Bandwidth.LFSDedupEnabled))
			if cfg.Bandwidth.ArtifactRetentionDays > 0 {
				printInfo(fmt.Sprintf("Artifact TTL: %d days", cfg.Bandwidth.ArtifactRetentionDays))
			}
			if cfg.Bandwidth.ArtifactMaxSizeMB > 0 {
				printInfo(fmt.Sprintf("Artifact max: %d MB", cfg.Bandwidth.ArtifactMaxSizeMB))
			}
			if cfg.Bandwidth.BdfsArchiveDir != "" {
				printInfo(fmt.Sprintf("bdfs archive: %s", cfg.Bandwidth.BdfsArchiveDir))
			}

			return svc.Start(ctx)
		},
	}
}

// bandwidth status — liveness check
func newBandwidthStatusCmd(cfgRoot *string) *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Check bandwidth service health",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := loadConfig(*cfgRoot)
			if err != nil {
				return err
			}
			if !cfg.Bandwidth.Enabled {
				printWarn("bandwidth service is disabled (bandwidth.enabled: false)")
				return nil
			}
			addr := bandwidthAddr(cfg.Bandwidth.ListenAddr)
			resp, err := httpGet("http://" + addr + "/health")
			if err != nil {
				printWarn(fmt.Sprintf("bandwidth service not reachable at %s: %v", addr, err))
				return nil
			}
			printOK(fmt.Sprintf("bandwidth service healthy at http://%s", addr))
			fmt.Println(resp)
			return nil
		},
	}
}

// bandwidth stats — show transfer statistics
func newBandwidthStatsCmd(cfgRoot *string) *cobra.Command {
	return &cobra.Command{
		Use:   "stats",
		Short: "Show bandwidth savings statistics",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := loadConfig(*cfgRoot)
			if err != nil {
				return err
			}
			addr := bandwidthAddr(cfg.Bandwidth.ListenAddr)
			body, err := httpGet("http://" + addr + "/stats")
			if err != nil {
				return fmt.Errorf("bandwidth service not reachable: %w", err)
			}
			var v any
			if err := json.Unmarshal([]byte(body), &v); err != nil {
				fmt.Println(body)
				return nil
			}
			out, _ := json.MarshalIndent(v, "", "  ")
			fmt.Println(string(out))
			return nil
		},
	}
}

// bandwidth dedup — deduplicate an LFS object
func newBandwidthDedupCmd(cfgRoot *string) *cobra.Command {
	return &cobra.Command{
		Use:   "dedup <oid> <size>",
		Short: "Check/apply LFS deduplication for an object",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := loadConfig(*cfgRoot)
			if err != nil {
				return err
			}
			addr := bandwidthAddr(cfg.Bandwidth.ListenAddr)
			payload := fmt.Sprintf(`{"oid":%q,"size":%s}`, args[0], args[1])
			client := &http.Client{Timeout: 10 * time.Second}
			resp, err := client.Post("http://"+addr+"/lfs/dedup", "application/json", stringReader(payload))
			if err != nil {
				return fmt.Errorf("bandwidth service not reachable: %w", err)
			}
			defer resp.Body.Close()
			var result any
			if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
				return err
			}
			out, _ := json.MarshalIndent(result, "", "  ")
			fmt.Println(string(out))
			return nil
		},
	}
}

// bandwidth evict — manually trigger artifact eviction
func newBandwidthEvictCmd(cfgRoot *string) *cobra.Command {
	return &cobra.Command{
		Use:   "evict",
		Short: "Trigger immediate CI artifact eviction",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := loadConfig(*cfgRoot)
			if err != nil {
				return err
			}
			addr := bandwidthAddr(cfg.Bandwidth.ListenAddr)
			client := &http.Client{Timeout: 30 * time.Second}
			resp, err := client.Post("http://"+addr+"/artifacts/evict", "application/json", nil)
			if err != nil {
				return fmt.Errorf("bandwidth service not reachable: %w", err)
			}
			defer resp.Body.Close()
			var result any
			if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
				return err
			}
			out, _ := json.MarshalIndent(result, "", "  ")
			fmt.Println(string(out))
			return nil
		},
	}
}

// bandwidth policy — show current artifact policies
func newBandwidthPolicyCmd(cfgRoot *string) *cobra.Command {
	return &cobra.Command{
		Use:   "policy",
		Short: "Show current artifact retention policies",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := loadConfig(*cfgRoot)
			if err != nil {
				return err
			}
			addr := bandwidthAddr(cfg.Bandwidth.ListenAddr)
			body, err := httpGet("http://" + addr + "/artifacts/policy")
			if err != nil {
				return fmt.Errorf("bandwidth service not reachable: %w", err)
			}
			var v any
			if err := json.Unmarshal([]byte(body), &v); err != nil {
				fmt.Println(body)
				return nil
			}
			out, _ := json.MarshalIndent(v, "", "  ")
			fmt.Println(string(out))
			return nil
		},
	}
}

func bandwidthAddr(addr string) string {
	if addr == "" {
		return "127.0.0.1:6062"
	}
	return addr
}

func bandwidthUpstream(cfg *config.Config) string {
	if cfg.Bandwidth.UpstreamGitLab != "" {
		return cfg.Bandwidth.UpstreamGitLab
	}
	return "http://" + cfg.GitLab.Domain
}
