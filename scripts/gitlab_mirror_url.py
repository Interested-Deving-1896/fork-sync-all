"""Validate GitLab mirror destinations before credentials are attached."""

from urllib.parse import urlsplit


def is_safe_gitlab_repo_url(value: str) -> bool:
    """Return True only for credential-free HTTPS clone URLs on gitlab.com."""
    if not isinstance(value, str) or not value or any(ord(ch) < 32 for ch in value):
        return False
    try:
        parsed = urlsplit(value)
        # Accessing .port can raise ValueError for malformed ports.
        port = parsed.port
        return (
            parsed.scheme == "https"
            and parsed.hostname == "gitlab.com"
            and parsed.username is None
            and parsed.password is None
            and port in (None, 443)
            and bool(parsed.path.strip("/"))
            and not parsed.query
            and not parsed.fragment
        )
    except ValueError:
        return False
