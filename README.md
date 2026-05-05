[update-readmes]   Mode: rewrite — migrating to template structure...
# fork-sync-all

<!-- AI:start:what-it-does -->
This project automates the daily synchronization of forked repositories with their upstream sources to ensure they stay up to date. It is designed for developers and organizations managing multiple forks, reducing manual effort and minimizing the risk of outdated codebases.
<!-- AI:end:what-it-does -->

## Architecture

<!-- AI:start:architecture -->
The project automates daily synchronization of forked repositories with their upstream sources using shell scripts and CI workflows. It consists of shell scripts and YAML-based workflows that handle tasks such as syncing forks, resolving conflicts, rebasing branches, and managing upstream pull requests. The `.github` and `.gitlab` directories contain CI/CD configurations for GitHub Actions and GitLab CI, respectively. The `scripts` directory houses reusable shell scripts invoked by the workflows. 

Directory structure:
```plaintext
.
├── .devcontainer/       # Development container configuration
├── .github/             # GitHub Actions workflows
├── .gitlab/             # GitLab CI configuration
├── scripts/             # Shell scripts for sync and automation tasks
├── .gitignore           # Git ignore rules
├── .gitlab-ci.yml       # GitLab CI pipeline definition
├── README.md            # Project documentation
```

Key components interact as follows:
- Workflows in `.github` and `.gitlab` trigger on schedule or events.
- Workflows invoke scripts in `scripts/` to perform sync operations.
- Logs and artifacts are generated for debugging and auditing.
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
- **mirror-artifacts.yml**: Syncs build artifacts to a designated storage. Requires `ARTIFACT_STORAGE_KEY`.
- **mirror-to-osp.yml**: Mirrors repositories to an open-source platform. Requires `OSP_API_TOKEN`.
- **rebase-lts.yml**: Rebases long-term support branches with upstream changes. No secrets required.
- **reconcile-org-refs.yml**: Updates organization references to match upstream. No secrets required.
- **resolve-failures.yml**: Handles and resolves sync failures. Requires `FAILURE_RESOLUTION_KEY`.
- **setup-osp-mirrors.yml**: Configures mirrors on the open-source platform. Requires `OSP_API_TOKEN`.
- **sync-eggs-docs-to-book.yml**: Syncs documentation from "eggs" to a book repository. No secrets required.
- **sync-forks.yml**: Synchronizes all forked repositories with their upstream sources. No secrets required.
- **sync-pieroproietti-forks.yml**: Syncs forks owned by a specific user. No secrets required.
- **upstream-prs.yml**: Creates pull requests to upstream repositories for changes. Requires `GITHUB_TOKEN`.

Secrets must be configured in the repository settings for workflows requiring them.
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
