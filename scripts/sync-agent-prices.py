#!/usr/bin/env python3
"""
scripts/sync-agent-prices.py

Hybrid A+B+C price sync for config/agent-cost-profiles.yml.

Sources (in priority order per agent):
  A — Anthropic API  GET /v1/models  (requires ANTHROPIC_API_KEY)
  B — LiteLLM        model_prices_and_context_window.json (pinned SHA)
  C — Staleness      flag agents with prices_last_verified > STALE_DAYS old

Behaviour:
  - Fetches LiteLLM JSON at the pinned SHA from litellm_pin.sha in the config.
  - For each agent with price_source: litellm, looks up litellm_key and reads
    input_cost_per_token / output_cost_per_token (converts to per-1M).
  - For agents with price_source: anthropic-api, queries the Anthropic API
    directly for the model's pricing (requires ANTHROPIC_API_KEY env var).
  - Agents with price_source: manual or free are never modified.
  - Computes a diff of changed prices.
  - Updates config/agent-cost-profiles.yml in-place (prices + prices_last_verified
    + litellm_pin.sha/date).
  - Exits 0 with no changes if nothing changed.
  - Exits 2 if prices changed (caller should open a PR).
  - Exits 1 on fetch/parse errors.
  - Writes a structured report to GITHUB_STEP_SUMMARY if set.
  - Flags stale entries (price_source: manual, prices_last_verified > STALE_DAYS)
    as warnings — does not modify them, just reports.

Usage:
  python3 scripts/sync-agent-prices.py [--config PATH] [--stale-days N] [--dry-run]

Environment:
  ANTHROPIC_API_KEY  — optional; enables Option A (Anthropic API direct lookup)
  GITHUB_STEP_SUMMARY — optional; path to write step summary markdown
"""

import argparse
import json
import os
import sys
import urllib.request
import urllib.error
from datetime import datetime, timezone, timedelta
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).parent.parent
DEFAULT_CONFIG = REPO_ROOT / "config" / "agent-cost-profiles.yml"
LITELLM_URL_TEMPLATE = (
    "https://raw.githubusercontent.com/BerriAI/litellm/{sha}"
    "/model_prices_and_context_window.json"
)
ANTHROPIC_MODELS_URL = "https://api.anthropic.com/v1/models"
DEFAULT_STALE_DAYS = 90


# ── Fetch helpers ─────────────────────────────────────────────────────────────

def fetch_json(url: str, headers: dict | None = None) -> dict:
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code} fetching {url}") from e
    except Exception as e:
        raise RuntimeError(f"Failed to fetch {url}: {e}") from e


def fetch_litellm(sha: str) -> dict:
    url = LITELLM_URL_TEMPLATE.format(sha=sha)
    print(f"[litellm] Fetching {url}", file=sys.stderr)
    return fetch_json(url)


def fetch_anthropic_models(api_key: str) -> dict:
    """
    Returns a dict of model_id -> {input_cost_per_1m, output_cost_per_1m}
    from the Anthropic /v1/models endpoint.

    Note: as of 2026, the Anthropic models API returns model metadata but
    pricing is not included in the response. This function is a stub that
    returns an empty dict — if Anthropic adds pricing to the API response
    in future, implement it here.
    """
    print("[anthropic-api] Querying Anthropic /v1/models ...", file=sys.stderr)
    try:
        data = fetch_json(
            ANTHROPIC_MODELS_URL,
            headers={
                "x-api-key": api_key,
                "anthropic-version": "2023-06-01",
            },
        )
        # Anthropic API currently does not include pricing in model list.
        # Log available models for debugging but return empty pricing dict.
        models = [m.get("id", "") for m in data.get("data", [])]
        print(f"[anthropic-api] Available models: {models}", file=sys.stderr)
        print(
            "[anthropic-api] Pricing not available in API response — "
            "falling back to LiteLLM for Anthropic prices.",
            file=sys.stderr,
        )
        return {}
    except RuntimeError as e:
        print(f"[anthropic-api] WARNING: {e} — falling back to LiteLLM", file=sys.stderr)
        return {}


# ── Price extraction ──────────────────────────────────────────────────────────

