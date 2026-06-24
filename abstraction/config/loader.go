// Package config provides layered configuration loading.
// Resolution order (later overrides earlier):
//  1. config/defaults.yaml — local-first defaults, committed
//  2. config/local.yaml — machine-specific overrides, gitignored
//  3. config/cloud.yaml — cloud overlays, applied only when cloud.enabled=true
//  4. Environment variables — GITLAB_ENHANCED_* prefix
package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// Config is the top-level configuration structure.
type Config struct {
	GitLab      GitLabConfig      `yaml:"gitlab"`
	Storage     StorageConfig     `yaml:"storage"`
	Build       BuildConfig       `yaml:"build"`
	Runner      RunnerConfig      `yaml:"runner"`
	LFS         LFSConfig         `yaml:"lfs"`
	IPFS        IPFSConfig        `yaml:"ipfs"`
	Environment EnvironmentConfig `yaml:"environment"`
	Cloud       CloudConfig       `yaml:"cloud"`
	Registry    RegistryConfig    `yaml:"registry"`
	Adblock     AdblockConfig     `yaml:"adblock"`
	Rewards     RewardsConfig     `yaml:"rewards"`
	Bandwidth   BandwidthConfig   `yaml:"bandwidth"`
}

type GitLabConfig struct {
	Domain        string `yaml:"domain"`
	Edition       string `yaml:"edition"` // ce | ee
	AdminEmail    string `yaml:"admin_email"`
	AdminPassword string `yaml:"admin_password"`
}

type StorageConfig struct {
	// Backend selects the storage implementation.
	// Values: local | chain | ipfs | cloud
	// "cloud" delegates to Provider below.
	Backend string `yaml:"backend"`

	// Path is the root directory for the local backend.
	Path string `yaml:"path"`

	// Provider selects the cloud storage provider when backend=cloud.
	// Values: aws | gcs | azure | minio | ceph | r2
	// All S3-compatible providers (minio, ceph, r2) use the S3 protocol
	// with a custom Endpoint.
	Provider string `yaml:"provider"`

	// Bucket / Container name (all providers).
	Bucket string `yaml:"bucket"`

	// Region is required for aws, optional for others.
	Region string `yaml:"region"`

	// Endpoint overrides the default service URL.
	// Required for minio, ceph, r2. Leave empty for aws/gcs/azure.
	Endpoint string `yaml:"endpoint"`

	// Credentials holds provider-specific authentication.
	// Leave empty to use the provider's default credential chain
	// (env vars, instance metadata, workload identity, etc.).
	Credentials StorageCredentials `yaml:"credentials"`
}

// StorageCredentials holds optional explicit credentials.
// Prefer environment variables or instance metadata over these fields.
type StorageCredentials struct {
	// AWS / S3-compatible
	AccessKeyID     string `yaml:"access_key_id"`
	SecretAccessKey string `yaml:"secret_access_key"`

	// GCS: path to service account JSON key file
	// Leave empty to use Application Default Credentials (ADC)
	GCSKeyFile string `yaml:"gcs_key_file"`

	// Azure: connection string or account+key
	// Leave empty to use DefaultAzureCredential (env / managed identity)
	AzureConnectionString string `yaml:"azure_connection_string"`
	AzureAccountName      string `yaml:"azure_account_name"`
	AzureAccountKey       string `yaml:"azure_account_key"`
}

type BuildConfig struct {
	Backend         string `yaml:"backend"` // incus | depot
	Socket          string `yaml:"socket"`
	CachePool       string `yaml:"cache_pool"`
	ProjectID       string `yaml:"project_id"`
	Token           string `yaml:"token"`
	BuildKitVersion string `yaml:"buildkit_version"`
}

type RunnerConfig struct {
	Backend          string `yaml:"backend"` // incus | blacksmith
	VMProfile        string `yaml:"vm_profile"`
	Concurrent       int    `yaml:"concurrent"`
	Org              string `yaml:"org"`
	Token            string `yaml:"token"`
	BlacksmithAPIURL string `yaml:"blacksmith_api_url"`
}

