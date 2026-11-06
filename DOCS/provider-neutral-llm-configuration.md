# Provider-neutral LLM configuration

The shared helper in `scripts/includes/llm.sh` speaks the OpenAI-compatible
`POST <base-url>/chat/completions` request shape. It deliberately does not
select a vendor, model, endpoint, or credential implicitly.

## Required configuration

Set these environment variables in the workflow/job that calls the helper:

- `LLM_BASE_URL`: HTTPS base URL for an approved OpenAI-compatible inference API.
  Use the base URL before `/chat/completions`; a trailing slash is optional.
- `LLM_API_KEY`: provider-specific API key, stored as a dedicated Actions secret.
  Do not reuse `GH_TOKEN` or `SYNC_TOKEN` unless the chosen provider explicitly
  documents that credential contract.
- `MODEL`: model identifier accepted by that endpoint.

The helper fails closed if any setting is missing or the base URL is not HTTP(S).
It never falls back to the retired GitHub Models inference endpoint and does not
print the credential or provider response body.

## Rollout requirements

This change is only the shared client boundary, not a complete live migration.
Before enabling translation or other AI workflows:

1. Choose and approve the provider, model, endpoint, and billing owner.
2. Configure the dedicated secret and variables in the relevant workflow.
3. Update quota/preflight scripts to query the selected provider or report
   capacity as unknown; GitHub REST quota is not LLM provider quota.
4. Mock-test the response contract and run a no-write single-request diagnostic
   with the approved credential.
5. Enable workflows only after that diagnostic succeeds. Until then, AI calls
   intentionally fail with a configuration error and no repository writes
   should be enabled for these jobs.

Never put API keys in repository files, workflow literals, logs, or issue comments.
