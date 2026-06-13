# vendor/shell-tools

Vendored core scripts from the 24 shell/filesystem utility repos registered
in the shell-tools group. Each subdirectory contains the minimal runnable
entrypoint(s) from the upstream fork, kept in sync by `sync-shell-tools.yml`.

## How this integrates with fork-sync-all workflows

```
vendor/shell-tools/<tool>/   ← tool's core script(s), available to all runners
scripts/includes/shell-tools.sh  ← wrapper functions (tool_encrypt, tool_sync, …)
.github/workflows/
  sync-shell-tools.yml       ← pulls latest from each upstream fork into vendor/
  integrate-shell-tools.yml  ← runs each tool's core function as a smoke test
  check-shell-tools-ci.yml   ← checks CI status across all 24 forks
```

Workflows call tools via the wrapper functions in `scripts/includes/shell-tools.sh`:

```bash
source scripts/includes/shell-tools.sh
sizes_report /some/path          # disk usage summary
namefix_check "bad filename.txt" # validate filename
jail_run "bash myscript.sh"      # run in Landlock sandbox
hrsync_backup /src /dst          # rsync with rename detection
```

## Sync policy

`sync-shell-tools.yml` runs weekly (Sunday 02:00 UTC) and on dispatch.
It sparse-clones each upstream fork and copies only the entrypoint script(s)
into the corresponding `vendor/shell-tools/<tool>/` directory.

The full fork (all branches, history) is kept current separately by
`sync-registered-imports.yml` which covers all 135 registered imports.

## Adding a new tool

1. Add the upstream to `registered-imports.json`
2. Add the repo to `config/gitlab-subgroups.yml`
3. Add a `vendor/shell-tools/<tool>/` directory with a `.keep` file
4. Add the tool to `config/shell-tools-registry.yml`
5. Add a wrapper function to `scripts/includes/shell-tools.sh`
6. Add the repo to `config/template-consumers.yml` with `profile: shell-tools`
