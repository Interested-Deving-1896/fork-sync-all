## What

<!-- Describe what this PR changes and why. -->

## Bugzilla

<!-- If this fixes or relates to a Bugzilla bug, reference it here.
     Supported formats: Bug 12345 | bz#12345 | bz: 12345 | [bz-12345]
     The sync-to-bugzilla workflow will automatically update the bug status. -->

Bug: <!-- e.g. Bug 12345, or N/A -->

## Type

- [ ] Mirror / sync logic change
- [ ] Workflow / CI update
- [ ] Script change
- [ ] Config change
- [ ] Docs
- [ ] Security

## Checklist

- [ ] `python3 scripts/validate-workflow-guards.py` passes (if workflows changed)
- [ ] New workflows added to `config/workflow-priority-tiers.yml` and `config/workflow-sync.yml`
- [ ] New workflows added to `config/workflow-quota-costs.yml` with estimated costs
- [ ] Logging helpers use `>&2` (no stdout pollution in captured subshells)
- [ ] No secrets or tokens hardcoded
