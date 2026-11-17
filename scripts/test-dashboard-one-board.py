#!/usr/bin/env python3
"""One board for every project: the starter's dashboard switches across
checkouts, and viewed projects stay untouched.

    python3 scripts/test-dashboard-one-board.py

A reference project (the scripts/harness finder plus a ledger, no dashboard of its
own) appears in the board's switcher and is switch-capable; switching to it
then building state creates no file inside it — the page comes from the
board's own checkout and the runtime snapshot lives there too. Copied
installs still appear; the install stubs carry no dashboard hooks.
"""

import importlib.util
import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parent
REPO = SCRIPTS.parent
TEMPLATE = REPO / "template"
SCRATCH = REPO / ".tmp"
SCRATCH.mkdir(exist_ok=True)

# Loaded by path rather than by name: `import dashboard` could resolve to
# something else on sys.path. Importing the server is side-effect-light —
# constants and locks, plus path setup at import; the serving machinery is
# all behind the __main__ guard.
spec = importlib.util.spec_from_file_location(
    "dashboard_one_board", TEMPLATE / "scripts" / "dashboard.py")
dashboard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dashboard)

MARKER = "dashboards/switch"


def snapshot_tree(root):
    """Every path under root, so a build that writes where it shouldn't shows
    up as a set difference rather than a guess about filenames."""
    return {p for p in Path(root).rglob("*")}