type LFSConfig struct {
	Server        string `yaml:"server"` // rudolfs | giftless | lfs-test-server
	Backend       string `yaml:"backend"`
	Path          string `yaml:"path"`
	Encryption    bool   `yaml:"encryption"`
	EncryptionKey string `yaml:"encryption_key"` // set via GITLAB_ENHANCED_LFS_ENCRYPTION_KEY

	// bdfs / btr-fs-git storage lifecycle fields.

	// BdfsSnapshotOnServe controls whether a bfg local_commit is taken
	// before the LFS server starts. Requires bfg in PATH and lfs.path to be
	// a BTRFS subvolume. Set via GITLAB_ENHANCED_LFS_BDFS_SNAPSHOT_ON_SERVE.
	BdfsSnapshotOnServe bool `yaml:"bdfs_snapshot_on_serve"`

	// BdfsPruneKeep is the number of LFS store snapshots to retain after
	// lfs serve exits. 0 disables post-serve pruning.
	// Set via GITLAB_ENHANCED_LFS_BDFS_PRUNE_KEEP.
	BdfsPruneKeep int `yaml:"bdfs_prune_keep"`

	// BdfsPrunePattern is passed to bdfs snapshot prune --pattern.
	// Empty string matches all snapshots under lfs.path.
	// Set via GITLAB_ENHANCED_LFS_BDFS_PRUNE_PATTERN.
	BdfsPrunePattern string `yaml:"bdfs_prune_pattern"`

	// BdfsCompression is the algorithm used for bdfs demote and prune
	// --demote-first. Valid values: zstd | lzma | lz4 | brotli | none.
	// Defaults to "zstd". Set via GITLAB_ENHANCED_LFS_BDFS_COMPRESSION.
	BdfsCompression string `yaml:"bdfs_compression"`

	// BdfsDemoteOnShutdown, when true, calls bdfs demote on the LFS store
	// after the server exits, compressing it to a DwarFS image alongside the
	// subvolume. Intended for setups that want the store archived after every
	// serve session. Requires bdfs in PATH.
	// Set via GITLAB_ENHANCED_LFS_BDFS_DEMOTE_ON_SHUTDOWN.
	BdfsDemoteOnShutdown bool `yaml:"bdfs_demote_on_shutdown"`
}

type IPFSConfig struct {
	Enabled bool   `yaml:"enabled"`
	Node    string `yaml:"node"`
	Gateway string `yaml:"gateway"`

	// DwarfsPin configures IPFS pinning of DwarFS archives produced by
	// bdfs demote (artifact eviction and LFS store demote).
	DwarfsPin DwarfsPinConfig `yaml:"dwarfs_pin"`
}

// DwarfsPinConfig controls automatic IPFS pinning of .dwarfs archives.
type DwarfsPinConfig struct {
	// Enabled must be true for pinning to occur. Requires ipfs.enabled=true.
	// Set via GITLAB_ENHANCED_IPFS_DWARFS_PIN_ENABLED.
	Enabled bool `yaml:"enabled"`

	// ChunkSizeKB is the CAR chunk size in KiB used when streaming archives
	// to the Kubo dag/import endpoint. Defaults to 256 KiB.
	// Set via GITLAB_ENHANCED_IPFS_DWARFS_PIN_CHUNK_SIZE_KB.
	ChunkSizeKB int `yaml:"chunk_size_kb"`

	// IndexPath is the SQLite file recording path→CID mappings.
	// Defaults to /var/lib/gitlab-enhanced/dwarfs-pin.db.
	// Set via GITLAB_ENHANCED_IPFS_DWARFS_PIN_INDEX_PATH.
	IndexPath string `yaml:"index_path"`
}

