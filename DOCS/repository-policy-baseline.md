# Repository policy baseline

Fork-Sync-All owns a versioned, role-aware baseline for repository settings. The
baseline is resolved from `config/repository-policy-baseline.yml` and the
consumer's template profile in `config/template-consumers.yml`.

## Why this exists

Template files alone cannot guarantee consistent GitHub repository settings.
Branch protection, required status checks, merge policy, auto-merge, branch
deletion, and security toggles are repository-level controls. This policy makes
those controls explicit and reviewable alongside template profiles.

## Resolution

Run:

```sh
python3 scripts/repository_policy.py --repo btrfs-dwarfs-framework
```

A consumer may set `policy_profile` to decouple repository governance from its
template profile. If omitted, the template `profile` is used. Unknown profiles,
duplicate consumer records, and `require_ci: true` without a named aggregate
status check fail closed. Disabled consumers resolve to a non-enforced status.

## CI requirement

Where a profile guarantees the aggregate `CI Required` gate, the baseline
requires that stable gate rather than individual matrix/job names. This avoids
branch-protection breakage when job names or matrix dimensions change. Profiles
that do not guarantee the gate do not invent one; they require an explicit
policy override before CI can be marked mandatory.

## Safety and rollout

This first stage is a resolver and validation contract, not a bulk settings
migration. It does not call GitHub APIs, change branch protection, enable
auto-merge, or alter existing repositories. Rollout should proceed in this
order:

1. Resolve each consumer and validate the selected profile.
2. Produce a read-only settings/branch-protection drift report.
3. Verify that the required check actually appears on each target branch.
4. Apply policy only to explicitly admitted canonical repositories.
5. Verify the resulting protection and check contexts; keep mirror/delegated
   repositories read-only unless their owner policy explicitly permits writes.

Repository-specific exceptions must be documented in
`repository_overrides`; omission means inherit the baseline.