def litellm_price(litellm_data: dict, key: str) -> tuple[float | None, float | None, int | None, int | None]:
    """
    Returns (cost_per_1m_in, cost_per_1m_out, context_k, context_out_k)
    for the given LiteLLM key, or (None, None, None, None) if not found.
    """
    entry = litellm_data.get(key)
    if not entry:
        return None, None, None, None

    in_per_token  = entry.get("input_cost_per_token")
    out_per_token = entry.get("output_cost_per_token")
    ctx_in  = entry.get("max_input_tokens")
    ctx_out = entry.get("max_output_tokens")

    cost_in  = round(in_per_token  * 1_000_000, 6) if in_per_token  is not None else None
    cost_out = round(out_per_token * 1_000_000, 6) if out_per_token is not None else None
    ctx_in_k  = round(ctx_in  / 1000) if ctx_in  else None
    ctx_out_k = round(ctx_out / 1000) if ctx_out else None

    return cost_in, cost_out, ctx_in_k, ctx_out_k


# ── Staleness check ───────────────────────────────────────────────────────────

def is_stale(verified_str: str | None, stale_days: int) -> bool:
    if not verified_str:
        return True
    try:
        verified = datetime.fromisoformat(str(verified_str))
        if verified.tzinfo is None:
            verified = verified.replace(tzinfo=timezone.utc)
        return (datetime.now(timezone.utc) - verified) > timedelta(days=stale_days)
    except ValueError:
        return True


# ── YAML round-trip helpers ───────────────────────────────────────────────────

def _update_agent_field(lines: list[str], agent_name: str, field: str, new_value) -> bool:
    """
    In-place update of a scalar field under an agent block in the YAML source.
    Returns True if a change was made.
    Preserves all comments and formatting outside the changed line.
    """
    in_agent = False
    indent = ""
    changed = False

    for i, line in enumerate(lines):
        # Detect agent block start (e.g. "  ona:")
        stripped = line.rstrip()
        if stripped.endswith(f"{agent_name}:") and not stripped.startswith("#"):
            in_agent = True
            indent = " " * (len(line) - len(line.lstrip()) + 2)
            continue

        if in_agent:
            # End of this agent block = next non-empty, non-comment line at same or lower indent
            if stripped and not stripped.startswith("#"):
                line_indent = len(line) - len(line.lstrip())
                agent_indent = len(indent) - 2
                if line_indent <= agent_indent and not stripped.startswith(f"{indent.strip()}"):
                    in_agent = False
                    continue

            # Match the field
            field_prefix = f"{indent}{field}:"
            if line.startswith(field_prefix):
                # Format the new value
                if isinstance(new_value, str):
                    formatted = f'"{new_value}"'
                elif new_value is None:
                    formatted = "null"
                elif isinstance(new_value, float):
                    # Preserve up to 4 significant decimal places, strip trailing zeros
                    formatted = f"{new_value:.4f}".rstrip("0").rstrip(".")
                    if "." not in formatted:
                        formatted += ".0"
                else:
                    formatted = str(new_value)

                # Preserve inline comment if present
                comment = ""
                rest = line[len(field_prefix):].strip()
                if "#" in rest:
                    comment = "  " + rest[rest.index("#"):]

                new_line = f"{indent}{field}: {formatted}{comment}\n"
                if new_line != line:
                    lines[i] = new_line
                    changed = True
                break

    return changed


