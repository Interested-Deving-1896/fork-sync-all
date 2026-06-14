#!/usr/bin/env python3
"""
Validates the devcontainer setup:
  - devcontainer.json parses cleanly (strips // comments)
  - devcontainer.template.json parses cleanly
  - All local features have devcontainer-feature.json + install.sh
  - automations templates have --no-ccr-inject-tool on headroom proxy
  - All feature manifests have required fields and matching id/dirname

Exits 1 on any error.
"""
import json, os, sys, glob
import yaml

errors = []


def check_json_file(path, label):
    if not os.path.exists(path):
        errors.append(f"MISSING: {path}")
        return None
    raw = open(path).read()
    lines = [l for l in raw.splitlines() if not l.strip().startswith("//")]
    try:
        return json.loads("\n".join(lines))
    except json.JSONDecodeError as e:
        errors.append(f"PARSE ERROR {label}: {e}")
        return None


# ── devcontainer.json ─────────────────────────────────────────────────────────
dc = check_json_file(".devcontainer/devcontainer.json", "devcontainer.json")
if dc is not None:
    if not dc.get("image") and not dc.get("build") and not dc.get("dockerFile"):
        errors.append("devcontainer.json: no image, build, or dockerFile")
    for feat_ref in dc.get("features", {}).keys():
        if feat_ref.startswith("./"):
            feat_path = f".devcontainer/{feat_ref.lstrip('./')}"
            if not os.path.isdir(feat_path):
                errors.append(f"Local feature not found: {feat_path}")
            else:
                if not os.path.exists(f"{feat_path}/devcontainer-feature.json"):
                    errors.append(f"Missing devcontainer-feature.json in {feat_path}")
                if not os.path.exists(f"{feat_path}/install.sh"):
                    errors.append(f"Missing install.sh in {feat_path}")
    feat_count = len(dc.get("features", {}))
    print(f"OK  devcontainer.json: {feat_count} features, image={dc.get('image','(build)')}")

# ── devcontainer.template.json ────────────────────────────────────────────────
tmpl = check_json_file(".devcontainer/devcontainer.template.json", "devcontainer.template.json")
if tmpl is not None:
    print(f"OK  devcontainer.template.json: {len(tmpl.get('features', {}))} features")

# ── automations templates ─────────────────────────────────────────────────────
for path in [".ona/automations.yaml", ".devcontainer/automations.template.yaml"]:
    if not os.path.exists(path):
        errors.append(f"MISSING: {path}")
        continue
    try:
        d = yaml.safe_load(open(path))
        for svc, cfg in ((d or {}).get("services", {}) or {}).items():
            start = ((cfg or {}).get("commands") or {}).get("start", "")
            if not start:
                errors.append(f"{path}: service '{svc}' missing start command")
            if "headroom proxy" in start and "--no-ccr-inject-tool" not in start:
                errors.append(f"{path}: headroom proxy missing --no-ccr-inject-tool")
        print(f"OK  {path}")
    except yaml.YAMLError as e:
        errors.append(f"{path}: YAML error: {e}")

# ── feature manifests ─────────────────────────────────────────────────────────
feat_dirs = sorted(glob.glob(".devcontainer/features/*/"))
for feat_dir in feat_dirs:
    name = feat_dir.rstrip("/").split("/")[-1]
    m = check_json_file(f"{feat_dir}devcontainer-feature.json", f"feature:{name}")
    if m is None:
        continue
    for field in ["id", "version", "name"]:
        if not m.get(field):
            errors.append(f"feature:{name}: missing '{field}'")
    if m.get("id") != name:
        errors.append(f"feature:{name}: id='{m.get('id')}' != dir name '{name}'")
    if not os.path.exists(f"{feat_dir}install.sh"):
        errors.append(f"feature:{name}: missing install.sh")

print(f"OK  {len(feat_dirs)} devcontainer features checked")

# ── Result ────────────────────────────────────────────────────────────────────
if errors:
    for e in errors:
        print(f"ERROR {e}")
    sys.exit(1)

print("OK  all devcontainer checks passed")
