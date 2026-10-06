#!/usr/bin/env python3
"""Exercise the template dashboard checkout-switch contract against the server module.

    python3 scripts/test-dashboard-switch.py

The switch endpoint only lands on a checkout whose page already speaks switch
(the marker in template/dashboard/index.html), and the page's peer tabs must
always offer the way back. What's under test: switch_capable's truth table,
switch_root's move-or-leave-untouched contract, and the way-back shape in the
template page. Chrome-free and offline — the page is read as text.
"""

import importlib.util
import re
import shutil
import tempfile
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
    "dashboard_server", TEMPLATE / "scripts" / "dashboard.py")
dashboard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dashboard)

MARKER = "dashboards/switch"

# The page's contracts, pinned as tolerant regexes — behavior, not source
# shape: either operand order of each root comparison is the same claim.
SELF_CHECK = r"\w+\.root\s*===\s*selfRoot"
BUSY_CHECK = r"startingPeerRoot\s*&&\s*\w+\.root\s*===\s*startingPeerRoot"


class SwitchCapableTests(unittest.TestCase):
    """The marker gate: a board is switchable only if its page speaks switch."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="switch capable ", dir=SCRATCH)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write_page(self, text):
        page = self.root / "dashboard" / "index.html"
        page.parent.mkdir(parents=True, exist_ok=True)
        page.write_text(text)

    def test_this_template_speaks_switch(self):
        # The core claim: the template board carries the marker.
        self.assertTrue(dashboard.switch_capable(str(TEMPLATE)))

    def test_marker_page_is_capable(self):
        self.write_page(f"<script>fetch('{MARKER}', {{method: 'POST'}})</script>")
        self.assertTrue(dashboard.switch_capable(str(self.root)))

    def test_markerless_page_is_not_capable(self):
        self.write_page("<h1>a board from before the switch</h1>")
        self.assertFalse(dashboard.switch_capable(str(self.root)))

    def test_missing_page_is_not_capable(self):
        self.assertFalse(dashboard.switch_capable(str(self.root)))


class SwitchRootTests(unittest.TestCase):
    """switch_root moves to a capable sibling and touches nothing else."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="switch root ", dir=SCRATCH)
        self.addCleanup(self.temp.cleanup)
        parent = Path(self.temp.name)
        self.root = parent / "here"
        self.markerless = parent / "p1"
        self.peer = parent / "p2"
        # sibling_roots() lists children of ROOT.parent holding the harness,
        # so every fake checkout needs scripts/dashboard.py to be seen at all.
        for r in (self.root, self.markerless, self.peer):
            (r / "scripts").mkdir(parents=True)
            (r / "scripts" / "dashboard.py").write_text("# fake checkout\n")
        (self.peer / "dashboard").mkdir()
        (self.peer / "dashboard" / "index.html").write_text(
            f"<script>fetch('{MARKER}', {{method: 'POST'}})</script>")
        (self.markerless / "dashboard").mkdir()
        (self.markerless / "dashboard" / "index.html").write_text("<h1>old board</h1>")
        # Harness rows are built the way template/scripts/dashboard.py builds
        # them: a memory pattern is str(MEMORY_DIR / ...), so the repoint has
        # something real to rebase — and one row outside MEMORY_DIR, which
        # must come through untouched.
        self.old_mem = parent / "old-memory"
        harness = [("memories", "blurb",
                    [(str(self.old_mem / "x.md"), "claude", "a memory"),
                     (str(Path.home() / "elsewhere.md"), "claude", "unmoved")])]
        for name, value in (
            ("ROOT", self.root),
            ("MEMORY_DIR", self.old_mem),
            ("HARNESS", harness),
        ):
            patcher = mock.patch.object(dashboard, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_switching_to_a_capable_peer_moves_root_and_memory(self):
        res = dashboard.switch_root({"root": str(self.peer)})
        self.assertEqual(res, {"ok": True})
        self.assertEqual(dashboard.ROOT, self.peer)
        # MEMORY_DIR is repointed under the new root, never shared with the old.
        self.assertEqual(dashboard.MEMORY_DIR.name, "memory")
        self.assertIn(str(self.peer).replace("/", "-"), str(dashboard.MEMORY_DIR))
        self.assertNotEqual(dashboard.MEMORY_DIR, self.old_mem)
        # The memory rows rebase onto the new MEMORY_DIR; anything outside the
        # old one is left alone.
        rows = dashboard.HARNESS[0][2]
        self.assertEqual(rows[0][0], str(dashboard.MEMORY_DIR / "x.md"))
        self.assertEqual(rows[1][0], str(Path.home() / "elsewhere.md"))

    def test_peer_payload_marks_markerless_sibling_incapable(self):
        with mock.patch.object(dashboard, "live_claims", return_value={}), \
             mock.patch.object(dashboard, "sibling_roots", return_value=[self.markerless, self.peer]), \
             mock.patch.object(dashboard, "project_name", return_value="Here"):
            peers = {p["root"]: p for p in dashboard.build_peers()["peers"]}
        self.assertTrue(peers[str(self.peer)]["switch_capable"])
        self.assertFalse(peers[str(self.markerless)]["switch_capable"])

    def test_live_external_checkout_is_not_advertised_as_switchable(self):
        outside = Path(tempfile.mkdtemp(prefix="external live "))
        self.addCleanup(lambda: shutil.rmtree(outside, ignore_errors=True))
        (outside / "dashboard").mkdir()
        (outside / "dashboard" / "index.html").write_text(
            f"<script>fetch('{MARKER}', {{method: 'POST'}})</script>")
        with mock.patch.object(dashboard, "live_claims", return_value={str(outside): 4321}), \
             mock.patch.object(dashboard, "sibling_roots", return_value=[self.markerless, self.peer]), \
             mock.patch.object(dashboard, "project_name", return_value="Here"):
            peers = {p["root"]: p for p in dashboard.build_peers()["peers"]}
        self.assertFalse(peers[str(outside)]["switch_capable"])

    def assert_untouched(self, payload, error):
        before_root = dashboard.ROOT
        before_mem = dashboard.MEMORY_DIR
        res = dashboard.switch_root(payload)
        self.assertEqual(res, {"ok": False, "error": error})
        self.assertIs(dashboard.ROOT, before_root)
        self.assertIs(dashboard.MEMORY_DIR, before_mem)

    def test_empty_root_is_refused(self):
        self.assert_untouched({"root": ""}, "root is empty")

    def test_unknown_root_is_refused(self):
        self.assert_untouched({"root": str(self.root.parent / "nowhere")}, "unknown checkout")

    def test_markerless_sibling_is_refused(self):
        self.assert_untouched({"root": str(self.markerless)},
                              "checkout does not support switching")


class WayBackTests(unittest.TestCase):
    """The template page, read as text: every tab round-trips, so nobody lands
    with no way back. Tolerant regexes — what must survive is behavior, not
    whitespace."""

    @classmethod
    def setUpClass(cls):
        cls.html = (TEMPLATE / "dashboard" / "index.html").read_text()

    def test_self_tab_is_the_board_on_screen(self):
        # The pressed tab is decided from the endpoint's `self` root — which
        # moves the moment a switch POST is answered, before any repaint lands.
        self.assertRegex(self.html, SELF_CHECK)
        # The lone-board fallback names this board by the project; a foreign
        # entry carrying a self flag must not out-rank the endpoint's root.
        self.assertRegex(self.html, r"name:\s*d\.project")
        self.assertRegex(self.html, r"p\.self\s*&&\s*!p\.root")

    def test_busy_tab_keeps_its_root_before_any_current_check(self):
        busy = re.search(BUSY_CHECK, self.html)
        current = re.search(SELF_CHECK, self.html)
        self.assertIsNotNone(busy)
        self.assertIsNotNone(current)
        # The in-flight tab renders before the current check that could claim it,
        # so it stays busy through the flight — rooted (the restore path finds
        # it), named (the row doesn't reflow), aria-busy and disabled.
        self.assertLess(busy.start(), current.start())
        self.assertRegex(self.html, r"aria-busy\s*=\s*['\"]true['\"][\s\S]{0,200}?data-peer-root=")

    def test_peer_list_shape_is_guarded(self):
        # Foreign entries make the whole list absent, not dead tabs.
        self.assertRegex(self.html, r"typeof\s+\w+\.root\s*===\s*['\"]string['\"]")
        self.assertRegex(self.html, r"\w+\.root\s*!==\s*''")
        self.assertRegex(self.html, r"typeof\s+\w+\.name\s*===\s*['\"]string['\"]")

    def test_peer_buttons_carry_their_root(self):
        # The press POSTs the root it carries; the self tab gets no root and
        # stays inert, and an incapable tab carries no pressable root at all.
        self.assertRegex(self.html, r'data-peer-root="\$\{')
        self.assertRegex(self.html, r"function peerGroup\b")
        self.assertRegex(self.html, r"data-peer-incapable")

    def test_incapable_tabs_are_inert_with_an_update_title(self):
        self.assertRegex(self.html, r"switch_capable\s*===\s*false")
        self.assertRegex(self.html, r"needs an update before it can switch")

    def test_peer_row_has_a_visible_scroll_affordance(self):
        self.assertRegex(self.html, r"peer-scroll-control")
        self.assertRegex(self.html, r"data-peer-scroll")
        self.assertRegex(self.html, r"has-more")

    def test_switch_target_is_verbatim(self):
        self.assertIn(MARKER, self.html)


class CaptureHookTests(unittest.TestCase):
    """The review pass photographs the peer tab bar via `shot <path> peers`;
    the page must honour the ?shot plumbing and press the popover open."""

    @classmethod
    def setUpClass(cls):
        cls.html = (TEMPLATE / "dashboard" / "index.html").read_text()

    def test_capture_hook_opens_the_peer_popover(self):
        self.assertRegex(self.html, r"URLSearchParams\(location\.search\)\.get\(\s*['\"]shot['\"]\s*\)")
        self.assertRegex(self.html, r"setAttribute\(\s*['\"]data-shot['\"]")
        self.assertRegex(self.html, r"peers:.*metaToggle")


if __name__ == "__main__":
    unittest.main()
