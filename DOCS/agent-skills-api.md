# AI-agnostic skills API

FSA-API treats the open Agent Skills package as its interchange format: a
directory containing `SKILL.md` with YAML frontmatter, plus optional scripts,
references, and assets. Provider behavior is declared in
`config/agent-skills.yml`, so adding another AI normally requires configuration,
not a new code path.

## Trust boundary

The API discovers, validates, inspects, and copies skill packages. It never
executes a skill or any bundled script. A skill can contain operational
instructions and executable code, so installation is an authenticated,
explicit operation and defaults to a dry run.

Validation confines reads and writes to configured workspace-relative roots,
rejects symlinks by default, limits package file count and total size, parses
frontmatter with `yaml.safe_load`, and checks the portable Agent Skills naming
and metadata rules.

## Provider registry

The default registry includes:

| Provider ID | Discovery | Export |
|---|---|---|
| `agents` | `.agents/skills` | `.agents/skills` |
| `codex` | `.agents/skills`, `.codex/skills` | `.codex/skills` |
| `claude` | `.agents/skills`, `.claude/skills` | `.claude/skills` |
| `copilot` | `.agents/skills`, `.github/skills`, `.claude/skills` | `.github/skills` |
| `gemini` | `.agents/skills`, `.gemini/skills` | `.gemini/skills` |
| `ona` | `.ona/skills` legacy Markdown | `.ona/skills` legacy Markdown |

The Ona entry preserves compatibility with this repository's existing flat
Markdown skills. Those files can be projected into a standard package by
installing them for a package-based provider. A standard-to-legacy export copies
only `SKILL.md`; the response warns when the source also contains resources.
Prefer the canonical `.agents/skills` location when multiple agents share a
workspace.

To add another provider, add a unique ID with `format`, `discovery_paths`, and
`export_path`. Supported formats are `agent-skills` and `legacy-markdown`. Every
path must also appear under `policy.allowed_roots`.

## HTTP routes

```text
GET  /api/fsa/skills
GET  /api/fsa/skills/providers
GET  /api/fsa/skills/:name
POST /api/fsa/skills/validate
POST /api/fsa/skills/export
```

Examples:

```bash
curl -sS http://localhost:8090/api/fsa/skills?provider=codex

curl -sS -X POST http://localhost:8090/api/fsa/skills/validate \
  -H "Authorization: Bearer $FSA_AUTH" \
  -H "Content-Type: application/json" \
  -d '{"path":".agents/skills/example"}'

# Preview only; no files are changed.
curl -sS -X POST http://localhost:8090/api/fsa/skills/export \
  -H "Authorization: Bearer $FSA_AUTH" \
  -H "Content-Type: application/json" \
  -d '{"name":"example","provider":"claude","dry_run":true}'
```

The same engine can be run locally:

```bash
python3 scripts/agent-skills.py providers
python3 scripts/agent-skills.py list --provider all
python3 scripts/agent-skills.py validate .agents/skills/example
python3 scripts/agent-skills.py export example claude
python3 scripts/agent-skills.py export example claude --materialize
```

## Scope

“AI-agnostic” means the core is provider-neutral and the provider registry is
extensible. It does not imply that every AI product can consume every resource
or tool declaration identically. The validation response retains standard
metadata, while provider-specific installation remains an adapter concern.
