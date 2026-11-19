# Support Bundles

Fork-Sync-All support bundles are sanitized, checksum-verified ZIP archives for
troubleshooting the control plane without tying diagnostics to a specific Git
provider. The same collector runs locally, in GitHub Actions, and in GitLab CI.

## Security model

- Collection is allowlist-based through `config/support-bundle.yml`.
- Secret values are never intentionally collected. Only the names of present
  secret variables are recorded.
- Every textual payload is redacted before it enters the archive.
- The manifest records every included file, size, and SHA-256 checksum.
- `inspect` rejects path traversal, missing files, and checksum mismatches.
- HTTPS delivery reads its bearer token only from
  `FSA_SUPPORT_UPLOAD_TOKEN`; tokens are never accepted as CLI arguments.
- GitHub and GitLab jobs are manual-only and retain artifacts for three days by
  default.

Always inspect the manifest and redaction report before sharing a bundle.

## CLI

Create the recommended standard bundle:

```bash
bash scripts/support-bundle.sh create --profile standard
```

Profiles:

- `minimal` — system versions, repository state, and CI context.
- `standard` — minimal plus validators, workflow inventory, and optional remote
  run metadata.
- `full` — standard plus explicitly allowlisted local log files.

Verify and inspect an archive:

```bash
bash scripts/support-bundle.sh inspect artifacts/support-bundles/<bundle>.zip
```

Copy it to a download directory:

```bash
bash scripts/support-bundle.sh send <bundle>.zip \
  --transport local --destination /safe/downloads/
```

Send it to a provider-neutral support endpoint:

```bash
export FSA_SUPPORT_UPLOAD_TOKEN='...'
bash scripts/support-bundle.sh send <bundle>.zip \
  --transport http --destination https://support.example/upload --method PUT
```

Plain HTTP is rejected by policy. The configured endpoint receives the ZIP as
the request body with `X-FSA-Bundle-ID` and `X-FSA-SHA256` headers.

## Git-platform downloads

- **GitHub:** run **Support Bundle** from Actions and download the resulting
  artifact.
- **GitLab:** start the manual `support-bundle` job and download its job
  artifact.
- **Gitea, Forgejo, Codeberg, or another CI:** run the same script, then publish
  `artifacts/support-bundles/*.zip*` using the platform's native artifact step.

Bundle creation is independent of delivery. Additional transports can be added
without changing collectors or the archive contract.

## FSA API

Authenticated routes:

```text
POST /api/fsa/support-bundles
GET  /api/fsa/support-bundles/:id
GET  /api/fsa/support-bundles/:id/download
POST /api/fsa/support-bundles/:id/send
```

The API confines local send destinations to the workspace. Generic CLI use can
copy to any destination explicitly chosen by the local operator. API-triggered
HTTP delivery is restricted to the server-side `FSA_SUPPORT_UPLOAD_URL`; callers
cannot supply an arbitrary upload host.
