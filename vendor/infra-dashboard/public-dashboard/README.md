# public-dashboard

SPA mirror-health and package-search dashboard. Builds to static files deployable on GitHub Pages, GitLab Pages, or any static host.

## Before the first deploy

### 1. Set GitHub repo variables

In the repo that hosts this dashboard, go to **Settings → Secrets and variables → Actions → Variables** and add:

| Variable | Required | Description | Example |
|---|---|---|---|
| `VITE_APP_NAME` | No | Display name in browser tab and PWA install banner | `My Infra Dashboard` |
| `VITE_APP_DESCRIPTION` | No | PWA manifest description | `Infrastructure dashboard — ...` |
| `VITE_ENDPOINT_URL` | Yes | Base URL of the running API backend (no trailing slash) | `https://api.example.org/api` |
| `VITE_MIRRORLIST_OWNER` | Yes | GitHub org/user that owns the mirrorlist repo | `my-org` |
| `VITE_MIRRORLIST_REPO` | Yes | Repo name containing the mirrorlist file | `my-infra` |
| `VITE_MIRRORLIST_PATH` | No | Path to the mirrorlist file inside the repo | `mirrorlist/mirrorlist` |
| `VITE_PRIMARY_MIRROR_URL` | Yes | Base URL of the primary/authoritative mirror | `https://mirror.example.org/repo` |
| `VITE_MIRROR_REPO_PATHS` | Yes | Comma-separated `arch/repo` paths to check on each mirror | `x86_64/core,x86_64/extra` |

Variables with no default **must** be set or the relevant feature is disabled at runtime (mirrors page shows no data, health checks are skipped).

### 2. Enable GitHub Pages

Go to **Settings → Pages** and set **Source** to `GitHub Actions`. The `deploy-pages.yml` workflow handles the rest on every push to `main`.

### 3. PWA icons

`icon-192.png` and `icon-512.png` are present in `public/` (generated from `icon.svg`). Replace them before the first deploy if you want custom branding — they must be 192×192 and 512×512 PNG respectively.

### 4. GitLab Pages (optional)

If the repo is mirrored to GitLab, `.gitlab-ci.yml` deploys to GitLab Pages automatically. Set the same variables under **Settings → CI/CD → Variables** in the GitLab project.

---

## Local development

```bash
cp .env.example .env.local
# Fill in .env.local with your values
bun install
bun run dev        # http://localhost:3000
```

The API backend must be running for mirror health data:

```bash
cd ../api
MIRRORLIST_PATH=../mirrorlist/mirrorlist cargo run
# Listening on 0.0.0.0:5862
```

## Building

```bash
bun run build          # standard build (Docker / self-hosted)
bun run build:pages    # Pages build with relative base path (./)
```

Output goes to `dist/`.

## Environment variables

All `VITE_*` variables are baked in at build time. See `.env.example` for the full list.

| Variable | Default | Notes |
|---|---|---|
| `VITE_APP_NAME` | `Infra Dashboard` | Browser tab title and PWA install name |
| `VITE_APP_DESCRIPTION` | _(generic fallback)_ | PWA manifest description |
| `VITE_APP_VERSION` | `dev` | Injected into `<meta>`; CI sets this to the commit SHA |
| `VITE_ENDPOINT_URL` | `http://localhost:5862/api` | API backend base URL |
| `VITE_MIRRORLIST_OWNER` | _(empty)_ | Must be set for mirror health to work |
| `VITE_MIRRORLIST_REPO` | _(empty)_ | Must be set for mirror health to work |
| `VITE_MIRRORLIST_PATH` | `mirrorlist/mirrorlist` | Path within the mirrorlist repo |
| `VITE_PRIMARY_MIRROR_URL` | _(empty)_ | Must be set for lag calculation |
| `VITE_MIRROR_REPO_PATHS` | _(empty)_ | Must be set for per-repo health checks |

## Docker

`VITE_*` vars must be passed at **build time** since Vite bakes them in:

```bash
docker build \
  --build-arg VITE_ENDPOINT_URL=https://api.example.org/api \
  --build-arg VITE_MIRRORLIST_OWNER=my-org \
  --build-arg VITE_MIRRORLIST_REPO=my-infra \
  --build-arg VITE_PRIMARY_MIRROR_URL=https://mirror.example.org/repo \
  --build-arg VITE_MIRROR_REPO_PATHS=x86_64/core,x86_64/extra \
  -t public-dashboard .
docker run -p 3000:3000 public-dashboard
```
