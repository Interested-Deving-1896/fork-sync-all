"""Tests for the Markdown-aware external-link checker."""

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import sys
import tempfile
import unittest
from urllib.error import HTTPError


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "check-markdown-links.py"


def load_module():
    spec = spec_from_file_location("check_markdown_links", SCRIPT)
    assert spec and spec.loader
    module = module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class Response:
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def getcode(self):
        return self.status

    def read(self, _count):
        return b"x"


class MarkdownLinksTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()

    def test_extracts_markdown_reference_autolink_and_html_anchor(self):
        content = """# Links

[inline](https://example.com/a_(b) "title")
[reference][docs]
[docs]: <https://example.com/reference>
<https://example.com/auto>
<a href="https://example.com/html">HTML</a>
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "README.md"
            path.write_text(content, encoding="utf-8")
            urls = {item.url for item in self.module.extract_links(path)}
        self.assertEqual(
            urls,
            {
                "https://example.com/a_(b)",
                "https://example.com/reference",
                "https://example.com/auto",
                "https://example.com/html",
            },
        )

    def test_ignores_code_comments_images_and_local_anchors(self):
        content = """[local](#section)
![badge](https://example.com/image.svg)
`[inline code](https://example.com/no-inline)`
<!-- [comment](https://example.com/no-comment) -->

```markdown
[fenced](https://example.com/no-fence)
```

    [indented](https://example.com/no-indent)
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "README.md"
            path.write_text(content, encoding="utf-8")
            self.assertEqual(self.module.extract_links(path), [])

    def test_transient_status_retries_then_succeeds(self):
        calls = []

        def opener(request, timeout):
            calls.append((request.full_url, timeout))
            if len(calls) == 1:
                raise HTTPError(request.full_url, 503, "busy", {}, None)
            return Response()

        result = self.module.check_url(
            "https://example.com", 3.0, 2, 0.0, opener=opener, sleeper=lambda _: None
        )
        self.assertEqual(result, (True, 200, 2, ""))

    def test_permanent_status_does_not_retry(self):
        def opener(request, timeout):
            raise HTTPError(request.full_url, 404, "missing", {}, None)

        result = self.module.check_url(
            "https://example.com/missing",
            3.0,
            2,
            0.0,
            opener=opener,
            sleeper=lambda _: None,
        )
        self.assertEqual(result, (False, 404, 1, "HTTP 404"))

    def test_explicitly_allowed_bot_block_status_is_retained(self):
        def opener(request, timeout):
            raise HTTPError(request.full_url, 403, "forbidden", {}, None)

        result = self.module.check_url(
            "https://example.com/bot-protected",
            3.0,
            2,
            0.0,
            opener=opener,
            sleeper=lambda _: None,
            allowed_statuses={403},
        )
        self.assertEqual(result, (True, 403, 1, "allowed status"))


if __name__ == "__main__":
    unittest.main()
