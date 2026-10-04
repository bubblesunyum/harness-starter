#!/usr/bin/env python3
"""Exercise preserved project guidance and memory-safe installer exports.

Uses an isolated bd double that reproduces memory-less auto-flush on every
invocation. No command touches the starter's live ledger.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SCRATCH = ROOT / ".tmp"
FAKE_BD = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
ledger = Path('.beads')
state_path = ledger / 'fixture.json'
state = json.loads(state_path.read_text()) if state_path.exists() else {
    'auto': True, 'issues': [{'_type': 'issue', 'id': 'fix-1'}],
    'memories': [{'_type': 'memory', 'key': 'fixture', 'value': 'keep me'}]}
with Path(os.environ['FIXTURE_LOG']).open('a') as log:
    log.write(json.dumps({'args': args, 'auto_override': os.getenv('BD_EXPORT_AUTO'),
                          'import_override': os.getenv('BD_IMPORT_AUTO')}) + '\n')
def export(path, memories):
    rows = state['issues'] + (state['memories'] if memories else [])
    Path(path).write_text(''.join(json.dumps(row) + '\n' for row in rows))
if ledger.exists() and state['auto'] and os.getenv('BD_EXPORT_AUTO') != 'false':
    export(ledger / 'issues.jsonl', False)
if args[0] == 'init':
    (ledger / 'embeddeddolt').mkdir(parents=True, exist_ok=True)
    (ledger / 'config.yaml').write_text('export:\n  auto: true\n')
elif args[0] == 'list':
    print(json.dumps(state['issues']))
elif args[:3] == ['config', 'get', 'issue_prefix']:
    print('fix')
elif args[:3] == ['config', 'set', 'export.auto']:
    if os.getenv('FIXTURE_CONFIG_FAIL'):
        sys.exit(1)
    state['auto'] = False
    (ledger / 'config.yaml').write_text('export:\n  auto: false\n')
elif args[0] == 'export':
    if os.getenv('FIXTURE_EXPORT_FAIL'):
        sys.exit(1)
    export(args[args.index('-o') + 1], '--include-memories' in args)
elif args[0] == 'mutate':
    state['issues'].append({'_type': 'issue', 'id': 'fix-2'})
elif args[0] == 'import':
    rows = [json.loads(line) for line in Path(args[1]).read_text().splitlines()]
    state['issues'] = [row for row in rows if row['_type'] == 'issue']
    state['memories'] = [row for row in rows if row['_type'] == 'memory']
if ledger.exists():
    state_path.write_text(json.dumps(state))
'''


class InstallPolicyTests(unittest.TestCase):
    def setUp(self):
        SCRATCH.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="install policy ", dir=SCRATCH)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = self.root / "project with spaces"
        self.project.mkdir()
        subprocess.run(["git", "init", "-q", str(self.project)], check=True)
        self.binaries = self.root / "bin"
        self.binaries.mkdir()
        self.bd = self.binaries / "bd"
        self.bd.write_text(FAKE_BD)
        self.bd.chmod(0o755)
        self.log = self.root / "bd-calls.jsonl"
        self.env = {**os.environ, "PATH": str(self.binaries) + os.pathsep + os.environ["PATH"],
                    "FIXTURE_LOG": str(self.log)}
        # An inherited override must not defeat the installer policy.
        self.env["BD_EXPORT_AUTO"] = "true"

    def command(self, name, *args, expected=0, env=None):
        result = subprocess.run(["bash", str(ROOT / "commands" / (name + ".sh")),
                                 *args, str(self.project)], env=env or self.env,
                                cwd=self.project, capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def add(self):
        return self.command("add")

    def export_rows(self):
        return [json.loads(line) for line in
                (self.project / ".beads/issues.jsonl").read_text().splitlines()]

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def shell(self, code):
        return subprocess.run(["bash", "-c", '. "$1"; ' + code, "fixture",
                               str(ROOT / "commands/lib/install.sh"), str(self.project)],
                              capture_output=True, text=True)

    def test_project_guidance_survives_repeat_and_contract_update(self):
        self.add()
        guidance = self.project / "AGENTS.local.md"
        guidance.write_text("Before release, run --full: it includes the browser e2e suite.\n")
        original = guidance.read_bytes()
        agents = self.project / "AGENTS.md"
        self.assertIn("AGENTS.local.md", agents.read_text())
        self.assertIn("scripts/verify.steps.sh", agents.read_text())
        agents.write_text(agents.read_text().replace("Start every session", "Old contract"))
        out = self.add()
        self.assertNotIn("AGENTS.local.md exists and differs", out)
        self.assertEqual(guidance.read_bytes(), original)
        self.command("update", "--apply")
        self.assertEqual(guidance.read_bytes(), original)
        self.assertEqual(agents.read_bytes(), (ROOT / "template/AGENTS.md").read_bytes())
        self.command("update")

    def test_fresh_and_existing_install_preserve_memories(self):
        self.add()
        self.assertIn("memory", [row["_type"] for row in self.export_rows()])
        ledger = self.project / ".beads"
        (ledger / "config.yaml").write_text("export.auto: true\n")
        state = json.loads((ledger / "fixture.json").read_text())
        state["auto"] = True
        (ledger / "fixture.json").write_text(json.dumps(state))
        self.add()
        self.assertIn("memory", [row["_type"] for row in self.export_rows()])
        self.assertEqual(self.shell('harness_manual_export_policy "$2"').returncode, 0)
        self.assertTrue(all(call["auto_override"] == "false" for call in self.calls()))
        for call in self.calls():
            if call["args"][0] == "export":
                self.assertIn("--include-memories", call["args"])
                self.assertEqual(call["import_override"], "false")
        # Ordinary mutation and bd's pre-commit path now leave the memories
        # present. The gate/ledger-push export is the explicit refresh boundary.
        env = {key: value for key, value in self.env.items() if key != "BD_EXPORT_AUTO"}
        before = (ledger / "issues.jsonl").read_bytes()
        subprocess.run([str(self.bd), "mutate"], cwd=self.project, env=env, check=True)
        hook = self.project / ".git/hooks/pre-commit"
        hook.write_text('#!/bin/sh\nexec bd precommit\n')
        hook.chmod(0o755)
        subprocess.run(["git", "add", ".beads/issues.jsonl"], cwd=self.project, check=True)
        commit = subprocess.run(["git", "-c", "user.name=Fixture", "-c",
                                 "user.email=fixture@example.invalid", "commit", "-q", "-m",
                                 "preserve fixture memories fix-1"], cwd=self.project, env=env,
                                capture_output=True, text=True)
        self.assertEqual(commit.returncode, 0, commit.stdout + commit.stderr)
        committed = subprocess.check_output(["git", "show", "HEAD:.beads/issues.jsonl"],
                                            cwd=self.project)
        self.assertEqual(committed, before)
        self.assertEqual((ledger / "issues.jsonl").read_bytes(), before)
        self.command("update", "--apply")
        self.assertIn("fix-2", [row.get("id") for row in self.export_rows()])
        self.assertIn("memory", [row["_type"] for row in self.export_rows()])

    def test_report_only_is_read_only_and_apply_repairs_policy(self):
        self.add()
        ledger = self.project / ".beads"
        config = ledger / "config.yaml"
        config.write_text("export:\n  auto: true\n")
        state = json.loads((ledger / "fixture.json").read_text())
        state["auto"] = True
        (ledger / "fixture.json").write_text(json.dumps(state))
        before = {path: path.read_bytes() for path in ledger.iterdir() if path.is_file()}
        log = self.log.read_bytes()
        self.assertIn("auto-export", self.command("update", expected=1))
        self.assertEqual(self.log.read_bytes(), log)
        self.assertEqual(before, {path: path.read_bytes() for path in ledger.iterdir() if path.is_file()})
        self.command("update", "--apply")
        self.command("update")
        self.assertIn("memory", [row["_type"] for row in self.export_rows()])

    def test_policy_accepts_bd_spelling_and_rejects_local_override(self):
        self.add()
        ledger = self.project / ".beads"
        for spelling in ("export.auto: false\n", "export:\n    auto: false\n"):
            (ledger / "config.yaml").write_text(spelling)
            self.assertEqual(self.shell('harness_manual_export_policy "$2"').returncode, 0)
        local = ledger / "config.local.yaml"
        local.write_text("export:\n  auto: true\n")
        self.assertEqual(self.shell('harness_manual_export_policy "$2"').returncode, 1)
        export = (ledger / "issues.jsonl").read_bytes()
        self.assertIn("config.local.yaml", self.command("update", "--apply", expected=1))
        self.assertEqual((ledger / "issues.jsonl").read_bytes(), export)
        local.write_text("export.auto: false\n")
        self.command("update", "--apply")

    def test_failed_policy_or_export_keeps_previous_memories(self):
        self.add()
        export = self.project / ".beads/issues.jsonl"
        before = export.read_bytes()
        for failure in ("FIXTURE_CONFIG_FAIL", "FIXTURE_EXPORT_FAIL"):
            out = self.command("update", "--apply", expected=1,
                               env={**self.env, failure: "1"})
            self.assertIn("could not", out)
            self.assertEqual(export.read_bytes(), before)
            self.assertFalse(list(export.parent.glob(".harness-export-*")))


if __name__ == "__main__":
    unittest.main()
