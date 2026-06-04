package main

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

// Our github mirrorlist endpoint
const GITHUB_MIRRORLIST = "https://raw.githubusercontent.com/CachyOS/CachyOS-PKGBUILDS/refs/heads/master/cachyos-mirrorlist/cachyos-mirrorlist"

// Config used for application "options"
type Config struct {
	ListenAddr      string
	UpstreamURL     *url.URL
	RefreshInterval time.Duration
	RequestTimeout  time.Duration
	PathMappings    map[string]string
}

// Proxy core caching proxy server
type Proxy struct {
	config     *Config
	httpClient *http.Client
	cacheData  map[string][]byte
	cacheMutex sync.RWMutex
}

// NewProxy initializes a new Proxy instance
func NewProxy(cfg *Config) *Proxy {
	return &Proxy{
		config:     cfg,
		httpClient: &http.Client{Timeout: cfg.RequestTimeout},
		cacheData:  make(map[string][]byte),
		cacheMutex: sync.RWMutex{},
	}
}

// startBackgroundRefresher updates the cache
func (p *Proxy) startBackgroundRefresher() {
	log.Println("Background refresher started.")

	// refreshes cache at the specified refresh interval
	ticker := time.NewTicker(p.config.RefreshInterval)
	defer ticker.Stop()

	// perform cache init
	p.refreshAllEndpoints()

	for range ticker.C {
		log.Println("Refreshing all endpoints...")
		p.refreshAllEndpoints()
	}
}

// refreshAllEndpoints iterates through proxied endpoints and fetches fresh data for each
func (p *Proxy) refreshAllEndpoints() {
	for proxyPath, upstreamPath := range p.config.PathMappings {
		log.Printf("Refreshing data for %s", proxyPath)
		data, err := p.fetchFromUpstream(upstreamPath)
		if err != nil {
			// keep the old cache for the endpoint
			log.Printf("ERROR: Failed to refresh %s: %v. Keeping stale data.", proxyPath, err)
			continue
		}

		p.cacheMutex.Lock()
		p.cacheData[proxyPath] = data
		p.cacheMutex.Unlock()

		log.Printf("Successfully refreshed and cached data for %s", proxyPath)
	}
}

// ServeHTTP very simple handler for all incoming requests
func (p *Proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// reject unsupported endpoints
	if _, ok := p.config.PathMappings[r.URL.Path]; !ok {
		http.NotFound(w, r)
		return
	}

	// let's use the requested path as the cache key..
	cacheKey := r.URL.Path

	// protect at least with read lock.
	p.cacheMutex.RLock()
	cachedData, found := p.cacheData[cacheKey]
	p.cacheMutex.RUnlock()

	// should be only at startup
	if !found {
		log.Printf("Cache MISS for %s (service starting up).", cacheKey)
		http.Error(w, "Service Initializing: Data not yet available.", http.StatusServiceUnavailable)
		return
	}

	// hardcoding content-type based on the endpoint
	contentType := "application/json"
	if strings.Contains(r.URL.Path, "mirrorlist") {
		contentType = "text/plain; charset=utf-8"
	}

	w.Header().Set("Content-Type", contentType)
	w.Write(cachedData)
}

func (p *Proxy) fetchFromUpstream(upstreamPath string) ([]byte, error) {
	var targetURL url.URL

	// NOTE: much hacky just to handle hardcoded mirrorlist :/
	parsedPath, err := url.Parse(upstreamPath)
	if err == nil && parsedPath.IsAbs() {
		targetURL = *parsedPath
	} else {
		targetURL = *p.config.UpstreamURL
		targetURL.Path = upstreamPath
	}

	req, err := http.NewRequest(http.MethodGet, targetURL.String(), nil)
	if err != nil {
		return nil, fmt.Errorf("could not create upstream request: %w", err)
	}

	req.Header.Set("Accept", "application/json, text/plain")
	req.Header.Set("User-Agent", "CachyOSMirrorlistProxy/1.0")

	resp, err := p.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("upstream request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("upstream returned non-200 status: %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("could not read upstream response body: %w", err)
	}
	return body, nil
}

func main() {
	upstream, err := url.Parse(getEnv("UPSTREAM_URL", "https://archlinux.org"))
	if err != nil {
		log.Fatalf("Invalid UPSTREAM_URL: %v", err)
	}

	pathMappings := map[string]string{
		"/status":             "/mirrors/status/json/",
		"/tier1":              "/mirrors/status/tier/1/json/",
		"/cachyos-mirrorlist": GITHUB_MIRRORLIST,
	}

	appPort := getEnv("PORT", "8080")
	config := &Config{
		ListenAddr:      fmt.Sprintf(":%s", appPort),
		UpstreamURL:     upstream,
		RefreshInterval: getEnvDurationFromString("REFRESH_INTERVAL", "5m"),
		RequestTimeout:  getEnvDurationFromString("REQUEST_TIMEOUT", "30m"),
		PathMappings:    pathMappings,
	}

	log.Println("Starting Caching Proxy with Background Refresh...")
	log.Printf(" ==> Listening on: %s", config.ListenAddr)
	log.Printf(" ==> Proxying from: %s", config.UpstreamURL)
	log.Printf(" ==> Path Mappings:")
	for proxyPath, upstreamPath := range config.PathMappings {
		log.Printf("     %s -> %s", proxyPath, upstreamPath)
	}
	log.Printf(" ==> Background Refresh Interval: %v", config.RefreshInterval)
	log.Printf(" ==> Upstream Request Timeout: %v", config.RequestTimeout)

	proxy := NewProxy(config)

	// Launch the background cache refresher as a separate goroutine.
	go proxy.startBackgroundRefresher()

	server := &http.Server{
		Addr:    config.ListenAddr,
		Handler: proxy,
	}

	if err := server.ListenAndServe(); err != nil {
		log.Fatalf("Failed to start server: %v", err)
	}
}

func getEnv(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok {
		return value
	}
	return fallback
}

func getEnvDurationFromString(key, fallback string) time.Duration {
	valStr := getEnv(key, fallback)
	d, err := time.ParseDuration(valStr)
	if err != nil {
		log.Printf("Warning: could not parse duration string for %s ('%s'). Using fallback '%s'.", key, valStr, fallback)
		d, _ = time.ParseDuration(fallback)
	}
	return d
}
