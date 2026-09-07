#!/usr/bin/env python3
"""Seed claude-local's isolated CLAUDE_CONFIG_DIR from the real one.

Usage: seed_config.py ~/.claude.json <isolated>/.claude.json

`claude-local` runs Claude Code with its own CLAUDE_CONFIG_DIR so that no
claude.ai login is stored there and no OAuth refresh is attempted against the
local server. That dir starts empty, which would mean re-running onboarding and
re-answering the folder-trust prompt for folders already trusted.

This copies forward exactly two things:

* the onboarding flags, so first-run setup does not repeat;
* `hasTrustDialogAccepted` for folders the real config already records as
  trusted. No new trust is granted -- a folder never trusted still prompts.

Everything else in the isolated config stays independent, including session
history, so local-model transcripts do not mix with the ones from the hosted
Claude Code. Idempotent: existing values in the destination are left alone.
"""
import json
import os
import sys

ONBOARDING_KEYS = ("hasCompletedOnboarding", "theme", "installMethod", "autoUpdates")


def load(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def main():
    if len(sys.argv) != 3:
        print(__doc__.splitlines()[2], file=sys.stderr)
        return 2
    src_path, dst_path = sys.argv[1], sys.argv[2]

    src = load(src_path)
    if not src:
        # No real config to copy from; Claude Code will onboard normally.
        return 0
    dst = load(dst_path)

    for key in ONBOARDING_KEYS:
        if key in src and key not in dst:
            dst[key] = src[key]

    projects = dst.setdefault("projects", {})
    for path, entry in (src.get("projects") or {}).items():
        if isinstance(entry, dict) and entry.get("hasTrustDialogAccepted"):
            existing = projects.setdefault(path, {})
            if isinstance(existing, dict):
                existing["hasTrustDialogAccepted"] = True

    parent = os.path.dirname(dst_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    tmp = dst_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(dst, f, indent=2)
    os.replace(tmp, dst_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
