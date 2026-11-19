#!/usr/bin/env python3
"""Print the base image from .devcontainer/devcontainer.json (strips // comments)."""
import json, sys

raw = open('.devcontainer/devcontainer.json').read()
lines = [l for l in raw.splitlines() if not l.strip().startswith('//')]
dc = json.loads('\n'.join(lines))
print(dc.get('image', 'mcr.microsoft.com/devcontainers/base:ubuntu'))