class OneBoardTests(unittest.TestCase):
    """Reference and copied installs share one switcher; the viewed project
    gains no files."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="one board ", dir=SCRATCH)
        self.addCleanup(self.temp.cleanup)
        parent = Path(self.temp.name)
        self.parent = parent
        # The board's own checkout: the page and the snapshot dir live here.
        self.board = parent / "board"
        (self.board / "dashboard").mkdir(parents=True)
        (self.board / "dashboard" / "index.html").write_text(
            f"<script>fetch('{MARKER}', {{method: 'POST'}})</script>")
        (self.board / "scripts").mkdir()
        # The checkout the board runs from, beside the projects it views.
        self.starter = parent / "starter"
        (self.starter / "scripts").mkdir(parents=True)
        (self.starter / "scripts" / "dashboard.py").write_text("# fake board host\n")
        # A copied install: its own dashboard script.
        self.copy = parent / "copied"
        (self.copy / "scripts").mkdir(parents=True)
        (self.copy / "scripts" / "dashboard.py").write_text("# fake checkout\n")
        # A reference install: the finder plus a ledger, no dashboard at all.
        # The pre-rename shape carries the old scripts/h resolver; the current
        # shape carries scripts/harness, with or without the shim beside it.
        self.ref = parent / "referenced"
        (self.ref / "scripts").mkdir(parents=True)
        (self.ref / "scripts" / "h").write_text("# fake finder\n")
        (self.ref / ".beads").mkdir()
        self.ref_new = parent / "referenced-new"
        (self.ref_new / "scripts").mkdir(parents=True)
        (self.ref_new / "scripts" / "harness").write_text("# fake finder\n")
        (self.ref_new / ".beads").mkdir()
        # A directory that runs no harness: never listed, never switchable.
        self.plain = parent / "plain"
        self.plain.mkdir()
        for name, value in (
            ("ROOT", self.starter),
            ("HARNESS", self.board),
            ("BOARD_ROOT", self.starter),
        ):
            patcher = mock.patch.object(dashboard, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_both_install_shapes_are_listed(self):
        roots = dashboard.sibling_roots()
        self.assertIn(self.copy, roots)
        self.assertIn(self.ref, roots)
        self.assertIn(self.ref_new, roots)
        self.assertNotIn(self.plain, roots)

    def test_both_install_shapes_are_switch_capable(self):
        self.assertTrue(dashboard.switch_capable(str(self.copy)))
        self.assertTrue(dashboard.switch_capable(str(self.ref)))

    def test_peers_advertise_both_shapes_as_switchable(self):
        with mock.patch.object(dashboard, "live_claims", return_value={}), \
             mock.patch.object(dashboard, "project_name", return_value="Starter"):
            peers = {p["root"]: p for p in dashboard.build_peers()["peers"]}
        self.assertTrue(peers[str(self.copy)]["switch_capable"])
        self.assertTrue(peers[str(self.ref)]["switch_capable"])

    def test_switching_to_a_reference_builds_state_without_touching_it(self):
        before = snapshot_tree(self.ref)
        # switch_root publishes the viewed project to children through the
        # environment; keep that inside the test so the real env is untouched.
        with mock.patch.dict(os.environ):
            self.assertEqual(dashboard.switch_root({"root": str(self.ref)}), {"ok": True})
            self.assertEqual(dashboard.ROOT, self.ref)
            # Hermetic state build: no bd, no git, no network — the question is
            # where files land, not what the ledger holds.
            with mock.patch.object(dashboard, "run", return_value=""), \
                 mock.patch.object(dashboard, "run_unstripped", return_value=""), \
                 mock.patch.object(dashboard, "bd_json", return_value=[]), \
                 mock.patch.object(dashboard, "prefix", lambda: "tst"):
                dashboard.state()
                out = dashboard.write_snapshot()
        self.assertEqual(snapshot_tree(self.ref), before)
        # The snapshot describes the viewed project but lives with the board
        # that started (BOARD_ROOT), never inside the viewed checkout.
        self.assertEqual(out, self.starter / "dashboard" / "state.json")
        self.assertEqual(json.loads(out.read_text())["root"], str(self.ref))

    def test_template_shaped_harness_snapshot_lands_in_board_root(self):
        # Dispatched through scripts/harness, HARNESS is <checkout>/template: a
        # HARNESS-anchored snapshot would land untracked in the shared checkout
        # (dashboard/state.json only ignores the checkout root's own).
        checkout = self.parent / "checkout"
        (checkout / "template" / "dashboard").mkdir(parents=True)
        (checkout / "template" / "dashboard" / "index.html").write_text(
            f"<script>fetch('{MARKER}', {{method: 'POST'}})</script>")
        before = snapshot_tree(checkout / "template")
        ref_before = snapshot_tree(self.ref)
        with mock.patch.object(dashboard, "ROOT", checkout), \
             mock.patch.object(dashboard, "HARNESS", checkout / "template"), \
             mock.patch.object(dashboard, "BOARD_ROOT", checkout), \
             mock.patch.dict(os.environ):
            self.assertEqual(dashboard.switch_root({"root": str(self.ref)}), {"ok": True})
            with mock.patch.object(dashboard, "run", return_value=""), \
                 mock.patch.object(dashboard, "run_unstripped", return_value=""), \
                 mock.patch.object(dashboard, "bd_json", return_value=[]), \
                 mock.patch.object(dashboard, "prefix", lambda: "tst"):
                out = dashboard.write_snapshot()
        self.assertEqual(out, checkout / "dashboard" / "state.json")
        self.assertEqual(snapshot_tree(checkout / "template"), before)
        self.assertEqual(snapshot_tree(self.ref), ref_before)

    def test_page_comes_from_the_board_checkout(self):
        # Whatever is viewed, the served page is the board's own.
        with mock.patch.object(dashboard, "ROOT", self.ref), \
             mock.patch("http.server.SimpleHTTPRequestHandler.__init__",
                        return_value=None) as super_init:
            dashboard.Handler(mock.Mock(), mock.Mock(), mock.Mock())
        self.assertEqual(super_init.call_args[1]["directory"],
                         str(self.board / "dashboard"))


class TestViewedToml(unittest.TestCase):
    """dashboard.toml is the one dashboard piece a leaf project keeps: after
    a switch the board serves the viewed project's tasks, theme and verdict,
    and its run buttons execute there."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="one board toml ", dir=SCRATCH)
        self.addCleanup(self.temp.cleanup)
        parent = Path(self.temp.name)
        self.board = parent / "board"
        (self.board / "dashboard").mkdir(parents=True)
        (self.board / "dashboard" / "index.html").write_text(
            f"<script>fetch('{MARKER}', {{method: 'POST'}})</script>")
        (self.board / "scripts").mkdir()
        self.starter = parent / "starter"
        (self.starter / "scripts").mkdir(parents=True)
        (self.starter / "scripts" / "dashboard.py").write_text("# fake board host\n")
        self.projects = {}
        for tag, accent, verdict, task, command in (
                ("a", "#aaaaaa", "ALPHA-(OK|FAIL)", "greet-a", '["scripts/hello.sh"]'),
                ("b", "#bbbbbb", "BETA-(OK|FAIL)", "work-b", '["echo", "hi"]')):
            root = parent / f"ref-{tag}"
            (root / "scripts").mkdir(parents=True)
            (root / "scripts" / "h").write_text("# fake finder\n")
            (root / ".beads").mkdir()
            (root / "dashboard.toml").write_text(
                f'[project]\nname = "Ref {tag.upper()}"\n'
                f'[theme]\n"--accent" = "{accent}"\n'
                f'[verdict]\npattern = "{verdict}"\n'
                f'[[task]]\nname = "{task}"\ncommand = {command}\n'
                f'label = "run it"\nbusy = "running"\nwhere = "header"\n')
            self.projects[tag] = (root, task)
        # greet-a resolves project-first: the script lives in ref-a, so the
        # button must name the project's copy, not the board's.
        (parent / "ref-a" / "scripts" / "hello.sh").write_text("#!/bin/sh\necho hi\n")
        for name, value in (
            ("ROOT", self.starter),
            ("HARNESS", self.board),
        ):
            patcher = mock.patch.object(dashboard, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self._runs_before = dict(dashboard._runs)
        self.addCleanup(lambda: (dashboard._runs.clear(),
                                 dashboard._runs.update(self._runs_before)))

    def viewed(self, tag):
        root, _ = self.projects[tag]
        with mock.patch.dict("os.environ"):
            self.assertEqual(dashboard.switch_root({"root": str(root)}), {"ok": True})
        self.assertEqual(dashboard.ROOT, root)
        return root

    def test_switch_serves_the_viewed_projects_toml(self):
        self.viewed("a")
        self.assertEqual(dashboard.project_name(), "Ref A")
        self.assertEqual(dashboard.theme(), {"--accent": "#aaaaaa"})
        self.assertEqual(dashboard.verdict_pattern(), "ALPHA-(OK|FAIL)")
        self.assertIn("greet-a", dashboard.tasks())
        self.viewed("b")
        self.assertEqual(dashboard.project_name(), "Ref B")
        self.assertEqual(dashboard.theme(), {"--accent": "#bbbbbb"})
        self.assertEqual(dashboard.verdict_pattern(), "BETA-(OK|FAIL)")
        tasks = dashboard.tasks()
        self.assertIn("work-b", tasks)
        self.assertNotIn("greet-a", tasks)

    def test_project_without_a_toml_serves_defaults(self):
        bare = self.starter.parent / "bare"
        (bare / "scripts").mkdir(parents=True)
        (bare / "scripts" / "h").write_text("# fake finder\n")
        (bare / ".beads").mkdir()
        self.viewed("a")
        self.assertIn("greet-a", dashboard.tasks())
        with mock.patch.dict("os.environ"):
            self.assertEqual(dashboard.switch_root({"root": str(bare)}), {"ok": True})
        self.assertEqual(dashboard.tasks(), dict(dashboard.DEFAULT_TASKS))
        self.assertEqual(dashboard.theme(), {})
        self.assertEqual(dashboard.verdict_pattern(), dashboard.DEFAULT_VERDICT)

    def await_settled(self, name, timeout=5.0):
        deadline = time.monotonic() + timeout
        while dashboard._runs.get(name, {}).get("state") == "running":
            if time.monotonic() > deadline:
                self.fail(f"task {name} never settled")
            time.sleep(0.01)

    def test_task_runs_with_cwd_at_the_viewed_project(self):
        seen = {}

        def fake_run(cmd, **kw):
            seen["cmd"] = cmd
            seen["cwd"] = kw.get("cwd")
            return subprocess.CompletedProcess(cmd, 0, stdout="hi\n", stderr="")

        root_a, _ = self.projects["a"]
        root_b, _ = self.projects["b"]
        with mock.patch("subprocess.run", side_effect=fake_run):
            self.viewed("a")
            dashboard.start_task("greet-a")
            self.await_settled("greet-a")
            # Project-first resolution: the button names ref-a's own script.
            self.assertEqual(seen["cmd"][0], str(root_a / "scripts" / "hello.sh"))
            self.assertEqual(Path(seen["cwd"]), root_a)
            self.assertEqual(dashboard._runs["greet-a"]["state"], "ok")
            self.viewed("b")
            dashboard.start_task("work-b")
            self.await_settled("work-b")
            self.assertEqual(seen["cmd"], ["echo", "hi"])
            self.assertEqual(Path(seen["cwd"]), root_b)


class StubSettingsTests(unittest.TestCase):
    """The install stubs start no dashboard: projects run none."""

    @classmethod
    def setUpClass(cls):
        cls.settings = json.loads(
            (TEMPLATE / "stubs" / ".claude" / "settings.json").read_text())

    def hook_commands(self):
        cmds = []
        for group in self.settings.get("hooks", {}).values():
            for entry in group:
                for hook in entry.get("hooks", []):
                    cmds.append(hook.get("command", ""))
        return cmds

    def test_no_stub_hook_mentions_the_dashboard(self):
        cmds = self.hook_commands()
        self.assertTrue(cmds, "the stubs start no hooks at all")
        for cmd in cmds:
            self.assertNotIn("dashboard", cmd)

    def test_session_hook_survives(self):
        self.assertIn('cd "$CLAUDE_PROJECT_DIR" && scripts/harness session --hook',
                      self.hook_commands())


if __name__ == "__main__":
    unittest.main()