def _update_litellm_pin(lines: list[str], sha: str, date: str) -> bool:
    changed = False
    for i, line in enumerate(lines):
        if line.strip().startswith("sha:") and i > 0:
            # Check we're inside litellm_pin block
            for j in range(i - 1, max(i - 5, -1), -1):
                if "litellm_pin:" in lines[j]:
                    new_line = f'  sha: "{sha}"\n'
                    if lines[i] != new_line:
                        lines[i] = new_line
                        changed = True
                    break
        if line.strip().startswith("date:") and i > 0:
            for j in range(i - 1, max(i - 5, -1), -1):
                if "litellm_pin:" in lines[j]:
                    new_line = f'  date: "{date}"\n'
                    if lines[i] != new_line:
                        lines[i] = new_line
                        changed = True
                    break
    return changed


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=str(DEFAULT_CONFIG))
    parser.add_argument("--stale-days", type=int, default=DEFAULT_STALE_DAYS)
    parser.add_argument("--dry-run", action="store_true",
                        help="Compute diff but do not write changes")
    args = parser.parse_args()

    config_path = Path(args.config)
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    # ── Load config ───────────────────────────────────────────────────────────
    with open(config_path) as f:
        raw_lines = f.readlines()
    with open(config_path) as f:
        config = yaml.safe_load(f)

    agents       = config.get("agents", {})
    litellm_pin  = config.get("litellm_pin", {})
    current_sha  = litellm_pin.get("sha", "main")

    # ── Fetch latest LiteLLM SHA ──────────────────────────────────────────────
    print("[sha] Fetching latest LiteLLM commit SHA for model_prices_and_context_window.json ...", file=sys.stderr)
    try:
        commits = fetch_json(
            "https://api.github.com/repos/BerriAI/litellm/commits"
            "?path=model_prices_and_context_window.json&per_page=1"
        )
        latest_sha  = commits[0]["sha"][:12]
        latest_date = commits[0]["commit"]["committer"]["date"][:10]
        print(f"[sha] Latest SHA: {latest_sha} ({latest_date})", file=sys.stderr)
    except Exception as e:
        print(f"[sha] WARNING: could not fetch latest SHA ({e}) — using pinned {current_sha}", file=sys.stderr)
        latest_sha  = current_sha
        latest_date = today

    # ── Fetch LiteLLM data ────────────────────────────────────────────────────
    try:
        litellm_data = fetch_litellm(latest_sha)
    except RuntimeError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        # Fall back to pinned SHA
        if latest_sha != current_sha:
            print(f"[litellm] Falling back to pinned SHA {current_sha}", file=sys.stderr)
            try:
                litellm_data = fetch_litellm(current_sha)
                latest_sha  = current_sha
                latest_date = litellm_pin.get("date", today)
            except RuntimeError as e2:
                print(f"ERROR: fallback also failed: {e2}", file=sys.stderr)
                return 1
        else:
            return 1

    # ── Option A: Anthropic API ───────────────────────────────────────────────
    anthropic_api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    anthropic_prices: dict = {}
    if anthropic_api_key:
        anthropic_prices = fetch_anthropic_models(anthropic_api_key)
    else:
        print("[anthropic-api] ANTHROPIC_API_KEY not set — skipping Option A", file=sys.stderr)

    # ── Process each agent ────────────────────────────────────────────────────
    changes:  list[dict] = []
    warnings: list[str]  = []
    working_lines = list(raw_lines)

    for agent_name, ap in agents.items():
        price_source = ap.get("price_source", "manual")
        litellm_key  = ap.get("litellm_key")
        verified_str = ap.get("prices_last_verified")

        # Option C: staleness check for manual entries
        if price_source in ("manual", "free"):
            if is_stale(verified_str, args.stale_days):
                warnings.append(
                    f"{agent_name}: price_source={price_source}, "
                    f"prices_last_verified={verified_str} is >{args.stale_days} days old — "
                    f"manual verification needed"
                )
            continue

        # Option A: Anthropic API (currently returns empty — future-proofed)
        if price_source == "anthropic-api" and litellm_key in anthropic_prices:
            ap_prices = anthropic_prices[litellm_key]
            new_in  = ap_prices.get("input_cost_per_1m")
            new_out = ap_prices.get("output_cost_per_1m")
        elif price_source in ("litellm", "anthropic-api") and litellm_key:
            # Option B: LiteLLM
            new_in, new_out, new_ctx_k, new_ctx_out_k = litellm_price(litellm_data, litellm_key)
            if new_in is None:
                warnings.append(
                    f"{agent_name}: litellm_key '{litellm_key}' not found in LiteLLM data"
                )
                continue
        else:
            continue

        old_in  = ap.get("cost_per_1m_in")
        old_out = ap.get("cost_per_1m_out")

        price_changed = (
            new_in  is not None and abs((new_in  or 0) - (old_in  or 0)) > 0.0001
        ) or (
            new_out is not None and abs((new_out or 0) - (old_out or 0)) > 0.0001
        )

        if price_changed:
            changes.append({
                "agent":   agent_name,
                "display": ap.get("display_name", agent_name),
                "field":   "cost_per_1m_in",
                "old":     old_in,
                "new":     new_in,
            })
            changes.append({
                "agent":   agent_name,
                "display": ap.get("display_name", agent_name),
                "field":   "cost_per_1m_out",
                "old":     old_out,
                "new":     new_out,
            })

        if not args.dry_run:
            if new_in is not None:
                _update_agent_field(working_lines, agent_name, "cost_per_1m_in",  new_in)
            if new_out is not None:
                _update_agent_field(working_lines, agent_name, "cost_per_1m_out", new_out)
            # Update context windows if they changed
            if new_ctx_k and new_ctx_k != ap.get("context_k"):
                _update_agent_field(working_lines, agent_name, "context_k", new_ctx_k)
            if new_ctx_out_k and new_ctx_out_k != ap.get("context_out_k"):
                _update_agent_field(working_lines, agent_name, "context_out_k", new_ctx_out_k)
            _update_agent_field(working_lines, agent_name, "prices_last_verified", today)

    # ── Update litellm_pin ────────────────────────────────────────────────────
    pin_changed = latest_sha != current_sha
    if not args.dry_run and pin_changed:
        _update_litellm_pin(working_lines, latest_sha, latest_date)

    # ── Write updated config ──────────────────────────────────────────────────
    if not args.dry_run and (changes or pin_changed):
        with open(config_path, "w") as f:
            f.writelines(working_lines)
        print(f"[write] Updated {config_path}", file=sys.stderr)

    # ── Report ────────────────────────────────────────────────────────────────
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")

    print("\n=== Price Sync Report ===", file=sys.stderr)

    if changes:
        print(f"\nPrice changes ({len(changes) // 2} agent(s)):", file=sys.stderr)
        seen = set()
        for c in changes:
            if c["agent"] not in seen:
                seen.add(c["agent"])
                in_c  = next((x for x in changes if x["agent"] == c["agent"] and x["field"] == "cost_per_1m_in"),  {})
                out_c = next((x for x in changes if x["agent"] == c["agent"] and x["field"] == "cost_per_1m_out"), {})
                print(
                    f"  {c['display']}: "
                    f"in ${in_c.get('old')} → ${in_c.get('new')}/1M, "
                    f"out ${out_c.get('old')} → ${out_c.get('new')}/1M",
                    file=sys.stderr,
                )
    else:
        print("\nNo price changes.", file=sys.stderr)

    if pin_changed:
        print(f"\nLiteLLM pin updated: {current_sha} → {latest_sha} ({latest_date})", file=sys.stderr)

    if warnings:
        print(f"\nWarnings ({len(warnings)}):", file=sys.stderr)
        for w in warnings:
            print(f"  ⚠ {w}", file=sys.stderr)

    # Write step summary
    if summary_path:
        with open(summary_path, "a") as f:
            f.write("## Agent Price Sync\n\n")
            f.write(f"**LiteLLM SHA**: `{latest_sha}` ({latest_date})")
            if pin_changed:
                f.write(f" ← updated from `{current_sha}`")
            f.write("\n\n")

            if changes:
                f.write(f"### Price changes — {len(changes) // 2} agent(s)\n\n")
                f.write("| Agent | Field | Old | New |\n|---|---|---|---|\n")
                for c in changes:
                    f.write(f"| {c['display']} | {c['field']} | ${c['old']} | ${c['new']} |\n")
                f.write("\n> A PR has been opened for review.\n")
            else:
                f.write("✅ No price changes — all prices current.\n")

            if warnings:
                f.write(f"\n### Staleness warnings — {len(warnings)}\n\n")
                for w in warnings:
                    f.write(f"- ⚠️ {w}\n")
                f.write(
                    f"\nAgents with `price_source: manual` or `free` are not auto-updated. "
                    f"Verify prices at the relevant provider and update "
                    f"`config/agent-cost-profiles.yml` manually.\n"
                )

    # Exit codes: 0 = no changes, 1 = error, 2 = prices changed (open PR)
    if changes:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
