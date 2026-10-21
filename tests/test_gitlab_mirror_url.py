"""Tests for credential-safe GitLab mirror destination URL validation."""

import pytest

from scripts.gitlab_mirror_url import is_safe_gitlab_repo_url


@pytest.mark.parametrize(
    "url",
    [
        "https://gitlab.com/group/project.git",
        "https://gitlab.com/group/subgroup/project",
        "https://gitlab.com:443/group/project.git",
    ],
)
def test_accepts_gitlab_https_clone_urls(url):
    assert is_safe_gitlab_repo_url(url)


@pytest.mark.parametrize(
    "url",
    [
        "",
        "gitlab.com/group/project.git",
        "http://gitlab.com/group/project.git",
        "https://gitlab.com.evil.invalid/group/project.git",
        "https://evil.invalid/group/project.git",
        "https://gitlab.com@evil.invalid/group/project.git",
        "https://user:pass@gitlab.com/group/project.git",
        "https://gitlab.com:444/group/project.git",
        "https://gitlab.com/group/project.git?redirect=evil.invalid",
        "https://gitlab.com/group/project.git#fragment",
        "https://gitlab.com:bad-port/group/project.git",
        "https://gitlab.com",
        None,
        42,
    ],
)
def test_rejects_unsafe_or_malformed_urls(url):
    assert not is_safe_gitlab_repo_url(url)
