"""Tests for credential-safe GitLab mirror destination URL validation."""

import pytest

from scripts.gitlab_mirror_url import is_safe_gitlab_repo_url


@pytest.mark.parametrize(
    "url",
    [
        "https://gitlab.com/openos-project/upstream-mirrors/project.git",
        "https://gitlab.com/openos-project/upstream-mirrors/subgroup/project",
        "https://gitlab.com:443/openos-project/upstream-mirrors/project.git",
    ],
)
def test_accepts_gitlab_https_clone_urls(url):
    assert is_safe_gitlab_repo_url(url)


@pytest.mark.parametrize(
    "url",
    [
        "",
        "gitlab.com/openos-project/upstream-mirrors/project.git",
        "http://gitlab.com/openos-project/upstream-mirrors/project.git",
        "https://gitlab.com.evil.invalid/openos-project/upstream-mirrors/project.git",
        "https://evil.invalid/openos-project/upstream-mirrors/project.git",
        "https://gitlab.com@evil.invalid/openos-project/upstream-mirrors/project.git",
        "https://user:pass@gitlab.com/openos-project/upstream-mirrors/project.git",
        "https://gitlab.com:444/openos-project/upstream-mirrors/project.git",
        "https://gitlab.com/openos-project/upstream-mirrors/project.git?redirect=evil.invalid",
        "https://gitlab.com/openos-project/upstream-mirrors/project.git#fragment",
        "https://gitlab.com:bad-port/openos-project/upstream-mirrors/project.git",
        "https://gitlab.com",
        "https://gitlab.com/other-group/project.git",
        "https://gitlab.com/openos-project/upstream-mirrors/",
        "https://gitlab.com/openos-project/upstream-mirrors/../other-project.git",
        "https://gitlab.com/openos-project/upstream-mirrors/%2e%2e/other-project.git",
        "https://gitlab.com/openos-project/upstream-mirrors/%252e%252e/other-project.git",
        "https://gitlab.com/openos-project/upstream-mirrors/%252f..%252fother-project.git",
        "https://gitlab.com/openos-project%2Fupstream-mirrors/project.git",
        "https://gitlab.com/openos-project/upstream-mirrors%2F..%2Fother-project.git",
        "https://gitlab.com/openos-project/upstream-mirrors/project%0a.git",
        "https://gitlab.com/openos-project/upstream-mirrors/project%7f.git",
        "https://gitlab.com/openos-project/upstream-mirrors/project%00.git",
        None,
        42,
    ],
)
def test_rejects_unsafe_or_malformed_urls(url):
    assert not is_safe_gitlab_repo_url(url)
