# Origins ↔ Repository Import Interconnect

## Purpose

The Origins system records *why and how* an upstream project relates to this
ecosystem. The repository importer records *where source was imported* and
whether it is configured for later synchronization. These are related but
different responsibilities; neither registry should silently replace the
other.

## Proposed bidirectional contract

- **Import → Origins:** after an import succeeds, propose a provenance entry
  containing the canonical source URL, source identity, relationship, imported
  target, and source revision. The proposal must be reviewed before changing
  `dep-graph/provenance.yml`.
- **Origins → Import:** an origin record may produce an import candidate only
  when it carries an explicit import intent and destination policy. A
  `reference` or `inspired-by` relationship alone is not permission to clone
  or create a repository.
- **Reconciliation:** compare canonical source URLs across
  `dep-graph/provenance.yml` and `registered-imports.json`; report linked,
  import-only, origin-only, invalid, and duplicate entries.
- **One-way authority per concern:** provenance owns attribution/relationship;
  the import registry owns transport target and synchronization policy.
- **Reviewable changes:** registry changes should be proposed as a PR. No
  automatic direct commits to main, no implicit repository creation, no
  mirror-chain propagation, and no scheduled synchronization from the bridge.

## Current implementation in this PR

`scripts/origin_import_bridge.py` is a read-only reconciliation tool. Run:

```bash
python3 -m pip install pyyaml
python3 scripts/origin_import_bridge.py
python3 scripts/origin_import_bridge.py --output origin-import-audit.json
```

The tool does not mutate either registry, create repositories, dispatch
workflows, or push Git refs. It deliberately reports gaps rather than
repairing them automatically.

## Calamares pilot

The proposed source is `https://codeberg.org/Calamares/calamares`, with a
separate import target `Interested-Deving-1896/calamares-upstream`. This
target is distinct from the existing `Interested-Deving-1896/calamares`
Rhino Linux configuration fork. Initial import and mirror/sync activation
remain separate decisions. OSP/OOC mirroring and recurring sync remain off
until the source audit is complete.

## Safety boundary

The importer refuses an existing primary destination. Its initial branch/tag
publication uses ordinary, non-force refspecs without pruning. Optional OSP
publication also uses non-force refspecs: non-fast-forward conflicts are
reported rather than resolved by overwriting or deleting remote refs. Any
reconciliation of an existing target requires a separately reviewed path.
