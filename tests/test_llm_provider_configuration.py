"""Regression tests for explicit, provider-neutral LLM configuration."""
from pathlib import Path

LLM_HELPER = Path(__file__).resolve().parents[1] / "scripts" / "includes" / "llm.sh"


def test_llm_helper_has_no_retired_provider_endpoint():
    source = LLM_HELPER.read_text(encoding="utf-8")
    assert "models.github.ai/inference" not in source
    assert "_LLM_MODELS_API" not in source


def test_llm_helper_requires_explicit_provider_config():
    source = LLM_HELPER.read_text(encoding="utf-8")
    assert 'LLM_BASE_URL="${LLM_BASE_URL:-}"' in source
    assert 'LLM_API_KEY="${LLM_API_KEY:-}"' in source
    assert 'MODEL="${MODEL:-}"' in source
    assert 'if [[ -z "$LLM_BASE_URL" || -z "$LLM_API_KEY" || -z "$MODEL" ]]' in source
    assert 'Authorization: Bearer ${LLM_API_KEY}' in source
    assert 'Authorization: Bearer ${GH_TOKEN}' not in source


def test_llm_helper_uses_configured_openai_compatible_endpoint():
    source = LLM_HELPER.read_text(encoding="utf-8")
    assert '"${LLM_BASE_URL%/}/chat/completions"' in source
    assert 'LLM_BASE_URL must be an HTTP(S) URL' in source
