#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise Codex agent generation and skill links in disposable repositories."""

import contextlib
import importlib.util
import io
import tempfile
try:
    import tomllib
except ImportError:
    tomllib = None
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("codex_support", Path(__file__).with_name("codex-support.py"))
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)


class CodexSupportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="codex harness ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / ".claude/agents/reviewer.md"
        self.source.parent.mkdir(parents=True)
        self.source.write_text('---\nname: reviewer\ndescription: Reviews "quoted" paths\n'
                               'model: sonnet\ntools: Read, Bash\n---\n\n'
                               'Read `CLAUDE.md`. Keep \\paths and "quotes" intact.\n')
        self.skill = self.root / ".claude/skills/workflow"
        self.skill.mkdir(parents=True)
        (self.skill / "SKILL.md").write_text("---\nname: workflow\ndescription: Shared procedure\n---\nRead me.\n")
        with contextlib.redirect_stdout(io.StringIO()):
            support.write(self.root)

    def verdict(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return support.check(self.root)

    @unittest.skipIf(tomllib is None, "TOML parsing requires Python 3.11; other checks run on 3.9")
    def test_prompt_round_trips_without_claude_configuration(self):
        agent = tomllib.loads((self.root / ".codex/agents/reviewer.toml").read_text())
        self.assertEqual(set(agent), {"name", "description", "developer_instructions"})
        self.assertEqual(agent["description"], 'Reviews "quoted" paths')
        self.assertEqual(agent["developer_instructions"], self.source.read_text().split("---\n", 2)[2].lstrip("\n"))
        self.assertEqual(self.verdict(), 0)

    def test_regeneration_leaves_claude_sources_unchanged(self):
        before = {p: p.read_bytes() for p in (self.root / ".claude").rglob("*") if p.is_file()}
        with contextlib.redirect_stdout(io.StringIO()):
            support.write(self.root)
        after = {p: p.read_bytes() for p in (self.root / ".claude").rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_source_edits_fail_check_without_rewriting_generated_agent(self):
        target = self.root / ".codex/agents/reviewer.toml"
        before = target.read_bytes()
        self.source.write_text(self.source.read_text() + "New rule.\n")
        self.assertEqual(self.verdict(), 1)
        self.assertEqual(target.read_bytes(), before)

    def test_skill_edit_is_shared_and_broken_link_fails(self):
        link = self.root / ".agents/skills/workflow"
        self.assertFalse(Path(link.readlink()).is_absolute())
        (self.skill / "SKILL.md").write_text("Updated shared procedure")
        self.assertEqual((link / "SKILL.md").read_text(), "Updated shared procedure")
        link.unlink()
        link.symlink_to("missing")
        self.assertEqual(self.verdict(), 1)

    def test_writer_preserves_copied_skills(self):
        link = self.root / ".agents/skills/workflow"
        link.unlink()
        link.mkdir()
        (link / "SKILL.md").write_text("Local work")
        with self.assertRaisesRegex(ValueError, "reconcile"):
            support.write(self.root)
        self.assertEqual((link / "SKILL.md").read_text(), "Local work")

    def test_renamed_skill_does_not_leave_a_broken_discovery_link(self):
        self.skill.rename(self.skill.with_name("renamed"))
        self.assertEqual(self.verdict(), 1)
        with contextlib.redirect_stdout(io.StringIO()):
            support.write(self.root)
        self.assertFalse((self.root / ".agents/skills/workflow").is_symlink())
        self.assertTrue((self.root / ".agents/skills/renamed/SKILL.md").is_file())

    def test_renamed_agent_is_removed_but_personal_agent_is_preserved(self):
        self.source.rename(self.source.with_name("renamed.md"))
        personal = self.root / ".codex/agents/personal.toml"
        personal.write_text('name = "personal"\n')
        self.assertEqual(self.verdict(), 1)
        with contextlib.redirect_stdout(io.StringIO()):
            support.write(self.root)
        self.assertFalse((self.root / ".codex/agents/reviewer.toml").exists())
        self.assertTrue(personal.exists())

    def test_refresh_preserves_project_hooks(self):
        hooks = self.root / ".codex/hooks.json"
        hooks.write_text('{"hooks":{"Stop":[]}}')
        with contextlib.redirect_stdout(io.StringIO()):
            support.write(self.root)
        self.assertEqual(hooks.read_text(), '{"hooks":{"Stop":[]}}')


if __name__ == "__main__":
    unittest.main()
