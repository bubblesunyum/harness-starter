#!/usr/bin/env python3
"""Starter-only probe for shared opencode agents: the starter generates the
shared side once, and reference projects link rather than regenerate.

    python3 scripts/test-shared-agents.py

Hermetic by construction: every shape builds its own throwaway roots, never
the live tree, so parallel edits can't flake it. Uses the real
template/scripts/opencode-agents.py with HARNESS_PROJECT/HARNESS_ROOT pointed
at the fixtures.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

THIS = Path(__file__).resolve()
REPO = THIS.parent.parent
SCRIPT = REPO / "template/scripts/opencode-agents.py"
MODELS_SRC = REPO / "template/scripts/models.py"
PATHS_SRC = REPO / "template/scripts/harness_paths.py"

AGENT_SRC = ("---\nname: {name}\ndescription: Probe {name}\n"
             "tools: Read, Bash\n---\n\nProbe body for {name}.\n")


def run_script(action, root, harness):
    """Run the real generator with fixture roots, returning CompletedProcess."""
    env = dict(os.environ, HARNESS_PROJECT=str(root),
               HARNESS_ROOT=str(harness))
    return subprocess.run([sys.executable, str(SCRIPT), action],
                          capture_output=True, text=True, env=env)


def plant_scripts(root):
    """Give a fixture root the siblings the generator imports."""
    scripts = root / "scripts"
    scripts.mkdir(parents=True, exist_ok=True)
    for src in (MODELS_SRC, PATHS_SRC):
        shutil.copy(src, scripts / src.name)


class SharedAgentsTests(unittest.TestCase):
    def setUp(self):
        if not SCRIPT.is_file() or not (REPO / "template/.claude/agents").is_dir():
            self.skipTest("starter-only: no template/ checkout here")
        self.temp = tempfile.TemporaryDirectory(prefix="shared agents ")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)

    def test_starter_generates_and_checks_shared_side(self):
        root = self.base / "root"
        harness = root / "template"
        for base, name in ((root, "proj"), (harness, "shared")):
            agents = base / ".claude/agents"
            agents.mkdir(parents=True)
            (agents / f"{name}.md").write_text(AGENT_SRC.format(name=name))
            plant_scripts(base if base == harness else root)
        # plant_scripts for both roots (root/scripts covers ROOT, harness/scripts HARNESS)
        plant_scripts(root)
        plant_scripts(harness)
        out = run_script("write", root, harness)
        self.assertEqual(out.returncode, 0, out.stderr + out.stdout)
        for base, name in ((root, "proj"), (harness, "shared")):
            dest = base / ".opencode/agent" / f"{name}.md"
            self.assertTrue(dest.is_file(), f"missing {dest}")
            text = dest.read_text()
            self.assertIn("scripts/harness opencode-agents", text)
            self.assertIn("model: ", text)
        out = run_script("check", root, harness)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("ok", out.stdout)

    def test_reference_symlinks_pass_check_and_survive_write(self):
        harness = self.base / "harness"
        root = self.base / "proj"
        agents = harness / ".claude/agents"
        agents.mkdir(parents=True)
        (agents / "a.md").write_text(AGENT_SRC.format(name="a"))
        plant_scripts(harness)
        plant_scripts(root)
        out = run_script("write", harness, harness)
        self.assertEqual(out.returncode, 0, out.stderr + out.stdout)
        shared_dest = harness / ".opencode/agent/a.md"
        self.assertTrue(shared_dest.is_file())
        before_target = shared_dest.read_text()
        # The project carries links into the harness, the way `h link` leaves them.
        (root / ".claude/agents").mkdir(parents=True)
        (root / ".claude/agents/a.md").symlink_to(harness / ".claude/agents/a.md")
        opener = root / ".opencode/agent"
        opener.mkdir(parents=True)
        (opener / "a.md").symlink_to(shared_dest)
        out = run_script("check", root, harness)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        snapshot = [(p.name, p.is_symlink(),
                     os.readlink(p) if p.is_symlink() else None)
                    for p in sorted(opener.glob("*.md"))]
        out = run_script("write", root, harness)
        self.assertEqual(out.returncode, 0, out.stderr + out.stdout)
        after = [(p.name, p.is_symlink(),
                  os.readlink(p) if p.is_symlink() else None)
                 for p in sorted(opener.glob("*.md"))]
        self.assertEqual(after, snapshot, "write touched the linked entries")
        self.assertTrue((opener / "a.md").is_symlink(), "link became a real file")
        self.assertEqual(shared_dest.read_text(), before_target,
                         "write reached through the link into the harness")
        out = run_script("check", root, harness)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)

    def test_dangling_linked_agent_fails_check(self):
        harness = self.base / "harness"
        root = self.base / "proj"
        agents = harness / ".claude/agents"
        agents.mkdir(parents=True)
        (agents / "a.md").write_text(AGENT_SRC.format(name="a"))
        plant_scripts(harness)
        plant_scripts(root)
        out = run_script("write", harness, harness)
        self.assertEqual(out.returncode, 0, out.stderr + out.stdout)
        shared_dest = harness / ".opencode/agent/a.md"
        self.assertTrue(shared_dest.is_file())
        (root / ".claude/agents").mkdir(parents=True)
        (root / ".claude/agents/a.md").symlink_to(harness / ".claude/agents/a.md")
        opener = root / ".opencode/agent"
        opener.mkdir(parents=True)
        (opener / "a.md").symlink_to(shared_dest)
        out = run_script("check", root, harness)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        # The shared agent is deleted: the project's link dangles.
        shared_dest.unlink()
        self.assertTrue((opener / "a.md").is_symlink())
        self.assertFalse((opener / "a.md").exists())
        out = run_script("check", root, harness)
        self.assertNotEqual(out.returncode, 0, "dangling linked agent passed")
        self.assertIn("a.md", out.stdout)
        self.assertIn("scripts/harness link", out.stdout)

    def test_dangling_claude_source_fails_check(self):
        harness = self.base / "harness"
        root = self.base / "proj"
        agents = harness / ".claude/agents"
        agents.mkdir(parents=True)
        (agents / "a.md").write_text(AGENT_SRC.format(name="a"))
        plant_scripts(harness)
        plant_scripts(root)
        out = run_script("write", harness, harness)
        self.assertEqual(out.returncode, 0, out.stderr + out.stdout)
        # A broken starter commit: the source itself is a dangling link with
        # no agent yet. check must fail loudly, never ok over the gap.
        (root / ".claude/agents").mkdir(parents=True)
        (root / ".claude/agents/a.md").symlink_to(
            harness / ".claude/agents/no-such.md")
        (root / ".opencode/agent").mkdir(parents=True)
        out = run_script("check", root, harness)
        self.assertNotEqual(out.returncode, 0, "dangling source passed")
        self.assertIn("does not resolve", out.stdout + out.stderr)

    def test_stale_shared_agent_fails_check(self):
        root = self.base / "root"
        harness = root / "template"
        for base, name in ((root, "proj"), (harness, "shared")):
            agents = base / ".claude/agents"
            agents.mkdir(parents=True)
            (agents / f"{name}.md").write_text(AGENT_SRC.format(name=name))
        plant_scripts(root)
        plant_scripts(harness)
        out = run_script("write", root, harness)
        self.assertEqual(out.returncode, 0, out.stderr + out.stdout)
        stale = harness / ".opencode/agent/shared.md"
        stale.write_text(stale.read_text() + "\ndrift\n")
        out = run_script("check", root, harness)
        self.assertNotEqual(out.returncode, 0, "stale shared agent passed")
        self.assertIn("AGENT", out.stdout)


if __name__ == "__main__":
    unittest.main()
