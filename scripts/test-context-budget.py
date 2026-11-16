#!/usr/bin/env python3
"""Starter-only probe for context.py's copy/reference budget split.

    python3 scripts/test-context-budget.py

Hermetic by construction: every shape builds its own throwaway roots, never
the live tree, so parallel edits can't flake it. Uses the real
template/scripts/context.py with HARNESS_PROJECT/HARNESS_ROOT pointed at the
fixtures.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

THIS = Path(__file__).resolve()
REPO = THIS.parent.parent
CONTEXT_DIR = REPO / "template/scripts"

FAKE_BRIEF = "#!/bin/bash\necho 'fake brief output words for the budget probe'\n"


def run_budget(root, harness, home):
    """(reference, parts, total, stderr) for the fixture roots."""
    env = dict(os.environ, HARNESS_PROJECT=str(root),
               HARNESS_ROOT=str(harness), HOME=str(home))
    code = ("import sys, json; sys.path.insert(0, %r);"
            "import context;"
            "ref = context.is_reference();"
            "parts, total = context.budget();"
            "print(json.dumps({'reference': ref, 'parts': parts, 'total': total}))"
            % str(CONTEXT_DIR))
    proc = subprocess.run([sys.executable, "-c", code],
                          capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        raise AssertionError("budget crashed: " + proc.stderr + proc.stdout)
    payload = json.loads(proc.stdout)
    return payload["reference"], payload["parts"], payload["total"], proc.stderr


def snapshot(root):
    """Every path under root, so a budget that writes or links fails the test."""
    found = []
    for path in sorted(root.rglob("*")):
        rel = str(path.relative_to(root))
        if path.is_symlink():
            found.append((rel, "link", os.readlink(path)))
        elif path.is_dir():
            found.append((rel, "dir", None))
        else:
            found.append((rel, "file", None))
    return found


def tokens_of(text):
    return round(len(text) / 4)


class ContextBudgetTests(unittest.TestCase):
    def setUp(self):
        if not (CONTEXT_DIR / "context.py").is_file():
            self.skipTest("starter-only: no template/ checkout here")
        self.temp = tempfile.TemporaryDirectory(prefix="context budget ")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.home = self.base / "home"
        self.home.mkdir()

    def test_dispatched_copy_counts_as_copy_and_runs_no_finder(self):
        root = self.base / "copy-proj"
        harness = self.base / "copy-harness"
        (root / "scripts").mkdir(parents=True)
        (root / "scripts/brief.sh").write_text(FAKE_BRIEF)
        marker = root / "H_WAS_RUN"
        (root / "scripts/h").write_text(
            "#!/bin/bash\ntouch %s\n" % marker)
        (root / "AGENTS.md").write_text("copy stub agents words here\n")
        (root / "CLAUDE.md").write_text("copy claude words here\n")
        (harness / "scripts").mkdir(parents=True)
        (harness / "AGENTS.md").write_text(
            "shared contract words that must not be counted " * 20 + "\n")
        before = snapshot(root)
        ref, parts, total, _ = run_budget(root, harness, self.home)
        self.assertFalse(ref, "a copy carrying its own brief.sh is not a reference")
        names = [name for name, _ in parts]
        self.assertIn("session brief", names)
        self.assertIn("skill descriptions", names)
        self.assertNotIn("AGENTS.md (contract)", names)
        self.assertNotIn("AGENTS.md stub", names)
        self.assertFalse(any("h session" in name for name in names),
                         "the finder must never run from context.py")
        brief_out = "fake brief output words for the budget probe\n"
        want = (tokens_of("copy stub agents words here\n")
                + tokens_of("copy claude words here\n")
                + tokens_of(brief_out))
        self.assertEqual(dict(parts)["session brief"], tokens_of(brief_out))
        self.assertEqual(total, want, "the outside harness contract must not count")
        self.assertFalse(marker.exists(), "scripts/h ran during a read-only check")
        self.assertEqual(snapshot(root), before, "budget created a file or link")

    def test_reference_shape_counts_contract_once_and_runs_no_finder(self):
        harness = self.base / "ref-harness"
        root = self.base / "ref-proj"
        contract = "shared contract words for the reference probe " * 10 + "\n"
        (harness / "AGENTS.md").parent.mkdir(parents=True, exist_ok=True)
        (harness / "AGENTS.md").write_text(contract)
        (harness / "scripts").mkdir(parents=True)
        (harness / "scripts/brief.sh").write_text(FAKE_BRIEF)
        skill = harness / ".claude/skills/demo"
        skill.mkdir(parents=True)
        (skill / "SKILL.md").write_text(
            "---\ndescription: demo skill for budget\n---\n\nbody\n")
        (root / "scripts").mkdir(parents=True)
        marker = root / "H_WAS_RUN"
        (root / "scripts/h").write_text(
            "#!/bin/bash\ntouch %s\n" % marker)
        self.assertFalse((root / "scripts/brief.sh").exists())
        (root / "AGENTS.md").write_text("thin stub words here\n")
        (root / "CLAUDE.md").write_text("project claude words here\n")
        linked = root / ".claude/skills/demo"
        linked.parent.mkdir(parents=True)
        linked.symlink_to(skill)
        before = snapshot(root)
        ref, parts, total, _ = run_budget(root, harness, self.home)
        self.assertTrue(ref, "harness outside plus no brief.sh is a reference")
        names = [name for name, _ in parts]
        self.assertEqual(names.count("AGENTS.md (contract)"), 1,
                         "the shared contract counts exactly once")
        self.assertIn("AGENTS.md stub", names)
        self.assertFalse(any("h session" in name for name in names),
                         "the finder must never run from context.py")
        brief_out = "fake brief output words for the budget probe\n"
        want_parts = {
            "AGENTS.md (contract)": tokens_of(contract),
            "AGENTS.md stub": tokens_of("thin stub words here\n"),
            "CLAUDE.md": tokens_of("project claude words here\n"),
            "session brief": tokens_of(brief_out),
            "skill descriptions (via links)":
                tokens_of("demo skill for budget"),
        }
        for name, want in want_parts.items():
            self.assertIn(name, names, "missing budget part: %s" % name)
            self.assertEqual(dict(parts)[name], want, "wrong count for %s" % name)
        self.assertEqual(total, sum(want_parts.values()))
        self.assertFalse(marker.exists(), "scripts/h ran during a read-only check")
        self.assertEqual(snapshot(root), before, "budget created a file or link")


if __name__ == "__main__":
    unittest.main()
