#!/usr/bin/env python3
"""
Applies brand substitutions to a file's content.

Reads config/brand.yml and replaces {{FSA_*}} tokens in the given file.
Used by sync-template.sh when propagating files to branded consumer repos.

Usage:
  python3 scripts/apply-brand.py <file_path>
  python3 scripts/apply-brand.py --stdin   (reads from stdin, writes to stdout)

Exits 0 always — branding is best-effort; missing tokens are left as-is.
"""
import sys
import yaml

BRAND_CONFIG = "config/brand.yml"

TOKEN_MAP = {
    "{{FSA_NAME}}":        ("brand", "name"),
    "{{FSA_SLUG}}":        ("brand", "slug"),
    "{{FSA_ORG}}":         ("brand", "org"),
    "{{FSA_REPO}}":        ("brand", "repo"),
    "{{FSA_DESCRIPTION}}": ("brand", "description"),
    "{{FSA_SUPPORT_URL}}": ("brand", "support_url"),
}


def load_brand():
    try:
        d = yaml.safe_load(open(BRAND_CONFIG))
        return d or {}
    except Exception:
        return {}


def apply_brand(content: str, brand_cfg: dict) -> str:
    brand = brand_cfg.get("brand") or {}
    if not brand.get("enabled"):
        return content
    for token, (section, key) in TOKEN_MAP.items():
        value = brand_cfg.get(section, {}).get(key, "")
        if value:
            content = content.replace(token, str(value))
    return content


def main():
    brand_cfg = load_brand()

    if len(sys.argv) > 1 and sys.argv[1] == "--stdin":
        content = sys.stdin.read()
        sys.stdout.write(apply_brand(content, brand_cfg))
        return

    if len(sys.argv) < 2:
        print("Usage: apply-brand.py <file_path> | --stdin", file=sys.stderr)
        sys.exit(1)

    path = sys.argv[1]
    try:
        content = open(path).read()
    except OSError as e:
        print(f"apply-brand: cannot read {path}: {e}", file=sys.stderr)
        sys.exit(0)  # non-fatal

    result = apply_brand(content, brand_cfg)
    open(path, "w").write(result)


if __name__ == "__main__":
    main()
