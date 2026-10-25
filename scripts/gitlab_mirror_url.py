"""Validate GitLab mirror destinations before credentials are attached."""

import re
from urllib.parse import unquote, urlsplit


_GROUP = ("", "openos-project", "upstream-mirrors")


def is_safe_gitlab_repo_url(value: str) -> bool:
    """Accept only safe HTTPS clone URLs inside the designated mirror group."""
    if not isinstance(value, str) or not value or any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        return False
    try:
        parsed = urlsplit(value)
        port = parsed.port  # Raises ValueError for malformed ports.
        raw_path = parsed.path
        decoded_path = unquote(raw_path, errors="strict")
        # Encoded control characters are dangerous too: validate the path after
        # decoding, before the URL is used as a credential-bearing destination.
        if any(ord(ch) < 32 or ord(ch) == 127 for ch in decoded_path):
            return False
        raw_lower = raw_path.lower()
        # Reject encoded separators and residual escapes that could be decoded
        # by another URL layer (including double-encoded traversal).
        unsafe_path_encoding = (
            "%2f" in raw_lower
            or "%5c" in raw_lower
            or re.search(r"%[0-9a-f]{2}", decoded_path.lower()) is not None
            or "\\" in raw_path
            or "\\" in decoded_path
        )
        segments = decoded_path.split("/")
        safe_path = (
            not unsafe_path_encoding
            and all(segment not in (".", "..") for segment in segments)
            and len(segments) >= 4
            and tuple(segments[:3]) == _GROUP
            and bool(segments[3])
        )
        return (
            parsed.scheme == "https"
            and parsed.hostname == "gitlab.com"
            and parsed.username is None
            and parsed.password is None
            and port in (None, 443)
            and not parsed.query
            and not parsed.fragment
            and safe_path
        )
    except (ValueError, UnicodeDecodeError):
        return False
