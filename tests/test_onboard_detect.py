"""Tests for new and changed consumer onboarding detection."""

import importlib.util
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "scripts" / "onboard-detect.py"
SPEC = importlib.util.spec_from_file_location("onboard_detect", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def test_changed_managed_consumer_is_reonboarded_and_owner_prefix_removed():
    old = """
consumers:
  - name: Interested-Deving-1896/Interested-Deving-1896
    tier: managed
    profile: readme-profile
    skip_osp_setup: true
"""
    new = """
consumers:
  - name: Interested-Deving-1896/Interested-Deving-1896
    tier: managed
    profile: readme-profile
"""
    assert MODULE.detect(None, None, old, new) == [
        {
            "name": "Interested-Deving-1896",
            "profile": "readme-profile",
            "upstream_url": "",
        }
    ]


def test_new_protected_and_delegated_destinations_are_not_onboarded():
    old = "consumers: []\n"
    new = """
consumers:
  - name: OpenOS-Project-OSP/Interested-Deving-1896
    tier: protected
    profile: readme-profile
  - name: OpenOS-Project-Ecosystem-OOC/Interested-Deving-1896
    tier: protected
    profile: readme-profile
  - name: OpenOS-Project-OSP/OpenOS-Project-OSP
    tier: delegated
    profile: readme-profile
"""
    assert MODULE.detect(None, None, old, new) == []


def test_new_managed_consumer_is_detected_once():
    old = "consumers: []\n"
    new = """
consumers:
  - name: Incus-Engine-Subsystem
    tier: managed
    profile: infra-core
"""
    assert MODULE.detect(None, None, old, new) == [
        {
            "name": "Incus-Engine-Subsystem",
            "profile": "infra-core",
            "upstream_url": "",
        }
    ]


def test_new_registered_import_is_detected():
    old = '[{"target_name":"existing","source_url":"https://example.test/existing"}]'
    new = """[
      {"target_name":"existing","source_url":"https://example.test/existing"},
      {"target_name":"new-project","source_url":"https://example.test/new-project"}
    ]"""
    assert MODULE.detect(old, new, None, None) == [
        {
            "name": "new-project",
            "profile": "",
            "upstream_url": "https://example.test/new-project",
        }
    ]
