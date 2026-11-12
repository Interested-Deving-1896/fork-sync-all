#!/usr/bin/env python3
"""Read-only, provider-neutral exchange between Origins and Code Archaeology."""
import argparse, json
from pathlib import Path
import sys

SCHEMA_VERSION = 1
RELATIONSHIPS = {"fork", "derived-from", "vendored", "copied-from", "inspired-by",
                 "depends-on", "mirror-of", "extracted-logic", "reference",
                 "schema-adopted", "pattern-adopted", "unknown"}

def parse_provenance_yaml(text):
    """Parse the simple influences list without requiring a YAML dependency."""
    records, current = [], None
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("- source:"):
            if current: records.append(current)
            current = {"source": line.split(":", 1)[1].strip()}
        elif current and ":" in line and not line.startswith("#"):
            key, value = line.split(":", 1)
            key, value = key.strip(), value.strip()
            if key in {"url", "relationship", "what", "artifact", "notes"}:
                current[key] = value.strip("'\"")
    if current: records.append(current)
    return records

def origins_to_investigations(provenance_path, target_repository):
    """Origins -> read-only Code Archaeology investigation requests."""
    declarations = parse_provenance_yaml(Path(provenance_path).read_text(encoding="utf-8"))
    requests = []
    for index, item in enumerate(declarations):
        relationship = item.get("relationship", "unknown")
        if relationship not in RELATIONSHIPS: relationship = "unknown"
        requests.append({
            "request_id": f"origins-{index + 1:05d}", "schema_version": SCHEMA_VERSION,
            "target_repository": target_repository, "declared_source": item.get("source", ""),
            "canonical_url": item.get("url", ""), "relationship": relationship,
            "question": item.get("what", "Investigate declared origin relationship"),
            "artifact_paths": [p.strip() for p in item.get("artifact", "").split(",") if p.strip()],
            "requested_evidence": ["commit-ancestry", "path-history", "patch-similarity",
                                   "rename-copy-move-candidates"],
            "mode": "read-only", "decision_state": "investigation-requested"
        })
    return {"schema_version": SCHEMA_VERSION, "contract": "fork-sync-all.origins-archaeology",
            "direction": "origins-to-archaeology", "target_repository": target_repository,
            "declaration_source": str(provenance_path), "requests": requests}

def archaeology_to_proposals(package):
    """Archaeology -> Origins proposal queue; never mutate declarations."""
    if not isinstance(package, dict):
        raise ValueError("evidence package must be a JSON object")
    if package.get("schema_version") != SCHEMA_VERSION:
        raise ValueError("unsupported evidence package schema_version")
    observations = package.get("observations")
    if not isinstance(observations, list):
        raise ValueError("evidence package observations must be an array")
    proposals = []
    for observation in observations:
        if not isinstance(observation, dict):
            raise ValueError("each evidence observation must be a JSON object")
        relationship = observation.get("relationship", "unknown")
        if relationship not in RELATIONSHIPS: relationship = "unknown"
        required = ("source_repository", "target_repository", "evidence_kind", "locator")
        missing = [key for key in required if not observation.get(key)]
        if missing: raise ValueError("observation missing required fields: " + ", ".join(missing))
        proposals.append({
            "proposal_id": observation.get("observation_id") or f"proposal-{len(proposals) + 1:05d}",
            "relationship_candidate": relationship, "source_repository": observation["source_repository"],
            "target_repository": observation["target_repository"],
            "source_revision": observation.get("source_revision"), "target_revision": observation.get("target_revision"),
            "evidence_kind": observation["evidence_kind"], "locator": observation["locator"],
            **({"blob_oid": observation["blob_oid"]} if observation.get("blob_oid") else {}),
            "source_paths": observation.get("source_paths", []),
            "target_paths": observation.get("target_paths", []),
            "confidence": observation.get("confidence", "unknown"), "rationale": observation.get("rationale", ""),
            "alternatives": observation.get("alternatives", []),
            "coverage": observation.get("coverage", {"complete": False}),
            "license_review": observation.get("license_review", "not-assessed"),
            "decision_state": "proposed-review-required", "may_auto_approve": False
        })
    return {"schema_version": SCHEMA_VERSION, "contract": "fork-sync-all.origins-archaeology",
            "direction": "archaeology-to-origins-proposals",
            "source_package": package.get("package_id", "unspecified"), "proposals": proposals,
            "authority": {"origins_declarations_modified": False, "provenance_auto_approval": False,
                          "repository_admission": False, "mirror_topology_mutation": False,
                          "sync_or_ref_mutation": False}}

def reconcile(declarations, proposals):
    """Conservative report-only reconciliation; absence is never contradiction."""
    declared = {(x.get("source", "").lower(), x.get("relationship", "unknown")) for x in declarations}
    rows = []
    for proposal in proposals:
        key = (proposal.get("source_repository", "").lower(), proposal.get("relationship_candidate", "unknown"))
        state = "candidate-match" if key in declared else "unmatched-proposal"
        if proposal.get("confidence") in {"unknown", "low"}: state = "ambiguous"
        if not (proposal.get("coverage") or {}).get("complete", False) and state != "ambiguous":
            state = "unavailable-or-incomplete"
        rows.append({"proposal_id": proposal.get("proposal_id"), "state": state,
                     "declared_match": key in declared, "decision_state": "human-review-required"})
    return {"schema_version": SCHEMA_VERSION, "report_only": True, "results": rows}

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    seed = sub.add_parser("seed")
    seed.add_argument("--provenance", default="dep-graph/provenance.yml")
    seed.add_argument("--target-repository", required=True)
    propose = sub.add_parser("propose")
    propose.add_argument("--input", required=True)
    reconcile_cmd = sub.add_parser("reconcile")
    reconcile_cmd.add_argument("--provenance", default="dep-graph/provenance.yml")
    reconcile_cmd.add_argument("--input", required=True,
                               help="JSON proposal queue produced by the propose command")
    args = parser.parse_args(argv)
    try:
        if args.command == "seed":
            result = origins_to_investigations(args.provenance, args.target_repository)
        elif args.command == "propose":
            result = archaeology_to_proposals(json.loads(Path(args.input).read_text(encoding="utf-8")))
        else:
            proposal_package = json.loads(Path(args.input).read_text(encoding="utf-8"))
            proposals = proposal_package.get("proposals")
            if not isinstance(proposals, list):
                raise ValueError("proposal input must contain a proposals array")
            declarations = parse_provenance_yaml(
                Path(args.provenance).read_text(encoding="utf-8"))
            result = reconcile(declarations, proposals)
            result["declarations_reviewed"] = len(declarations)
            result["proposals_reviewed"] = len(proposals)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"origins-archaeology: {exc}", file=sys.stderr)
        return 2
    json.dump(result, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
