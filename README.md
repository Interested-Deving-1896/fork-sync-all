[update-readmes]   Mode: rewrite — migrating to template structure...
# fork-sync-all

<!-- AI:start:what-it-does -->
This project automates the daily synchronization of forked repositories with their upstream sources to ensure they remain up-to-date. It is used by developers and organizations managing multiple forks to streamline updates, reduce manual effort, and maintain consistency across repositories.
<!-- AI:end:what-it-does -->

## Architecture

<!-- AI:start:architecture -->
The project automates daily synchronization of forked repositories with their upstream sources. It uses GitHub Actions workflows to manage various tasks, such as syncing forks, reconciling references, and resolving conflicts. Each workflow is defined in YAML files under `.github/workflows`. Shell scripts in the `scripts` directory handle specific operations like rebasing and syncing artifacts. The `.devcontainer` directory provides a development environment configuration. The `.gitlab-ci.yml` file supports optional GitLab CI integration.

Directory structure:
```plaintext
.
├── .devcontainer/          # Development container configuration
├── .github/
│   └── workflows/          # GitHub Actions workflow definitions
├── .gitignore              # Git ignore rules
├── .gitlab-ci.yml          # GitLab CI configuration
├── README.md               # Project documentation
├── scripts/                # Shell scripts for sync operations
└── other files...          # Additional project files
```

Key components interact as follows:
- Workflows trigger on schedule or events, invoking scripts in `scripts/`.
- Scripts perform tasks like fetching upstream changes, rebasing, and resolving conflicts.
- Outputs are logged and optionally pushed to mirrors or upstream repositories.
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
- **mirror-artifacts.yml**: Syncs build artifacts from upstream repositories. Requires `ARTIFACTS_TOKEN`.
- **mirror-to-osp.yml**: Mirrors repositories to an open-source platform. Requires `OSP_API_KEY`.
- **rebase-lts.yml**: Rebases long-term support branches with upstream changes. No secrets required.
- **reconcile-org-refs.yml**: Updates organization-level references to match upstream. No secrets required.
- **resolve-failures.yml**: Handles and resolves sync-related failures. Requires `FAILURE_HANDLER_TOKEN`.
- **setup-osp-mirrors.yml**: Configures mirrors on the open-source platform. Requires `OSP_API_KEY`.
- **sync-eggs-docs-to-book.yml**: Syncs documentation from "eggs" repos to a central book repo. No secrets required.
- **sync-forks.yml**: Synchronizes all forked repositories with their upstream sources. No secrets required.
- **sync-pieroproietti-forks.yml**: Syncs forks owned by a specific user. No secrets required.
- **upstream-prs.yml**: Creates pull requests to upstream repositories for changes. Requires `GITHUB_TOKEN`.

Secrets can be configured in the repository settings under "Secrets and variables."
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
