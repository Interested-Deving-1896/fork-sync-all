# Codex Cloud migration

Ona Cloud shuts down on October 31, 2026. Fork-Sync-All treats Ona as a
temporary compatibility surface and keeps its durable setup in the repository.
Ona environments do not migrate automatically; create and publish a separate
Codex Cloud environment.

## Create the environment

From ChatGPT on the web or in the desktop app, choose **Work in → Cloud →
Select environment → Create environment**, connect
`Interested-Deving-1896/fork-sync-all`, and let Codex inspect the repository.
New environments cannot currently be created from the mobile app, but a
published environment can be selected and used there.

Use this checked-in command as the environment's install script:

```bash
bash scripts/codex-cloud-install.sh
```

The script creates `.venv`, installs the pinned Python, mdBook, and shell2http
dependencies, installs optional security helpers, and validates the repository
contracts. Codex must provide Python 3, Go, and Rust/Cargo before running it;
the Dev Container declares the same runtimes for other compatible platforms.

## Start skill

Record the following instructions in the Codex Cloud **Start skill** field:

> Work from the repository root. Read `AGENTS.md` before changing files. Verify
> `.venv/bin/python`, `mdbook`, and `shell2http` exist. Run `bash
> scripts/tests/test-check-readme-render-mobile.sh` and `.venv/bin/python -m
> pytest -q` for broad validation. Start Documentation Preview, FSA API, or the
> project MCP server only when the task requires it; use the commands in
> `.ona/config.yaml` as a temporary reference, but do not depend on Ona APIs.
> Never run mutating org-wide scripts unless the task explicitly authorizes
> that external change.

## Credentials and network access

Do not copy secrets from an Ona environment or commit them to Git. Add fresh
values in the Codex Cloud environment:

- Environment variables for credentials that repository programs must read.
- Network secrets for credentials sent only to approved HTTPS services.
- The minimum outbound domains required for GitHub, GitLab, package managers,
  and explicitly requested integrations.

Rotate or revoke the expired Ona `GH_TOKEN` and `SYNC_TOKEN`. Validate new
credentials in Codex Cloud before enabling live audits or org-wide workflows.

## Publish and retire Ona

1. Review the prepared environment and its test results.
2. Save and publish the Codex Cloud environment.
3. Start a fresh cloud task and confirm the install and start instructions.
4. Commit or export all remaining Ona work, then stop the Ona environment.
5. Remove `.ona/config.yaml` only after the replacement workflows no longer
   need it as a migration reference.

The AI-agent badge registry remains provider-neutral; Codex Cloud is the
current hosted migration target, not an exclusive project requirement.
