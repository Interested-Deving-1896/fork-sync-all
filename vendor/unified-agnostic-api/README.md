# unified-agnostic-api

[![Built with Ona](https://ona.com/build-with-ona.svg)](https://app.ona.com/#https://github.com/Interested-Deving-1896/unified-agnostic-api) [![KDE Eco](https://img.shields.io/badge/KDE%20Eco-certified-brightgreen?logo=kde&logoColor=white&style=flat-square)](https://eco.kde.org/) [![Blue Angel](https://img.shields.io/badge/Blue%20Angel-DE--UZ%20215-0055a4?style=flat-square)](https://www.blauer-engel.de/en/certification/criteria)

A modular, Bash-based API that exposes filesystem, GitHub, browser, operating-system, and AI capabilities through a consistent adapter interface. Use adapters directly from the command line or expose them over HTTP through a configurable server backend.

## What it does

- **One adapter interface:** group related operations behind predictable CLI commands and HTTP routes.
- **Multiple integration areas:** filesystem operations, GitHub repository and release management, browser automation, OS utilities, and AI helpers.
- **Flexible HTTP serving:** configure the server to use shell2http, webhook, or CGI.
- **Declarative routing:** define endpoint paths, methods, scripts, and optional bearer-token authentication in config/routes.yml.
- **Local-first CLI:** run adapter scripts directly without starting an HTTP server, or proxy commands to a running instance.
- **Extensible design:** add an adapter script and register its route to expose new functionality.

## Architecture

The project is organized around small Bash adapter scripts, shared request/response helpers, and a route manifest.

~~~text
CLI (cli/uaa.sh) ───────────────► adapter scripts ──► JSON/text responses
       │
       └── --server URL ────────► HTTP server
                                    │
config/routes.yml ─────────────────┤
                                    ▼
                         shell2http | webhook | CGI
                                    │
                                    ▼
                              adapter scripts
~~~

- **cli/uaa.sh** dispatches local adapter commands and supports proxying requests to a running server.
- **adapters/** contains operation-specific scripts. Each script handles an endpoint or command.
- **lib/** provides shared logging, input parsing, authentication, and response helpers.
- **config/routes.yml** maps HTTP paths and methods to adapter scripts; routes can require bearer-token authentication.
- **server/** merges route manifests and starts the selected HTTP backend.
- **docs/adapter-authoring.md** describes the adapter contract and how to register additional routes.

## Install

Clone the repository and enter its directory:

~~~bash
git clone https://github.com/Interested-Deving-1896/unified-agnostic-api.git
cd unified-agnostic-api
~~~

The CLI can be run directly with Bash; you do not need to install a global command to try it. Some adapters and server modes require additional tools or credentials, depending on which features you use. For the HTTP server, the default backend is `shell2http`; install it using the instructions in [msoap/shell2http](https://github.com/msoap/shell2http). The alternative `webhook` backend requires [adnanh/webhook](https://github.com/adnanh/webhook). CGI mode requires a compatible web server configured to execute the deployed CGI scripts.

## Usage

### Run a command locally

Run the CLI through Bash from the repository root:

~~~bash
bash cli/uaa.sh help
bash cli/uaa.sh health
bash cli/uaa.sh adapters list
bash cli/uaa.sh filesystem ls --path /tmp
bash cli/uaa.sh os info
~~~

The CLI runs adapter scripts directly; a server is not required for local commands. Use `bash cli/uaa.sh help` to see the command groups and supported operations. Examples that access GitHub, browser automation, or AI providers may require credentials or optional tools appropriate to that adapter.

### Start the HTTP server

Start the default server on port 8080 (the default backend is `shell2http`):

~~~bash
bash server/start.sh
~~~

Choose a different port or backend with flags:

~~~bash
bash server/start.sh --port 9090
bash server/start.sh --backend cgi
bash server/start.sh --backend webhook
~~~

Check the health endpoint and list registered adapters:

~~~bash
curl http://localhost:8080/health
curl http://localhost:8080/api/adapters
curl 'http://localhost:8080/api/filesystem/ls?path=/tmp'
~~~

If the server is configured on a different host or port, replace `localhost:8080` accordingly. The CLI can also proxy supported commands to a running instance:

~~~bash
bash cli/uaa.sh --server http://localhost:8080 os info
~~~

### Call a write endpoint

Routes marked `auth: true` in `config/routes.yml` are intended to be protected by the configured bearer token. For example, the filesystem write route is a POST endpoint:

~~~bash
curl -X POST http://localhost:8080/api/filesystem/write \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $UAA_AUTH" \
  -d '{"path":"/tmp/example.txt","content":"Hello from UAA"}'
~~~

Use a disposable test path when experimenting. Treat this API as a trusted local service unless you have deliberately configured and secured network access; do not expose write, shell, browser-automation, or other sensitive endpoints to an untrusted network.

## Configuration

The server and adapters are configured through environment variables and YAML files. Defaults are applied by the launcher, so set only the values you need to override.

### Server environment variables

| Variable | Default | Purpose |
|---|---|---|
| `UAA_PORT` | `8080` | Port the server listens on |
| `UAA_HOST` | `0.0.0.0` | Interface/address the server binds to |
| `UAA_BACKEND` | `shell2http` | HTTP backend: `shell2http`, `cgi`, or `webhook` |
| `UAA_LOG` | `info` | Log level: `debug`, `info`, or `warn` |
| `UAA_AUTH` | unset | Optional bearer token used by protected routes |
| `UAA_TOGGLES_FILE` | `config/toggles.yml` | Optional path to the feature-toggle configuration file |

You can set variables inline for a single launch:

~~~bash
UAA_PORT=9090 UAA_HOST=127.0.0.1 UAA_LOG=debug bash server/start.sh
~~~

Or use flags for common server options:

~~~bash
bash server/start.sh --port 9090 --host 127.0.0.1 --backend shell2http
~~~

When using protected routes, configure `UAA_AUTH` in the server environment and send the matching value as an `Authorization: Bearer …` header. Keep the token private; do not commit secrets to the repository or place them in public logs. Authentication behavior is defined by each route and adapter, so review `config/routes.yml` before exposing the service.

### Route manifest

Edit [config/routes.yml](config/routes.yml) to add or change HTTP endpoints. Each route associates a URL path with an adapter script and an HTTP method; routes can also enable authentication. For example:

~~~yaml
- path: /api/my-adapter/example
  script: adapters/my-adapter/example.sh
  method: GET
  auth: false
~~~

Paths are served by the selected backend, and scripts are resolved relative to the repository root. To add another route manifest without editing the default file, pass one or more `--routes` options:

~~~bash
bash server/start.sh --routes config/routes.yml --routes extra/routes.yml
~~~

For adapter inputs, request/response helpers, route registration, and local testing, see the [Adapter Authoring Guide](docs/adapter-authoring.md).

## CI

<!-- AI:start:ci -->
The repository includes a GitHub Actions accessibility audit in [check-accessibility.yml](https://github.com/Interested-Deving-1896/unified-agnostic-api/actions/workflows/check-accessibility.yml). The workflow checks ownership coverage, README screen-reader compatibility, WCAG 2.1 AA HTML compliance, and generated audio/Braille accessibility artifacts. Run it from the repository's Actions tab to produce a report.
<!-- AI:end:ci -->

## Mirror chain

<!-- AI:start:mirror-chain -->
This repository is maintained in [Interested-Deving-1896/unified-agnostic-api](https://github.com/Interested-Deving-1896/unified-agnostic-api) and mirrored downstream:

~~~text
Interested-Deving-1896/unified-agnostic-api
              │
              ▼
OpenOS-Project-OSP/unified-agnostic-api
              │
              ▼
OpenOS-Project-Ecosystem-OOC/unified-agnostic-api
~~~

The mirror chain is coordinated by [fork-sync-all](https://github.com/Interested-Deving-1896/fork-sync-all). Changes flow downstream automatically; direct commits made in the OSP or OOC mirrors are detected and opened as pull requests back to Interested-Deving-1896.
<!-- AI:end:mirror-chain -->

## Contributors

<!-- AI:start:contributors -->
| Contributor | Commits |
|---|---:|
| [@Interested-Deving-1896](https://github.com/Interested-Deving-1896) | 16 |
| [@github-actions[bot]](https://github.com/apps/github-actions) | 1 |
<!-- AI:end:contributors -->

## Origins

<!-- AI:start:origins -->
The project draws on ideas and patterns from several existing tools and projects. The following references are documented by the repository's maintenance project:

| Project | Referenced concept |
|---|---|
| [msoap/shell2http](https://github.com/msoap/shell2http) | HTTP endpoints backed by shell scripts; a primary server backend |
| [adnanh/webhook](https://github.com/adnanh/webhook) | Webhook-triggered scripts; an alternate server backend |
| [Lifailon/bash-api-server](https://github.com/Lifailon/bash-api-server) | Bash-based REST/CGI patterns |
| [locus313/github-api-scripts](https://github.com/locus313/github-api-scripts) | GitHub organization administration script patterns |
| [beamitpal/unified-ai-api](https://github.com/beamitpal/unified-ai-api) | Provider-agnostic AI API design patterns |
<!-- AI:end:origins -->

## Resources

<!-- AI:start:resources -->
| Resource | Description |
|---|---|
| [Adapter Authoring Guide](docs/adapter-authoring.md) | Adapter script contract, helper functions, route registration, and local testing |
| [Route manifest](config/routes.yml) | HTTP endpoint paths, methods, adapter scripts, and authentication settings |
| [CLI](cli/uaa.sh) | Available command groups and command-line dispatch |
| [Server launcher](server/start.sh) | Server options, backend selection, and environment variables |
| [fork-sync-all](https://github.com/Interested-Deving-1896/fork-sync-all) | Repository synchronization and README maintenance workflows |
<!-- AI:end:resources -->

## Accessibility

<!-- AI:start:accessibility -->
This repository uses automated accessibility auditing through [check-accessibility.yml](https://github.com/Interested-Deving-1896/unified-agnostic-api/actions/workflows/check-accessibility.yml).

The checks cover CODEOWNERS ownership coverage, README screen-reader compatibility, WCAG 2.1 AA HTML compliance, audio overview generation with espeak-ng, and Braille output with liblouis. Run the workflow from GitHub Actions to generate the report and accessibility artifacts. See the [W3C Web Content Accessibility Guidelines](https://www.w3.org/WAI/standards-guidelines/wcag/) for the underlying standard.
<!-- AI:end:accessibility -->

## License

<!-- AI:start:license -->
No LICENSE file was detected in the repository when this README was generated. Add a license file and update this section to state the project's license.
<!-- AI:end:license -->
