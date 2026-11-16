# NativeLink integration for Fork-Sync-All

## Status

This is the first FSA-side integration slice: a provider adapter that validates
NativeLink Remote Execution API endpoints and renders Bazel remote execution
and/or remote cache flags. It is opt-in and deliberately does not launch builds,
contact a NativeLink service, provision workers, or change any existing workflow.

The upstream NativeLink documentation demonstrates Bazel clients using
`--remote_executor=grpc://...` and `--remote_cache=grpc://...`; TLS deployments
use `grpcs://`. See the upstream
[local testing guide](https://docs.nativelink.com/remote-execution/local-testing)
and [TLS/authentication guide](https://docs.nativelink.com/how-to/tls-and-auth).

## Configuration

Set only the endpoints that are available to the project:

| Variable | Purpose |
|---|---|
| `NATIVE_LINK_EXECUTOR` | Optional REAPI execution endpoint, e.g. `grpcs://executor.example:50052` |
| `NATIVE_LINK_CACHE` | Optional remote cache endpoint, e.g. `grpcs://cache.example:50051` |
| `NATIVE_LINK_INSTANCE_NAME` | Optional REAPI instance name |

The endpoints must use `grpc://` or `grpcs://`, include a host and explicit
port, and must not include credentials, paths, query strings, or fragments.
The adapter rejects malformed configuration and does not echo endpoint values
in errors.

## Use

Render Bazel flags from the environment:

```sh
python3 scripts/nativelink_adapter.py
```

Or provide values explicitly:

```sh
python3 scripts/nativelink_adapter.py \
  --executor grpcs://executor.example:50052 \
  --cache grpcs://cache.example:50051 \
  --instance-name fsa/ci
```

For machine-readable output:

```sh
python3 scripts/nativelink_adapter.py --format json
```

Append the rendered flags to a project-owned Bazel invocation only after that
project opts in and its maintainers confirm the endpoint, trust boundary, and
build configuration. Cache-only mode is supported. An execution endpoint is
not required to use the remote cache.

## Security and operational boundaries

- NativeLink is an optional execution/cache provider, not a replacement for
  FSA's provider-neutral orchestration, policy, or runner abstractions.
- Do not put bearer tokens, passwords, signed URLs, or credentials in endpoint
  URLs, workflow inputs, command-line arguments, logs, or generated artifacts.
- Configure authentication using the selected build tool's supported
  credential mechanism and protected CI secrets; do not expose secrets to
  untrusted pull-request jobs.
- Keep untrusted PR execution isolated from trusted cache namespaces and
  production workers. Apply least privilege, resource quotas, network policy,
  retention limits, and audit logging at the NativeLink deployment boundary.
- NativeLink's worker API is a worker-registration/control surface, not a
  build-client endpoint. FSA clients must use the documented REAPI client
  endpoints; never point a build client at a worker API listener.
- Remote execution requires hermetic, reproducible build actions and compatible
  toolchains/platform properties. Enabling a remote endpoint alone does not
  make a build safe or remotely executable.

## Next integration stages

1. Agree on the FSA provider-neutral remote-execution contract and endpoint
   ownership model.
2. Add a protected, project-scoped workflow that consumes rendered flags only
   for explicitly allowlisted builds.
3. Validate cache isolation, TLS/authentication, worker platform properties,
   timeouts, cancellation, resource quotas, and artifact provenance.
4. Pilot on a disposable, non-production build before enabling additional
   repositories or runner classes.

Until those gates and an end-to-end pilot pass, this adapter reports
configuration only. It does not claim a successful NativeLink connection or
build.