type EnvironmentConfig struct {
	Backend        string `yaml:"backend"` // incus | gitpod-k8s | ona
	WorkspaceImage string `yaml:"workspace_image"`
	IDE            string `yaml:"ide"`
	IDEPort        int    `yaml:"ide_port"`
	Network        string `yaml:"network"`
	Token          string `yaml:"token"`
	// GitpodDomain is the hostname of the Gitpod Classic installation.
	// Gitpod runs on its own subdomain (e.g. gitpod.gitlab.local), separate
	// from the GitLab domain. Only used when backend = "gitpod-k8s".
	GitpodDomain string `yaml:"gitpod_domain"`

	// bdfs / btr-fs-git workspace snapshot fields.
	// The workspace subvolume must be a BTRFS subvolume for these to have effect.

	// BdfsSnapshotOnPause, when true, calls bfg local_commit on the workspace
	// subvolume when the workspace is paused. Requires bfg in PATH.
	// Set via GITLAB_ENHANCED_ENVIRONMENT_BDFS_SNAPSHOT_ON_PAUSE.
	BdfsSnapshotOnPause bool `yaml:"bdfs_snapshot_on_pause"`

	// BdfsDemoteOnDelete, when true, calls bdfs demote on the workspace
	// subvolume when the workspace is deleted, compressing it to a DwarFS
	// archive. Requires bdfs in PATH.
	// Set via GITLAB_ENHANCED_ENVIRONMENT_BDFS_DEMOTE_ON_DELETE.
	BdfsDemoteOnDelete bool `yaml:"bdfs_demote_on_delete"`

	// BdfsPruneKeep is the number of workspace snapshots to retain after each
	// pause snapshot. 0 disables pruning.
	// Set via GITLAB_ENHANCED_ENVIRONMENT_BDFS_PRUNE_KEEP.
	BdfsPruneKeep int `yaml:"bdfs_prune_keep"`

	// BdfsCompression is the algorithm used for bdfs demote and snapshot prune.
	// Valid values: zstd | lzma | lz4 | brotli | none. Defaults to "zstd".
	// Set via GITLAB_ENHANCED_ENVIRONMENT_BDFS_COMPRESSION.
	BdfsCompression string `yaml:"bdfs_compression"`

	// DwarfsPinEnabled, when true, pins the DwarFS archive produced by
	// BdfsDemoteOnDelete to IPFS via the Kubo node at DwarfsPinKuboAPI.
	// Requires ipfs.enabled=true.
	// Set via GITLAB_ENHANCED_ENVIRONMENT_DWARFS_PIN_ENABLED.
	DwarfsPinEnabled bool `yaml:"dwarfs_pin_enabled"`

	// DwarfsPinKuboAPI is the base URL of the Kubo HTTP RPC API used for
	// workspace archive pinning (e.g. http://127.0.0.1:5001).
	// Set via GITLAB_ENHANCED_ENVIRONMENT_DWARFS_PIN_KUBO_API.
	DwarfsPinKuboAPI string `yaml:"dwarfs_pin_kubo_api"`

	// DwarfsPinIndexPath is the SQLite file recording workspace archive CIDs.
	// Defaults to /var/lib/gitlab-enhanced/workspace-dwarfs-pin.db.
	// Set via GITLAB_ENHANCED_ENVIRONMENT_DWARFS_PIN_INDEX_PATH.
	DwarfsPinIndexPath string `yaml:"dwarfs_pin_index_path"`
}

type CloudConfig struct {
	Enabled  bool   `yaml:"enabled"`
	Provider string `yaml:"provider"` // aws | gcp | azure
}

type RegistryConfig struct {
	Backend string `yaml:"backend"`
	URL     string `yaml:"url"`
}

// AdblockConfig controls the adblock-proxy sidecar.
type AdblockConfig struct {
	// Enabled controls whether adblock-proxy is started by `gitlab-enhanced up`.
	Enabled bool `yaml:"enabled"`
	// ListenAddr is the address adblock-proxy binds to.
	ListenAddr string `yaml:"listen_addr"`
	// ListsDir is the directory containing EasyList-format .txt filter lists.
	ListsDir string `yaml:"lists_dir"`
	// FilterCI enables URL filtering for outbound CI job network requests.
	FilterCI bool `yaml:"filter_ci"`
	// FilterWorkspaces enables URL filtering for workspace container traffic.
	FilterWorkspaces bool `yaml:"filter_workspaces"`
}

