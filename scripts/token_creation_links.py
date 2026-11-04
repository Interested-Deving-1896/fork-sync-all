#!/usr/bin/env python3
"""Generate provider-specific credential links for token rotation alerts."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "config" / "token-creation-profiles.json"
GITHUB_CLASSIC_URL = "https://github.com/settings/tokens/new"
GITHUB_FINE_GRAINED_URL = "https://github.com/settings/personal-access-tokens/new"
GITLAB_PAT_URL = "https://gitlab.com/-/user_settings/personal_access_tokens"

def load_registry(path: Path = REGISTRY) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1 or not isinstance(data.get("profiles"), dict):
        raise ValueError("unsupported token creation profile registry")
    return data

def safe_name(value: str) -> str:
    value = str(value).strip()
    if not value or len(value) > 40:
        raise ValueError("GitHub token names must contain 1-40 characters")
    return value

def build_github_classic_url(profile: dict) -> str:
    scopes = profile.get("classic_scopes", [])
    if not scopes or any(not isinstance(s, str) or not s for s in scopes):
        raise ValueError("classic PAT profile must define explicit scopes")
    return GITHUB_CLASSIC_URL + "?" + urlencode([
        ("description", safe_name(profile["token_name"])),
        ("scopes", ",".join(scopes)),
    ])

def build_github_fine_grained_url(profile: dict, expires_in: int = 90) -> str:
    fine = profile.get("fine_grained", {})
    if fine.get("status") != "supported":
        raise ValueError("fine-grained profile is not approved for drop-in use")
    if not 1 <= int(expires_in) <= 366:
        raise ValueError("fine-grained expiration must be 1-366 days")
    permissions = fine.get("permissions", {})
    if not permissions:
        raise ValueError("fine-grained profile must define audited permissions")
    params = [
        ("name", safe_name(profile["token_name"])),
        ("description", str(profile["description"])[:1024]),
        ("target_name", str(profile["resource_owner"])),
        ("expires_in", str(expires_in)),
    ]
    for permission, level in sorted(permissions.items()):
        if not permission.replace("_", "").isalnum() or level not in {"read", "write", "admin"}:
            raise ValueError(f"invalid fine-grained permission: {permission}={level}")
        params.append((permission, level))
    return GITHUB_FINE_GRAINED_URL + "?" + urlencode(params)

def build_github_url(profile: dict, expires_in: int = 90) -> str:
    token_type = profile.get("token_type", "classic")
    if token_type == "classic":
        return build_github_classic_url(profile)
    if token_type == "fine_grained":
        return build_github_fine_grained_url(profile, expires_in)
    raise ValueError("unsupported GitHub token type: " + str(token_type))

def render_profile(profile_id: str, registry: dict) -> str:
    try:
        profile = registry["profiles"][profile_id]
    except KeyError as exc:
        raise ValueError(f"unknown token profile: {profile_id}") from exc
    if profile["provider"] == "github":
        url = build_github_url(profile)
        if profile.get("token_type", "classic") == "fine_grained":
            permissions = profile["fine_grained"]["permissions"]
            summary = ", ".join(name + ":" + level for name, level in sorted(permissions.items()))
            return "\n".join([
                "- **Create GitHub fine-grained PAT** — [open prefilled form](" + url + ")",
                "  - Name: " + profile["token_name"],
                "  - Description: " + profile["description"],
                "  - Resource owner: " + profile["resource_owner"],
                "  - Permissions: " + summary,
            "  - Select only the required repositories manually; the URL template does not preselect repository selection.",
                "  - **90-day expiry is preselected.** GitHub and organization lifetime policies remain authoritative.",
            ])
        scopes = ", ".join(s for s in profile["classic_scopes"])
        fine = profile.get("fine_grained", {})
        return "\n".join([
            "- **Create GitHub PAT (classic)** — [open prefilled form](" + url + ")",
            "  - Token note/name: " + profile["token_name"],
            "  - Purpose: " + profile["description"],
            "  - Classic scopes: " + scopes,
            "  - **Set expiry to 90 days manually.** The classic link pre-fills the Note and scopes; GitHub does not document an expiry query parameter for classic PATs.",
            "- **Fine-grained migration:** not offered as a drop-in yet (" + fine.get("reason", "permission parity not audited") + ")",
        ])
    if profile["provider"] == "gitlab":
        scopes = ", ".join(profile.get("gitlab_scopes", []))
        return "\n".join([
            "- **Create GitLab personal access token** — [open token settings](" + GITLAB_PAT_URL + ")",
            "  - Suggested name: " + profile["token_name"],
            "  - Suggested scopes: " + scopes,
            "  - Set expiry to 90 days where instance/group policy permits; GitHub URL parameters do not apply.",
        ])
    raise ValueError("unsupported provider: " + str(profile["provider"]))

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", required=True)
    parser.add_argument("--format", choices=("markdown", "json", "url", "compact"), default="markdown")
    args = parser.parse_args()
    registry = load_registry()
    if args.profile not in registry["profiles"]:
        parser.error("unknown token profile: " + args.profile)
    markdown = render_profile(args.profile, registry)
    if args.format == "json":
        print(json.dumps({"profile": args.profile, "default_expiry_days": registry["default_expiry_days"], "markdown": markdown}))
    elif args.format == "url":
        profile = registry["profiles"][args.profile]
        print(build_github_url(profile) if profile["provider"] == "github" else GITLAB_PAT_URL)
    elif args.format == "compact":
        print(markdown.replace("\n", " "))
    else:
        print(markdown)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
