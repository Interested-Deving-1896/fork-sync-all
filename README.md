[update-readmes]   Mode: rewrite — migrating to template structure...
# fork-sync-all

<!-- AI:start:what-it-does -->
This project automates the daily synchronization of forked repositories with their upstream sources to ensure they remain up-to-date. It is used by developers and organizations managing multiple forks to streamline updates, reduce manual effort, and maintain consistency across repositories.
<!-- AI:end:what-it-does -->

## Architecture

<!-- AI:start:architecture -->
The project automates daily synchronization of forked repositories with their upstream sources using shell scripts and CI workflows. It consists of shell scripts and YAML-based workflows that define the synchronization logic. The `.github` and `.gitlab` directories contain CI/CD configurations for GitHub Actions and GitLab CI, respectively. The `scripts` directory holds reusable shell scripts for syncing operations. Workflows interact with these scripts to perform tasks such as rebasing, resolving conflicts, and updating mirrors. The `.devcontainer` directory provides a development environment configuration.

Directory structure:
```plaintext
.
├── .devcontainer/         # Development container configuration
├── .github/               # GitHub Actions workflows
├── .gitlab/               # GitLab CI configuration
├── scripts/               # Shell scripts for sync operations
├── .gitignore             # Git ignore rules
├── .gitlab-ci.yml         # GitLab CI pipeline definition
├── README.md              # Project documentation
```
<!-- AI:end:architecture -->

## Install

<!-- Add installation instructions here. This section is yours — the AI will not modify it. -->

```bash
git clone https://github.com/Interested-Deving-1896/fork-sync-all.git
cd fork-sync-all
```

## Usage

<!-- Add usage examples here. This section is yours — the AI will not modify it. -->

## Configuration

<!-- Document configuration options here. This section is yours — the AI will not modify it. -->

## CI

<!-- AI:start:ci -->
The repository uses GitHub Actions for continuous integration and automation. Below are the workflows and their purposes:

- **add-mirror-repo.yml**: Adds new repositories to the mirror list. No secrets required.
- **mirror-artifacts.yml**: Syncs build artifacts between repositories. Requires `ARTIFACTS_TOKEN`.
- **mirror-to-osp.yml**: Mirrors repositories to an Open Source Program (OSP) instance. Requires `OSP_API_KEY`.
- **rebase-lts.yml**: Rebases long-term support branches with upstream changes. No secrets required.
- **reconcile-org-refs.yml**: Updates organization-level references to match upstream. No secrets required.
- **resolve-failures.yml**: Identifies and resolves sync failures. Requires `FAILURE_LOGS_TOKEN`.
- **setup-osp-mirrors.yml**: Configures mirrors for OSP repositories. Requires `OSP_API_KEY`.
- **sync-eggs-docs-to-book.yml**: Syncs documentation from "eggs" repositories to a central book. No secrets required.
- **sync-forks.yml**: Synchronizes all forked repositories with their upstream sources. Requires `GITHUB_TOKEN`.
- **sync-pieroproietti-forks.yml**: Syncs forks owned by the user "pieroproietti". Requires `GITHUB_TOKEN`.
- **upstream-prs.yml**: Creates pull requests for upstream changes. Requires `GITHUB_TOKEN`.

Secrets must be configured in the repository settings for workflows that require them.
<!-- AI:end:ci -->

## Mirror chain

<!-- AI:start:mirror-chain -->
This repo is maintained in [`Interested-Deving-1896/fork-sync-all`](https://github.com/Interested-Deving-1896/fork-sync-all) and mirrored through:

```
Interested-Deving-1896/fork-sync-all  ──►  OpenOS-Project-OSP/fork-sync-all  ──►  OpenOS-Project-Ecosystem-OOC/fork-sync-all
```

Changes flow downstream automatically via the hourly mirror chain in
[`fork-sync-all`](https://github.com/Interested-Deving-1896/fork-sync-all).
Direct commits to OSP or OOC are detected and opened as PRs back to `Interested-Deving-1896`.
<!-- AI:end:mirror-chain -->

## License

<!-- Add license information here. This section is yours — the AI will not modify it. -->