// RewardsConfig controls the opt-in BAT rewards service.
type RewardsConfig struct {
	// Enabled must be explicitly set to true to activate the rewards service.
	// Nothing calls the BAT/Ethereum APIs unless this is true.
	Enabled bool `yaml:"enabled"`

	// PublisherID is the Brave publisher verification ID for this GitLab instance.
	PublisherID string `yaml:"publisher_id"`

	// WalletAddress is the ERC-20 wallet address that receives BAT contributions.
	WalletAddress string `yaml:"wallet_address"`

	// UpholdClientID and UpholdClientSecret are for Uphold custodial wallet API.
	// Leave empty to use non-custodial on-chain transfers only.
	UpholdClientID     string `yaml:"uphold_client_id"`
	UpholdClientSecret string `yaml:"uphold_client_secret"`

	// MinPayoutBAT is the minimum BAT balance before an automatic payout is triggered.
	MinPayoutBAT float64 `yaml:"min_payout_bat"`

	// ListenAddr is the address the rewards HTTP service binds to.
	ListenAddr string `yaml:"listen_addr"`

	// WebhookSecret is the token configured in GitLab Admin > System Hooks.
	// Set via GITLAB_ENHANCED_REWARDS_WEBHOOK_SECRET.
	WebhookSecret string `yaml:"webhook_secret"`

	// DBPath is the SQLite database file path for rewards persistence.
	// Defaults to /var/lib/gitlab-enhanced/rewards.db
	DBPath string `yaml:"db_path"`

	// BandwidthAddr is the address of the bandwidth service for artifact registration.
	BandwidthAddr string `yaml:"bandwidth_addr"`

	// Non-custodial ERC-20 payout configuration.
	// Used when uphold_client_id is empty.
	// EthRPCURL is the Ethereum JSON-RPC endpoint (Infura, Alchemy, local geth).
	EthRPCURL string `yaml:"eth_rpc_url"`

	// EthPrivateKey is the hex-encoded secp256k1 private key of the publisher wallet.
	// Always set via GITLAB_ENHANCED_REWARDS_ETH_PRIVATE_KEY — never commit to YAML.
	EthPrivateKey string `yaml:"eth_private_key"`

	// EthChainID is the Ethereum chain ID (1=mainnet, 11155111=Sepolia). Defaults to 1.
	EthChainID int64 `yaml:"eth_chain_id"`
}

// BandwidthConfig controls the server-side bandwidth management service.
type BandwidthConfig struct {
	// Enabled controls whether the bandwidth manager is active.
	Enabled bool `yaml:"enabled"`

	// ListenAddr is the address the bandwidth proxy binds to.
	ListenAddr string `yaml:"listen_addr"`

	// UpstreamGitLab is the URL of the GitLab instance to proxy to.
	// Defaults to http://<gitlab.domain> when empty.
	UpstreamGitLab string `yaml:"upstream_gitlab"`

	// CompressionLevel sets gzip compression level (1-9, 0=disabled).
	CompressionLevel int `yaml:"compression_level"`

	// LFSDedupEnabled enables content-addressed deduplication for LFS objects.
	LFSDedupEnabled bool `yaml:"lfs_dedup_enabled"`

	// ArtifactMaxSizeMB is the maximum size for a single CI artifact in MB (0=unlimited).
	ArtifactMaxSizeMB int `yaml:"artifact_max_size_mb"`

	// ArtifactRetentionDays is how long CI artifacts are kept before deletion (0=forever).
	ArtifactRetentionDays int `yaml:"artifact_retention_days"`

	// CacheMaxSizeGB is the maximum total size of the CI cache in GB (0=unlimited).
	CacheMaxSizeGB int `yaml:"cache_max_size_gb"`

	// DBPath is the SQLite database file path for artifact persistence.
	// Defaults to /var/lib/gitlab-enhanced/bandwidth.db
	DBPath string `yaml:"db_path"`

	// BdfsArchiveDir, when non-empty, causes evicted artifacts to be compressed
	// into DwarFS images in this directory rather than being permanently deleted.
	// Requires bdfs to be installed on the host; falls back to plain deletion
	// when bdfs is absent or the demote operation fails.
	// Set via GITLAB_ENHANCED_BANDWIDTH_BDFS_ARCHIVE_DIR.
	BdfsArchiveDir string `yaml:"bdfs_archive_dir"`

	// DwarfsPinEnabled, when true, pins each .dwarfs archive produced by
	// artifact eviction to IPFS via the Kubo node at DwarfsPinKuboAPI.
	// Set via GITLAB_ENHANCED_BANDWIDTH_DWARFS_PIN_ENABLED.
	DwarfsPinEnabled bool `yaml:"dwarfs_pin_enabled"`

	// DwarfsPinKuboAPI is the base URL of the Kubo HTTP RPC API
	// (e.g. http://127.0.0.1:5001).
	// Set via GITLAB_ENHANCED_BANDWIDTH_DWARFS_PIN_KUBO_API.
	DwarfsPinKuboAPI string `yaml:"dwarfs_pin_kubo_api"`

	// DwarfsPinChunkSizeKB is the CAR chunk size in KiB. Defaults to 256 KiB.
	// Set via GITLAB_ENHANCED_BANDWIDTH_DWARFS_PIN_CHUNK_SIZE_KB.
	DwarfsPinChunkSizeKB int `yaml:"dwarfs_pin_chunk_size_kb"`

	// DwarfsPinIndexPath is the SQLite file recording path→CID mappings.
	// Defaults to /var/lib/gitlab-enhanced/dwarfs-pin.db.
	// Set via GITLAB_ENHANCED_BANDWIDTH_DWARFS_PIN_INDEX_PATH.
	DwarfsPinIndexPath string `yaml:"dwarfs_pin_index_path"`
}

