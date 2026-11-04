# Token creation link profiles

Fork-Sync-All uses provider-specific token-creation links in Token Health Monitor
issues so maintainers can reach the correct creation form with reviewed settings
already filled in.

## Defaults and provider behavior

- Rotation guidance defaults to a **90-day** lifetime (three months), subject
  to provider and organization policy.
- GitHub fine-grained PAT templates support name, description, resource owner,
  permissions, and `expires_in=90`.
- GitHub classic PAT links prefill the classic Note and comma-separated scopes.
  The classic Note is limited to 40 characters. There is no documented classic
  URL parameter for expiry, so select 90 days manually on the form.
- GitLab uses its own PAT settings page and scope model. GitHub URL parameters
  must never be applied to GitLab tokens.

## Current GitHub profiles

| Secret/profile | Current type | Prefilled classic scopes | Fine-grained replacement |
|---|---|---|---|
| `SYNC_TOKEN` | Classic | `admin:org`, `admin:org_hook`, `admin:repo_hook`, `audit_log`, `delete:packages`, `delete_repo`, `gist`, `notifications`, `project`, `repo`, `workflow`, `write:packages` | Blocked pending permission/API parity audit |
| `GH_SYNC_TOKEN` | Classic | `admin:org`, `admin:org_hook`, `admin:public_key`, `admin:repo_hook`, `audit_log`, `gist`, `notifications`, `project`, `repo`, `workflow`, `write:discussion`, `write:packages` | Blocked pending permission/API parity audit |
| `ADD_MIRROR_REPO_SYNC` | Classic | `admin:repo_hook`, `read:org`, `repo`, `workflow` | Blocked pending repository-creation and organization-hook audit |
| `OSP_ADMIN_TOKEN` | Classic | `admin:org` | Blocked pending organization Actions-secret API audit; prefer GitHub App |
| `MIRROR_TOKEN` / `ORG_MIRROR_OSP_TO_OOC` | Classic | `admin:enterprise`, `admin:gpg_key`, `admin:org`, `admin:org_hook`, `admin:public_key`, `admin:repo_hook`, `admin:ssh_signing_key`, `project`, `repo`, `workflow` | Blocked pending broad mirror-consumer audit |
| `GITLAB_SYNC_TOKEN` | GitLab PAT | `api`, `read_repository`, `write_repository` | Not applicable |

These are the scopes currently documented for the tracked credentials, not a
recommendation to preserve broad access indefinitely. The next security task is
to inventory each token consumer and reduce scopes or migrate machine identities
to GitHub Apps where possible. Do not infer fine-grained parity from similar
permission names.

## Generator and tests

```bash
python3 scripts/token_creation_links.py --profile SYNC_TOKEN
python3 -m pytest tests/test_token_creation_links.py -v
```

The generator rejects unreviewed fine-grained profiles. A future profile may
set `fine_grained.status: supported` only after its API permission coverage,
resource owner, and repository access have been verified. It then emits a URL
with the exact audited permissions and a 90-day expiry.

## Safety

- URLs contain only public profile metadata, never credential values.
- Generating a link does not create, approve, store, rotate, or revoke a token.
- A human generates the credential, copies it securely, and submits it through
  the existing protected rotation workflow or provider-specific secret settings.
- Organization approval, SAML authorization, maximum-lifetime policies, and
  repository selection remain enforced by GitHub.
- Expiry values may remain unknown where a provider API does not expose them.

## Upstream references

- [GitHub documentation: managing personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) — documents fine-grained PAT URL parameters and the permission/resource-owner validation performed by GitHub.
- [GitHub Changelog, 2025-08-26: template URLs for fine-grained PATs](https://github.blog/changelog/2025-08-26-template-urls-for-fine-grained-pats-and-updated-permissions-ui/) — confirms URL templates for fine-grained PATs and the legacy classic PAT deep-link behavior.
