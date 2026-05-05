[update-readmes]   Mode: rewrite — migrating to template structure...
# fork-sync-all

<!-- AI:start:what-it-does -->
This project automates the daily synchronization of forked repositories with their upstream sources to ensure they remain up-to-date. It is designed for developers and organizations managing multiple forks, reducing manual effort and minimizing the risk of outdated codebases.
<!-- AI:end:what-it-does -->

## Architecture

<!-- AI:start:architecture -->
The project automates daily synchronization of forked repositories with their upstream sources. It uses shell scripts and GitHub Actions workflows to manage updates, resolve conflicts, and maintain consistency across repositories. Key components include:

1. **Workflows**: Located in `.github/workflows/`, these YAML files define the automation logic for syncing forks, resolving failures, rebasing branches, and managing upstream pull requests.
2. **Scripts**: The `scripts/` directory contains shell scripts that implement core functionality, such as syncing repositories and handling edge cases.
3. **Configuration**: Files like `.gitlab-ci.yml` and `.devcontainer/` provide CI/CD and development environment setup.

The workflows interact with the scripts to execute tasks on a schedule or in response to events. The directory structure is as follows:

```plaintext
.
├── .devcontainer/       # Development environment configuration
├── .github/
│   └── workflows/       # GitHub Actions workflow definitions
├── .gitignore           # Git ignore rules
├── .gitlab-ci.yml       # GitLab CI configuration
├── README.md            # Project documentation
├── scripts/             # Shell scripts for core functionality
└── other files          # Supporting files and artifacts
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
- **add-mirror-repo.yml**: Adds new repositories to the mirror list. No secrets required.
- **mirror-artifacts.yml**: Syncs build artifacts from forks to upstream. Requires `ARTIFACTS_TOKEN`.
- **mirror-to-osp.yml**: Mirrors repositories to an open-source platform. Requires `OSP_API_KEY`.
- **rebase-lts.yml**: Rebases long-term support branches with upstream changes. No secrets required.
- **reconcile-org-refs.yml**: Updates organization references to match upstream. No secrets required.
- **resolve-failures.yml**: Identifies and resolves sync failures. Requires `ADMIN_TOKEN`.
- **setup-osp-mirrors.yml**: Configures mirrors for open-source projects. Requires `OSP_API_KEY`.
- **sync-eggs-docs-to-book.yml**: Syncs documentation from forks to a central book repository. No secrets required.
- **sync-forks.yml**: Synchronizes all forked repositories with their upstream sources. No secrets required.
- **sync-pieroproietti-forks.yml**: Syncs forks owned by a specific user. No secrets required.
- **upstream-prs.yml**: Creates pull requests to upstream repositories for changes in forks. Requires `GITHUB_TOKEN`.
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
