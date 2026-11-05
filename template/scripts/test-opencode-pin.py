#!/usr/bin/env python3
"""Plant foreign models in a copy of the tree and prove opencode-pin.py fails.

    python3 scripts/test-opencode-pin.py

A check that has only ever seen a clean tree is a check nobody knows works.
Each case copies the harness's real opencode.json and scripts into a
throwaway root, plants one foreign model or variant, and expects the check to
name it — then proves the unplanted copy passes, so a failure is the plant's.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
from models import OPENCODE_MODEL, OPENCODE_MODEL_ARG, OPENCODE_VARIANT, ROLES

PINNED = {"model": OPENCODE_MODEL, "variant": OPENCODE_VARIANT}
AGENT = (f"---\ndescription: x\nmodel: {OPENCODE_MODEL_ARG}\nmode: subagent\n---\n\n"
         f"<!-- Generated from .claude/agents/x.md by scripts/opencode-agents.py. -->\n")


class PinCheckTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="opencode pin ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copy(ROOT / "opencode.json", self.root / "opencode.json")
        shutil.copytree(SCRIPTS, self.root / "scripts",
                        ignore=shutil.ignore_patterns("__pycache__"))
        (self.root / "harness").mkdir()
        self.roster({role: PINNED for role in ROLES})
        (self.root / ".opencode/agent").mkdir(parents=True)
        self.agent_file = self.root / ".opencode/agent/reviewer-taste.md"
        self.agent_file.write_text(AGENT)
        # The check also reads user-level agent dirs from HOME. Point HOME at
        # an empty scratch dir so a foreign model in the developer's real
        # ~/.config/opencode can't fail a clean tree.
        self.home = Path(self.temp.name) / "home"
        self.home.mkdir()

    def roster(self, data):
        (self.root / "harness/models.json").write_text(json.dumps(data))

    def config(self, edit):
        path = self.root / "opencode.json"
        tree = json.loads(path.read_text())
        edit(tree)
        path.write_text(json.dumps(tree))

    def check(self):
        env = {**os.environ, "HOME": str(self.home)}
        return subprocess.run([sys.executable, str(SCRIPTS / "opencode-pin.py"),
                               "check", str(self.root)],
                              capture_output=True, text=True, env=env)

    def assert_fails_naming(self, *needles):
        out = self.check()
        self.assertEqual(out.returncode, 1, out.stdout)
        for needle in needles:
            self.assertIn(needle, out.stdout)

    def test_the_unplanted_copy_passes(self):
        out = self.check()
        self.assertEqual(out.returncode, 0, out.stdout)
        self.assertIn(f"pinned to {OPENCODE_MODEL_ARG}", out.stdout)

    def test_no_roster_passes(self):
        (self.root / "harness/models.json").unlink()
        self.assertEqual(self.check().returncode, 0)

    def test_a_foreign_roster_model_fails(self):
        self.roster({"implement": {"model": "opencode-go/cheap-bulk",
                                   "variant": OPENCODE_VARIANT}})
        self.assert_fails_naming("harness/models.json", "opencode-go/cheap-bulk")

    def test_a_roster_variant_mismatch_fails(self):
        self.roster({"reviewer-taste": {"model": OPENCODE_MODEL, "variant": "low"}})
        self.assert_fails_naming("harness/models.json", "'low'")

    def test_an_unreadable_roster_fails(self):
        (self.root / "harness/models.json").write_text("{nope")
        self.assert_fails_naming("unreadable")

    def test_a_foreign_agent_file_model_fails(self):
        self.agent_file.write_text(AGENT.replace(OPENCODE_MODEL_ARG, "ollama/qwen3:4b"))
        self.assert_fails_naming("reviewer-taste.md", "ollama/qwen3:4b")

    def test_an_agent_file_variant_mismatch_fails(self):
        self.agent_file.write_text(AGENT.replace(OPENCODE_MODEL_ARG,
                                                 f"{OPENCODE_MODEL}#low"))
        self.assert_fails_naming("reviewer-taste.md", "#low")

    def test_a_foreign_agent_in_the_plural_directory_fails(self):
        # opencode 2 reads .opencode/agents/ as well as .opencode/agent/.
        plural = self.root / ".opencode/agents"
        plural.mkdir()
        (plural / "bulk.md").write_text("---\nmodel: ollama/qwen3:4b\nmode: subagent\n---\n")
        self.assert_fails_naming(".opencode/agents/bulk.md", "ollama/qwen3:4b")

    def test_a_generated_agent_without_a_model_line_fails(self):
        self.agent_file.write_text(AGENT.replace(f"model: {OPENCODE_MODEL_ARG}\n", ""))
        self.assert_fails_naming("reviewer-taste.md", "no model line")

    def test_a_foreign_session_model_in_opencode_json_fails(self):
        self.config(lambda t: t.update(model="opencode-go/cheap-bulk"))
        self.assert_fails_naming("opencode.json", "opencode-go/cheap-bulk")

    def test_a_missing_session_pin_fails(self):
        self.config(lambda t: t.pop("model"))
        self.assert_fails_naming("no top-level model")

    def test_a_foreign_agent_in_opencode_json_fails(self):
        for group in ("agent", "agents", "mode"):
            with self.subTest(group=group):
                shutil.copy(ROOT / "opencode.json", self.root / "opencode.json")
                self.config(lambda t: t.setdefault(group, {}).update(
                    general={"model": "opencode-go/cheap-bulk"}))
                self.assert_fails_naming(f"{group}.general")

    def test_an_agent_variant_mismatch_in_opencode_json_fails(self):
        self.config(lambda t: t["agent"]["build"].update(variant="low"))
        self.assert_fails_naming("agent.build")

    def test_an_explicit_null_agent_variant_in_opencode_json_fails(self):
        # An explicit null is a present variant that isn't the pin — the
        # merge-writer pins it up, so the gate must flag it until then.
        self.config(lambda t: t["agent"]["build"].update(variant=None))
        self.assert_fails_naming("agent.build")

    def test_a_foreign_shadow_config_fails(self):
        (self.root / ".opencode/opencode.json").write_text(
            json.dumps({"model": "opencode-go/cheap-bulk"}))
        self.assert_fails_naming(".opencode/opencode.json")

    def test_jsonc_comments_and_trailing_commas_parse(self):
        (self.root / ".opencode/opencode.jsonc").write_text(
            '{\n  // local plugin\n  "plugin": ["https://x.test/p"], // trailing\n'
            '  /* block */ "theme": "x",\n}\n')
        out = self.check()
        self.assertEqual(out.returncode, 0, out.stdout)
        (self.root / ".opencode/opencode.jsonc").write_text(
            '{\n  "model": "opencode-go/cheap-bulk", // bulk\n}\n')
        self.assert_fails_naming(".opencode/opencode.jsonc", "cheap-bulk")

    def test_a_script_building_its_own_model_flag_fails(self):
        planted = self.root / "scripts/spawn.py"
        planted.write_text('import subprocess\nsubprocess.run(["opencode", "run", '
                           '"-m", "opencode-go/cheap-bulk", "go"])\n')
        self.assert_fails_naming("scripts/spawn.py:2")

    def test_a_shell_script_passing_a_model_fails(self):
        planted = self.root / "scripts/spawn.sh"
        planted.write_text("#!/bin/bash\nopencode run -m opencode-go/cheap-bulk go\n")
        self.assert_fails_naming("scripts/spawn.sh:2")

    def test_a_foreign_user_level_agent_fails(self):
        foreign = self.home / ".config/opencode/agents"
        foreign.mkdir(parents=True)
        (foreign / "bulk.md").write_text(
            "---\nmodel: ollama/qwen3:4b\nmode: subagent\n---\n")
        self.assert_fails_naming("bulk.md", "ollama/qwen3:4b")

    def test_a_pinned_user_level_agent_passes(self):
        agent = self.home / ".opencode/agents"
        agent.mkdir(parents=True)
        (agent / "ok.md").write_text(AGENT)
        out = self.check()
        self.assertEqual(out.returncode, 0, out.stdout)

    def test_a_doc_example_naming_another_model_fails(self):
        (self.root / "AGENTS.local.md").write_text(
            "Run `opencode run -m opencode-go/cheap-bulk` for bulk work.\n")
        self.assert_fails_naming("AGENTS.local.md:1", "opencode-go/cheap-bulk")


if __name__ == "__main__":
    unittest.main()
