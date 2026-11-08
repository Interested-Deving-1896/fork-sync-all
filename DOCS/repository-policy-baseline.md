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
template profile. If omitted, the template `profile` is used. Set
`policy_managed: true` on an individual consumer to admit it to repository
settings management; this is independent of template propagation and mirror
tier. The default is false. Protected/delegated consumers remain read-only
unless explicitly admitted. Unknown profiles, duplicate consumer records, and
`require_ci: true` without a named aggregate status check fail closed. Disabled
consumers resolve to a non-enforced status.

The existing `config/repo-settings.yml` remains the common repository-settings
source. `scripts/manage-repo-settings.sh` resolves the consumer policy and
resolves role-specific `repository` settings only for explicitly admitted
consumers. Precedence is policy defaults/profile, shared settings defaults,
explicit policy repository exception, then explicit `repo-settings.yml`
per-repository override. Its default `MODE=check` remains read-only;
`MODE=apply` is still required for any remote settings mutation.

## CI requirement

Template profiles do not automatically imply that a CI status context exists.
The built-in consumer profiles therefore leave `require_ci` disabled until the
target repository actually publishes a stable aggregate gate. The explicit
`ci-required` policy profile selects the exact `CI Required` context; use it
only after confirming that context appears on the target default branch.
Onboarding independently verifies the context before applying protection and
reads protection back afterwards. This avoids inventing check names or
accidentally making a repository unmergeable.

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
