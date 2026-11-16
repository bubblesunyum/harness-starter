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
        # Reference installs resolve the shared harness, never the network.
        self.env["HARNESS_HOME"] = str(ROOT)

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

    def test_project_guidance_and_stubs_survive_repeat(self):
        self.add()
        guidance = self.project / "AGENTS.local.md"
        guidance.write_text("Before release, run --full: it includes the browser e2e suite.\n")
        original = guidance.read_bytes()
        agents = self.project / "AGENTS.md"
        self.assertIn("AGENTS.local.md", agents.read_text())
        agents.write_text(agents.read_text().replace("First action every session", "Old contract"))
        edited = agents.read_bytes()
        out = self.add()
        self.assertNotIn("differs", out)
        self.assertEqual(guidance.read_bytes(), original)
        # Stubs are never compared or overwritten: the edit survives a re-add.
        self.assertEqual(agents.read_bytes(), edited)

    def test_copy_install_refuses_and_points_at_migrate(self):
        for marker in ("scripts/brief.sh", "scripts/verify.sh", ".claude/HARNESS.md"):
            with self.subTest(marker=marker):
                target = self.root / ("copy-%s" % marker.replace("/", "_"))
                target.mkdir()
                subprocess.run(["git", "init", "-q", str(target)], check=True)
                path = target / marker
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("copied contract\n")
                result = subprocess.run(["bash", str(ROOT / "commands/add.sh"), str(target)],
                                        env=self.env, cwd=target,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("copied install", result.stdout + result.stderr)
                self.assertIn("harness migrate", result.stdout + result.stderr)
                self.assertFalse((target / "AGENTS.md").exists())
                self.assertFalse((target / "scripts/h").exists())

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
        # The pre-commit hook is the refresh boundary now: mutating the ledger
        # and committing without a manual export still lands a fresh export —
        # with memories — staged into the commit. The gate's export check is
        # the backstop, not the mechanism.
        env = {key: value for key, value in self.env.items() if key != "BD_EXPORT_AUTO"}
        before = (ledger / "issues.jsonl").read_bytes()
        subprocess.run([str(self.bd), "mutate"], cwd=self.project, env=env, check=True)
        subprocess.run(["git", "add", ".beads/issues.jsonl"], cwd=self.project, check=True)
        commit = subprocess.run(["git", "-c", "user.name=Fixture", "-c",
                                 "user.email=fixture@example.invalid", "commit", "-q", "-m",
                                 "preserve fixture memories fix-1"], cwd=self.project, env=env,
                                capture_output=True, text=True)
        self.assertEqual(commit.returncode, 0, commit.stdout + commit.stderr)
        committed = subprocess.check_output(["git", "show", "HEAD:.beads/issues.jsonl"],
                                            cwd=self.project)
        self.assertNotEqual(committed, before)
        rows = [json.loads(line) for line in committed.decode().splitlines()]
        self.assertIn("fix-2", [row.get("id") for row in rows])
        self.assertIn("memory", [row["_type"] for row in rows])
        self.assertEqual((ledger / "issues.jsonl").read_bytes(), committed)
        self.add()
        self.assertIn("fix-2", [row.get("id") for row in self.export_rows()])
        self.assertIn("memory", [row["_type"] for row in self.export_rows()])

    def test_readd_repairs_policy_and_preserves_memories(self):
        self.add()
        ledger = self.project / ".beads"
        config = ledger / "config.yaml"
        config.write_text("export:\n  auto: true\n")
        state = json.loads((ledger / "fixture.json").read_text())
        state["auto"] = True
        (ledger / "fixture.json").write_text(json.dumps(state))
        self.assertEqual(self.shell('harness_manual_export_policy "$2"').returncode, 1)
        self.add()
        self.assertEqual(self.shell('harness_manual_export_policy "$2"').returncode, 0)
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
        self.assertIn("config.local.yaml", self.command("add", expected=1))
        self.assertEqual((ledger / "issues.jsonl").read_bytes(), export)
        local.write_text("export.auto: false\n")
        self.add()

    def test_failed_policy_or_export_keeps_previous_memories(self):
        self.add()
        export = self.project / ".beads/issues.jsonl"
        before = export.read_bytes()
        for failure in ("FIXTURE_CONFIG_FAIL", "FIXTURE_EXPORT_FAIL"):
            out = self.command("add", expected=1,
                               env={**self.env, failure: "1"})
            self.assertIn("could not", out)
            self.assertEqual(export.read_bytes(), before)
            self.assertFalse(list(export.parent.glob(".harness-export-*")))


if __name__ == "__main__":
    unittest.main()
