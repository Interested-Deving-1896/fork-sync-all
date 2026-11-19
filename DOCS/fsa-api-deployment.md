# FSA-API Deployment

FSA-API is a shell-first HTTP control plane for fork-sync-all. It runs as a
persistent process on each FSA instance and exposes 29 routes across 8 domains
(workflows, repos, notifications, quota, chain, bdfs, security, deployments,
codebase, docs, toggles).

## Architecture

```
fsa-api/server/fsa-start.sh
  ├── merges UAA base routes + FSA-specific routes
  ├── applies toggle filtering (fsa-api/config/fsa-toggles.yml)
  └── delegates to backend:
       shell2http  — recommended for persistent deployment
       cgi         — Apache/nginx CGI mode
       webhook     — adnanh/webhook backend
```

## Deployment options

### Option A — GitHub Actions service (ephemeral, no host needed)

Use `fsa-api.yml` with `mode=serve` for smoke tests and one-off adapter calls.
Not suitable for persistent deployment — runner is recycled after the job.

### Option B — Ona environment service (recommended for source instance)

Add FSA-API as a long-running service in `.ona/automations.yaml`:

```yaml
services:
  fsa-api:
    name: FSA API
    description: FSA control-plane HTTP API on port 8090
    command: |
      export GH_TOKEN="${SYNC_TOKEN}"
      export FSA_AUTH="${FSA_AUTH_TOKEN}"
      export FSA_ORG="Interested-Deving-1896"
      export FSA_REPO="fork-sync-all"
      go install github.com/msoap/shell2http@latest 2>/dev/null
      export PATH="$HOME/go/bin:$PATH"
      exec fsa-api/server/fsa-start.sh --port 8090
    ready: curl -sf http://localhost:8090/health
```

Then expose port 8090 and set `fsa_api_url` in `config/fsa-deployments.yml`:

```yaml
- id: source
  fsa_api_url: 'https://<environment-id>.preview.gitpod.io'
```

### Option C — Self-hosted runner with systemd (for OSP/OOC mirrors)

On a self-hosted runner host:

```bash
# Install shell2http
go install github.com/msoap/shell2http@latest

# Clone fork-sync-all
git clone https://github.com/OpenOS-Project-OSP/fork-sync-all /opt/fsa

# Create systemd unit
cat > /etc/systemd/system/fsa-api.service << 'EOF'
[Unit]
Description=FSA API
After=network.target

[Service]
Type=simple
User=fsa
WorkingDirectory=/opt/fsa
Environment=GH_TOKEN=<token>
Environment=FSA_AUTH=<auth-token>
Environment=FSA_ORG=OpenOS-Project-OSP
Environment=FSA_REPO=fork-sync-all
Environment=PATH=/home/fsa/go/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/opt/fsa/fsa-api/server/fsa-start.sh --port 8090
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now fsa-api
```

## Deployment sequence

Deploy in chain order — source first, then mirrors:

1. **source** (`Interested-Deving-1896`) — Option B (Ona environment service)
2. **osp-github** (`OpenOS-Project-OSP`) — Option C (self-hosted runner) or Option A
3. **ooc-github** (`OpenOS-Project-Ecosystem-OOC`) — Option C
4. **osp-gitlab** (`openos-project/ops`) — Option C (GitLab runner)
5. **ooc-gitlab** (`openos-project-ooc-ecosystem/ops`) — Option C

After each deployment, update `fsa_api_url` in `config/fsa-deployments.yml`
and commit to main. The flush pipeline will propagate the update to all mirrors.

## Secrets required

| Secret | Used by | Purpose |
|---|---|---|
| `SYNC_TOKEN` | source, osp-github, ooc-github | GitHub PAT with repo+actions+workflow scopes |
| `GITLAB_TOKEN` | osp-gitlab, ooc-gitlab | GitLab PAT with api scope |
| `FSA_AUTH` | all | Bearer token for auth-gated routes (generate with `openssl rand -hex 32`) |

## Health check

```bash
curl -sf http://localhost:8090/health
curl -sf http://localhost:8090/api/fsa/quota
curl -sf http://localhost:8090/api/fsa/deployments
```

## Smoke test via fsa-api.yml

Before committing to a persistent deployment, validate the server boots:

```bash
gh workflow run fsa-api.yml --field mode=validate
gh workflow run fsa-api.yml --field mode=serve
```
