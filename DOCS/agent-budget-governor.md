# AI agent compute-budget governor

The compute-budget governor prevents new AI coding-agent work from starting
when its provider's native budget is too low.  It also exposes cooperative
checkpoints that a running agent can use to pause at a safe boundary and resume
after a fresh observation crosses the configured recovery threshold.

The governor is provider-neutral.  Ona is the first adapter and OCU is the
first configured unit, but enforcement always uses the provider's native unit
(`ocu`, `credit`, `token`, or `usd`).  Approximate token-to-OCU conversions are
useful for forecasts only and are never used for admission decisions.

Policies represent billing pools rather than agent brands. Ona Agent and
Ona-managed Codex can both use the `ona` policy; agents backed by another pool
select that provider's policy. This keeps admission independent of the coding
agent implementation while still accounting for the resource that is actually
exhaustible.

## Components

| Component | Purpose |
|---|---|
| `config/agent-budget.yml` | Thresholds, reserves, freshness limits, and task estimates |
| `scripts/agent-budget-governor.py` | Network-free state machine and admission engine |
| `scripts/agent-budget-ona.py` | Ona billing/execution observer and goal pause/resume adapter |
| `scripts/includes/agent-budget.sh` | Cooperative `agent_budget_admit` and checkpoint helpers |
| `agent-budget-governor.yml` | Observation ingestion, state persistence, and enforcement |

Normalized state is stored in an Actions repository variable named
`AI_AGENT_BUDGET_STATE_<PROVIDER>`.  The corresponding enforced decision is
stored in `AI_AGENT_BUDGET_PAUSED_<PROVIDER>`.  State contains only normalized
numbers and timestamps; credentials and raw provider responses are never stored.

## Ona support

Ona Core and Enterprise expose different useful signals:

- Core shows the remaining OCU balance in **Settings → Cost & Budgets**, but no
  public Core remaining-balance API is currently documented.  Use the manual or
  `repository_dispatch` observation bridge until Ona publishes one.
- Enterprise exposes cumulative credit usage through
  `BillingService/GetCumulativeCreditUsage`.  This is consumption, not a Core
  OCU balance; the configured credit budget is still required to derive a
  remaining value.
- Agent executions expose native token counters and support cooperative goal
  pause/resume through `AgentService/SendToAgentExecution`.

Official references:

- <https://ona.com/docs/ona/billing/usage>
- <https://ona.com/docs/ona/billing/ona-intelligence-usage-api>
- <https://ona.com/docs/api-reference/generated/billing/get-cumulative-credit-usage>
- <https://ona.com/docs/api-reference/generated/agent/get-agent-execution>
- <https://ona.com/docs/api-reference/generated/agent/send-to-agent-execution>

## Required setup

### Core OCU balance bridge

Submit an authoritative observation after checking the Ona billing page:

```bash
gh workflow run agent-budget-governor.yml \
  --field action=observe \
  --field provider=ona \
  --field available_units=120 \
  --field source=ona-billing-ui \
  --field shadow_mode=true
```

An external observer can instead send a `repository_dispatch` event of type
`agent-budget-observation` with this payload:

```json
{
  "provider": "ona",
  "available_units": 120,
  "observed_at": "2026-10-09T00:00:00Z",
  "source": "ona-billing-bridge",
  "shadow_mode": true
}
```

### Enterprise Ona API

Create a dedicated read-only PAT or service-account token with
`billing:read_usage`, then configure:

- `ONA_BILLING_TOKEN` as a secret;
- `ONA_ORGANIZATION_ID` as a variable;
- `ONA_CREDIT_LIMIT` as a variable when remaining credits must be derived;
- `ONA_HOST` only when the organization does not use the default host.

Use a separate write-capable token for agent control.  Goal pause/resume may
need a PAT unless Ona confirms that the service-account token can perform the
write.  Never reuse the billing token for control.

For opt-in automatic control, configure:

- `ONA_AGENT_CONTROL_TOKEN` as the separate write-capable secret;
- `AI_AGENT_BUDGET_ONA_EXECUTIONS` as a JSON array of explicitly registered
  Ona agent-execution UUIDs;
- `AI_AGENT_BUDGET_AUTO_PAUSE=true` after shadow validation;
- `AI_AGENT_BUDGET_AUTO_RESUME=true` only when restarting spend without a human
  approval is acceptable.

Automatic pause is attempted only after a fresh, authoritative observation is
below the pause threshold. Unknown or stale data blocks new admissions but does
not interrupt an active agent. Automatic resume requires a fresh recovery
observation and a real paused-to-ready state transition.

Execution control is disabled in shadow mode and on status/check-only runs. On
each fresh observation, the allowlist is reconciled idempotently to the desired
goal state, so a partial API failure is safely retried on the next observation.

## Admission and hysteresis

For Ona Core, the default policy is:

- pause below 20 OCU;
- resume at 40 OCU;
- keep 10 OCU in reserve;
- reject observations older than six hours or more than five minutes in the
  future.

A task is admitted only when the observation is fresh, the provider is not in
the paused hysteresis state, and `available - reserve >= required`.  Unknown or
stale state fails closed for new work.  It does not terminate work already in a
destructive section.

```bash
source scripts/includes/agent-budget.sh
agent_budget_admit ona full-session

# Repeat at a safe, resumable boundary.
agent_budget_checkpoint ona full-session
```

Exit code `0` means admitted.  Exit code `3` means checkpoint/defer without
treating the task as a defect.

## Adding another provider

Add its native unit and thresholds under `providers`, then have a read-only
adapter submit this normalized observation to the governor or dispatch workflow:

```json
{
  "provider": "provider-id",
  "unit": "provider-native-unit",
  "available_units": 100,
  "observed_at": "2026-10-09T00:00:00Z",
  "source": "provider-api"
}
```

The normalized state records a timestamp and source label as trust signals;
adapters should provide the provider's observation time rather than relying on
ingestion time. Stale, future-dated, malformed, or out-of-order observations
cannot reopen admission. Keep observation credentials read-only. If the
provider supports pausing active agents, implement that as a separate allowlisted
control adapter with a distinct credential, following the Ona adapter's
dry-run-first pattern.

## Rollout

1. Keep `AI_AGENT_BUDGET_SHADOW_MODE=true`; collect observations and compare
   decisions with actual usage.
2. Set it to `false` to block new work after confidence is established.
3. Add cooperative pause for only explicitly registered Ona execution IDs.
4. Enable automatic resume only after idempotency and ownership checks pass.

`StopAgentExecution` is deliberately not part of normal budget control.  A
graceful goal pause preserves resumability; force-stop remains an operator-only
emergency action.