// Load reads and merges configuration from the standard locations.
// root is the repository root directory.
func Load(root string) (*Config, error) {
	cfg := &Config{}
	layers := []string{
		filepath.Join(root, "config", "defaults.yaml"),
		filepath.Join(root, "config", "local.yaml"),
	}
	for _, path := range layers {
		if err := mergeFile(cfg, path); err != nil {
			return nil, fmt.Errorf("loading %s: %w", path, err)
		}
	}
	// Apply cloud overlay only when enabled
	if cfg.Cloud.Enabled {
		cloudPath := filepath.Join(root, "config", "cloud.yaml")
		if err := mergeFile(cfg, cloudPath); err != nil {
			return nil, fmt.Errorf("loading cloud config: %w", err)
		}
	}
	applyEnvOverrides(cfg)
	return cfg, nil
}

// mergeFile reads a YAML file into cfg. Missing files are silently skipped.
func mergeFile(cfg *Config, path string) error {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	// Expand environment variables in values
	data = []byte(os.ExpandEnv(string(data)))
	return yaml.Unmarshal(data, cfg)
}

// applyEnvOverrides maps GITLAB_ENHANCED_* environment variables onto cfg.
// Format: GITLAB_ENHANCED_STORAGE_BACKEND → cfg.Storage.Backend
func applyEnvOverrides(cfg *Config) {
	// String overrides
	for env, field := range map[string]*string{
		// Core
		"GITLAB_ENHANCED_GITLAB_DOMAIN":         &cfg.GitLab.Domain,
		"GITLAB_ENHANCED_GITLAB_ADMIN_EMAIL":     &cfg.GitLab.AdminEmail,
		"GITLAB_ENHANCED_GITLAB_ADMIN_PASSWORD":  &cfg.GitLab.AdminPassword,
		"GITLAB_ENHANCED_STORAGE_BACKEND":        &cfg.Storage.Backend,
		"GITLAB_ENHANCED_STORAGE_PATH":           &cfg.Storage.Path,
		"GITLAB_ENHANCED_BUILD_BACKEND":          &cfg.Build.Backend,
		"GITLAB_ENHANCED_BUILD_BUILDKIT_VERSION": &cfg.Build.BuildKitVersion,
		"GITLAB_ENHANCED_RUNNER_BACKEND":         &cfg.Runner.Backend,
		"GITLAB_ENHANCED_RUNNER_BLACKSMITH_API_URL": &cfg.Runner.BlacksmithAPIURL,
		"GITLAB_ENHANCED_LFS_SERVER":              &cfg.LFS.Server,
		"GITLAB_ENHANCED_LFS_BACKEND":             &cfg.LFS.Backend,
		"GITLAB_ENHANCED_LFS_ENCRYPTION_KEY":      &cfg.LFS.EncryptionKey,
		"GITLAB_ENHANCED_LFS_BDFS_PRUNE_PATTERN":          &cfg.LFS.BdfsPrunePattern,
		"GITLAB_ENHANCED_LFS_BDFS_COMPRESSION":            &cfg.LFS.BdfsCompression,
		"GITLAB_ENHANCED_IPFS_DWARFS_PIN_INDEX_PATH":      &cfg.IPFS.DwarfsPin.IndexPath,
		"GITLAB_ENHANCED_BANDWIDTH_DWARFS_PIN_KUBO_API":   &cfg.Bandwidth.DwarfsPinKuboAPI,
		"GITLAB_ENHANCED_BANDWIDTH_DWARFS_PIN_INDEX_PATH": &cfg.Bandwidth.DwarfsPinIndexPath,
		"GITLAB_ENHANCED_ENVIRONMENT_BACKEND":                    &cfg.Environment.Backend,
		"GITLAB_ENHANCED_ENVIRONMENT_BDFS_COMPRESSION":           &cfg.Environment.BdfsCompression,
		"GITLAB_ENHANCED_ENVIRONMENT_DWARFS_PIN_KUBO_API":        &cfg.Environment.DwarfsPinKuboAPI,
		"GITLAB_ENHANCED_ENVIRONMENT_DWARFS_PIN_INDEX_PATH":      &cfg.Environment.DwarfsPinIndexPath,
		"GITLAB_ENHANCED_CLOUD_PROVIDER":                         &cfg.Cloud.Provider,
		// Adblock
		"GITLAB_ENHANCED_ADBLOCK_LISTEN_ADDR": &cfg.Adblock.ListenAddr,
		"GITLAB_ENHANCED_ADBLOCK_LISTS_DIR":   &cfg.Adblock.ListsDir,
		// Rewards
		"GITLAB_ENHANCED_REWARDS_PUBLISHER_ID":       &cfg.Rewards.PublisherID,
		"GITLAB_ENHANCED_REWARDS_WALLET_ADDRESS":      &cfg.Rewards.WalletAddress,
		"GITLAB_ENHANCED_REWARDS_UPHOLD_CLIENT_ID":    &cfg.Rewards.UpholdClientID,
		"GITLAB_ENHANCED_REWARDS_UPHOLD_CLIENT_SECRET": &cfg.Rewards.UpholdClientSecret,
		"GITLAB_ENHANCED_REWARDS_LISTEN_ADDR":         &cfg.Rewards.ListenAddr,
		"GITLAB_ENHANCED_REWARDS_WEBHOOK_SECRET":      &cfg.Rewards.WebhookSecret,
		"GITLAB_ENHANCED_REWARDS_DB_PATH":             &cfg.Rewards.DBPath,
		"GITLAB_ENHANCED_REWARDS_BANDWIDTH_ADDR":      &cfg.Rewards.BandwidthAddr,
		"GITLAB_ENHANCED_REWARDS_ETH_RPC_URL":         &cfg.Rewards.EthRPCURL,
		"GITLAB_ENHANCED_REWARDS_ETH_PRIVATE_KEY":     &cfg.Rewards.EthPrivateKey,
		// Bandwidth
		"GITLAB_ENHANCED_BANDWIDTH_LISTEN_ADDR":       &cfg.Bandwidth.ListenAddr,
		"GITLAB_ENHANCED_BANDWIDTH_UPSTREAM_GITLAB":   &cfg.Bandwidth.UpstreamGitLab,
		"GITLAB_ENHANCED_BANDWIDTH_DB_PATH":           &cfg.Bandwidth.DBPath,
		"GITLAB_ENHANCED_BANDWIDTH_BDFS_ARCHIVE_DIR":  &cfg.Bandwidth.BdfsArchiveDir,
	} {
		if v := os.Getenv(env); v != "" {
			*field = v
		}
	}

	// Boolean overrides
	for _, pair := range []struct {
		env   string
		field *bool
	}{
		{"GITLAB_ENHANCED_CLOUD_ENABLED", &cfg.Cloud.Enabled},
		{"GITLAB_ENHANCED_IPFS_ENABLED", &cfg.IPFS.Enabled},
		{"GITLAB_ENHANCED_ADBLOCK_ENABLED", &cfg.Adblock.Enabled},
		{"GITLAB_ENHANCED_ADBLOCK_FILTER_CI", &cfg.Adblock.FilterCI},
		{"GITLAB_ENHANCED_ADBLOCK_FILTER_WORKSPACES", &cfg.Adblock.FilterWorkspaces},
		{"GITLAB_ENHANCED_REWARDS_ENABLED", &cfg.Rewards.Enabled},
		{"GITLAB_ENHANCED_BANDWIDTH_ENABLED", &cfg.Bandwidth.Enabled},
		{"GITLAB_ENHANCED_BANDWIDTH_LFS_DEDUP_ENABLED", &cfg.Bandwidth.LFSDedupEnabled},
		{"GITLAB_ENHANCED_LFS_ENCRYPTION", &cfg.LFS.Encryption},
		{"GITLAB_ENHANCED_LFS_BDFS_SNAPSHOT_ON_SERVE", &cfg.LFS.BdfsSnapshotOnServe},
		{"GITLAB_ENHANCED_LFS_BDFS_DEMOTE_ON_SHUTDOWN", &cfg.LFS.BdfsDemoteOnShutdown},
		{"GITLAB_ENHANCED_IPFS_DWARFS_PIN_ENABLED", &cfg.IPFS.DwarfsPin.Enabled},
		{"GITLAB_ENHANCED_BANDWIDTH_DWARFS_PIN_ENABLED", &cfg.Bandwidth.DwarfsPinEnabled},
		{"GITLAB_ENHANCED_ENVIRONMENT_BDFS_SNAPSHOT_ON_PAUSE", &cfg.Environment.BdfsSnapshotOnPause},
		{"GITLAB_ENHANCED_ENVIRONMENT_BDFS_DEMOTE_ON_DELETE", &cfg.Environment.BdfsDemoteOnDelete},
		{"GITLAB_ENHANCED_ENVIRONMENT_DWARFS_PIN_ENABLED", &cfg.Environment.DwarfsPinEnabled},
	} {
		if v := strings.ToLower(os.Getenv(pair.env)); v == "true" || v == "1" {
			*pair.field = true
		}
	}

	// Integer overrides
	for _, pair := range []struct {
		env   string
		field *int
	}{
		{"GITLAB_ENHANCED_RUNNER_CONCURRENT", &cfg.Runner.Concurrent},
		{"GITLAB_ENHANCED_ENVIRONMENT_IDE_PORT", &cfg.Environment.IDEPort},
		{"GITLAB_ENHANCED_BANDWIDTH_COMPRESSION_LEVEL", &cfg.Bandwidth.CompressionLevel},
		{"GITLAB_ENHANCED_BANDWIDTH_ARTIFACT_MAX_SIZE_MB", &cfg.Bandwidth.ArtifactMaxSizeMB},
		{"GITLAB_ENHANCED_BANDWIDTH_ARTIFACT_RETENTION_DAYS", &cfg.Bandwidth.ArtifactRetentionDays},
		{"GITLAB_ENHANCED_BANDWIDTH_CACHE_MAX_SIZE_GB", &cfg.Bandwidth.CacheMaxSizeGB},
		{"GITLAB_ENHANCED_LFS_BDFS_PRUNE_KEEP", &cfg.LFS.BdfsPruneKeep},
		{"GITLAB_ENHANCED_IPFS_DWARFS_PIN_CHUNK_SIZE_KB", &cfg.IPFS.DwarfsPin.ChunkSizeKB},
		{"GITLAB_ENHANCED_BANDWIDTH_DWARFS_PIN_CHUNK_SIZE_KB", &cfg.Bandwidth.DwarfsPinChunkSizeKB},
		{"GITLAB_ENHANCED_ENVIRONMENT_BDFS_PRUNE_KEEP", &cfg.Environment.BdfsPruneKeep},
	} {
		if v := os.Getenv(pair.env); v != "" {
			var n int
			if _, err := fmt.Sscanf(v, "%d", &n); err == nil {
				*pair.field = n
			}
		}
	}

	// int64 overrides
	if v := os.Getenv("GITLAB_ENHANCED_REWARDS_ETH_CHAIN_ID"); v != "" {
		var n int64
		if _, err := fmt.Sscanf(v, "%d", &n); err == nil {
			cfg.Rewards.EthChainID = n
		}
	}

	// Float overrides
	for _, pair := range []struct {
		env   string
		field *float64
	}{
		{"GITLAB_ENHANCED_REWARDS_MIN_PAYOUT_BAT", &cfg.Rewards.MinPayoutBAT},
	} {
		if v := os.Getenv(pair.env); v != "" {
			var f float64
			if _, err := fmt.Sscanf(v, "%f", &f); err == nil {
				*pair.field = f
			}
		}
	}
}
