#!/usr/bin/env python3
"""Exercise models.py — the pin, the roster that records it, the ensure probe
and the packet budget — against a fake opencode on PATH.

    python3 scripts/test-models-probe.py

What's under test: the probe sends only the pinned model, `ensure` writes
the pinned roster with or without a terminal and never offers another model,
and a roster naming anything else is refused by every reader.
"""

import json
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import models

# Replays $FAKE_EVENTS on stdout for `run`, records argv; anything else exits 2.
FAKE_OPENCODE = """#!/usr/bin/env python3
import json, os, sys, time
log = os.environ["FAKE_LOG"]
with open(log, "a") as f:
    f.write(json.dumps({"argv": sys.argv[1:]}) + "\\n")
if sys.argv[1] == "run":
    time.sleep(float(os.environ.get("FAKE_SLEEP", "0")))
    sys.stdout.write(os.environ.get("FAKE_EVENTS", ""))
    sys.stderr.write(os.environ.get("FAKE_STDERR", ""))
    sys.exit(int(os.environ.get("FAKE_EXIT", "0")))
sys.exit(2)
"""


def text_event(text, session="ses_fake"):
    return json.dumps({"type": "text", "sessionID": session,
                       "part": {"type": "text", "text": text}}) + "\n"


def error_event(message):
    return json.dumps({"type": "error", "sessionID": "ses_fake",
                       "error": {"name": "APIError", "data": {"message": message}}}) + "\n"


class ProbeErrorTests(unittest.TestCase):
    def test_error_event_reads_the_message(self):
        err = models.probe_error(error_event("region not enabled for this model"), 1, "")
        self.assertEqual(err, "region not enabled for this model")

    def test_error_without_a_message_falls_back_to_the_name(self):
        out = json.dumps({"type": "error", "error": {"name": "APIError"}}) + "\n"
        self.assertEqual(models.probe_error(out, 1, ""), "APIError")

    def test_junk_lines_and_foreign_shapes_are_skipped(self):
        out = "not json\n[1, 2]\n" + text_event("ok")
        self.assertIsNone(models.probe_error(out, 0, ""))

    def test_answered_run_is_no_error(self):
        self.assertIsNone(models.probe_error(text_event("ok"), 0, ""))

    def test_failed_run_with_no_reply_names_the_exit_and_stderr(self):
        err = models.probe_error("", 1, "boom\nwent wrong\n")
        self.assertIn("exited 1", err)
        self.assertIn("went wrong", err)

    def test_clean_exit_with_no_reply_says_so(self):
        self.assertIn("no reply", models.probe_error("", 0, ""))


class ProbePinnedTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="models probe ")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        fake = bin_dir / "opencode"
        fake.write_text(FAKE_OPENCODE)
        fake.chmod(0o755)
        self.log = root / "calls.jsonl"
        self.env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}",
                        FAKE_LOG=str(self.log),
                        FAKE_EVENTS=text_event("ok"))
        self.env.pop("OPENCODE_BIN", None)

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(l)["argv"] for l in self.log.read_text().splitlines()]

    def test_the_probe_sends_the_pin_and_only_the_pin(self):
        with mock.patch.dict(os.environ, self.env):
            err = models.probe_pinned()
        self.assertIsNone(err)
        argv = self.calls()[0]
        self.assertEqual(argv[argv.index("-m") + 1], models.OPENCODE_MODEL_ARG)
        self.assertIn("--standalone", argv)
        self.assertNotIn("--variant", argv)
        self.assertEqual(argv[-1], models.PROBE_PROMPT)

    def test_provider_error_is_the_failure_line(self):
        env = dict(self.env, FAKE_EVENTS=error_event("region not enabled"),
                   FAKE_EXIT="1")
        with mock.patch.dict(os.environ, env):
            err = models.probe_pinned()
        self.assertEqual(err, "region not enabled")

    def test_live_error_shape_reads_the_message(self):
        out = json.dumps({"type": "error",
                          "error": {"type": "provider.no-route",
                                    "message": "Model unavailable: x/y"}}) + "\n"
        self.assertEqual(models.probe_error(out, 1, ""), "Model unavailable: x/y")

    def test_missing_opencode_is_named(self):
        # An empty HOME so the ~/.opencode/bin fallback misses too: without
        # it the test reads this machine's real install instead of nothing.
        home = Path(self.temp.name) / "home"
        home.mkdir()
        with mock.patch.dict(os.environ, {"PATH": self.temp.name,
                                           "HOME": str(home)}):
            err = models.probe_pinned()
        self.assertIn("cannot probe", err)

    def test_hung_model_reports_the_timeout(self):
        env = dict(self.env, FAKE_SLEEP="5")
        with mock.patch.dict(os.environ, env):
            with mock.patch.object(models, "PROBE_TIMEOUT_SECONDS", 1):
                err = models.probe_pinned()
        self.assertIn("no reply in 1s", err)


class RosterTests(unittest.TestCase):
    """ensure, the readers, and the states between them, in a throwaway root."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="models roster ")
        self.addCleanup(self.temp.cleanup)
        self.fake_root = Path(self.temp.name)
        self.roster = self.fake_root / "harness" / "models.json"
        for patch in (mock.patch.object(models, "ROOT", self.fake_root),
                      mock.patch.object(models, "ROSTER", self.roster)):
            patch.start()
            self.addCleanup(patch.stop)

    def write(self, data):
        self.roster.parent.mkdir(parents=True, exist_ok=True)
        self.roster.write_text(data if isinstance(data, str) else json.dumps(data))

    def ensure(self, tty, again=False, probe=None):
        stdin = mock.Mock()
        stdin.isatty.return_value = tty
        probes = []

        def fake_probe():
            probes.append(True)
            return probe

        err = io.StringIO()
        with mock.patch.object(models.sys, "stdin", stdin), \
             mock.patch.object(models, "probe_pinned", side_effect=fake_probe), \
             mock.patch.object(models.shutil, "which", return_value="/fake/opencode"), \
             mock.patch("builtins.input", side_effect=AssertionError("ensure prompted")), \
             mock.patch("sys.stdout", io.StringIO()), mock.patch("sys.stderr", err):
            self.assertEqual(models.ensure(again=again), 0)
        return json.loads(self.roster.read_text()), probes, err.getvalue()

    def assert_pinned(self, roster):
        self.assertEqual(set(roster), set(models.ROLES) | set(roster))
        for role, entry in roster.items():
            self.assertEqual((entry["model"], entry["variant"]),
                             (models.OPENCODE_MODEL, models.OPENCODE_VARIANT), role)

    def test_no_terminal_writes_the_pinned_roster_without_probing(self):
        roster, probes, _ = self.ensure(tty=False)
        self.assert_pinned(roster)
        self.assertEqual(set(roster), set(models.ROLES))
        self.assertEqual(probes, [])
        self.assertEqual(models.roster_state(), "ok")

    def test_a_terminal_probes_the_pin_once_and_offers_nothing_else(self):
        roster, probes, _ = self.ensure(tty=True)
        self.assert_pinned(roster)
        self.assertEqual(probes, [True])

    def test_a_failed_probe_still_writes_the_pin_and_says_so(self):
        roster, _, err = self.ensure(tty=True, probe="region not enabled")
        self.assert_pinned(roster)
        self.assertIn("region not enabled", err)

    def test_a_foreign_roster_is_rewritten_and_named(self):
        self.write({"implement": {"model": "opencode-go/cheap", "variant": "low",
                                  "context": 99},
                    "custom": "ollama/qwen3:4b"})
        self.assertEqual(models.roster_state(), "foreign")
        roster, _, err = self.ensure(tty=False)
        self.assert_pinned(roster)
        self.assertIn("custom", roster)
        self.assertIn("opencode-go/cheap", err)
        # Measured for another model, so it says nothing about the pin's window.
        self.assertNotIn("context", roster["implement"])

    def test_a_context_measured_for_the_pin_survives_a_rewrite(self):
        self.write({"implement": {"model": models.OPENCODE_MODEL, "variant": "low",
                                  "context": 99}})
        roster, _, _ = self.ensure(tty=False)
        self.assertEqual(roster["implement"]["context"], 99)

    def test_a_corrupt_roster_is_rewritten(self):
        self.write("{not json")
        self.assertEqual(models.roster_state(), "invalid")
        roster, _, err = self.ensure(tty=False)
        self.assert_pinned(roster)
        self.assertIn("unreadable", err)

    def test_a_pinned_roster_is_left_alone(self):
        self.ensure(tty=False)
        before = self.roster.read_text()
        self.ensure(tty=True)
        self.assertEqual(self.roster.read_text(), before)

    def test_readers_return_the_pin_with_or_without_a_roster(self):
        self.assertEqual(models.model_for("implement"), models.OPENCODE_MODEL)
        self.assertEqual(models.variant_for("implement"), models.OPENCODE_VARIANT)
        self.ensure(tty=False)
        self.assertEqual(models.model_for("reviewer-taste"), models.OPENCODE_MODEL)

    def test_readers_refuse_a_foreign_model_or_variant(self):
        for entry in ({"model": "opencode-go/cheap", "variant": "xhigh"},
                      {"model": models.OPENCODE_MODEL, "variant": "low"},
                      {"model": models.OPENCODE_MODEL},
                      "opencode-go/cheap"):
            with self.subTest(entry=entry):
                self.write({"implement": entry})
                for reader in (models.model_for, models.variant_for, models.budget_for):
                    with self.assertRaises(models.ForeignModel):
                        reader("implement")


class BudgetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="models budget ")
        self.addCleanup(self.temp.cleanup)
        self.fake_root = Path(self.temp.name)
        self.roster = self.fake_root / "harness" / "models.json"
        self.xdg = self.fake_root / "cache"

    def budget(self, role, context=None, catalog="absent"):
        entry = {"model": models.OPENCODE_MODEL, "variant": models.OPENCODE_VARIANT}
        if context is not None:
            entry["context"] = context
        self.roster.parent.mkdir(parents=True, exist_ok=True)
        self.roster.write_text(json.dumps({"reviewer-taste": entry}))
        if catalog != "absent":
            cache_file = self.xdg / "opencode" / "models.json"
            cache_file.parent.mkdir(parents=True, exist_ok=True)
            cache_file.write_text(json.dumps(catalog) if not isinstance(catalog, str)
                                  else catalog)
        with mock.patch.object(models, "ROOT", self.fake_root), \
             mock.patch.object(models, "ROSTER", self.roster), \
             mock.patch.dict(os.environ, {"XDG_CACHE_HOME": str(self.xdg)}):
            return models.budget_for(role)

    def catalog(self, context):
        provider, _, name = models.OPENCODE_MODEL.partition("/")
        return {provider: {"models": {name: {"limit": {"context": context}}}}}

    def test_explicit_context_wins_over_the_catalog(self):
        self.assertEqual(self.budget("reviewer-taste", 99, self.catalog(1048576)), 99)

    def test_catalog_limit_wins_over_the_pins_fallback(self):
        self.assertEqual(self.budget("reviewer-taste", catalog=self.catalog(2000)), 2000)

    def test_missing_cache_falls_back_to_the_pins_window(self):
        # A machine whose opencode never cached the catalog must not refuse
        # every ordinary packet at 8192.
        self.assertEqual(self.budget("reviewer-taste"), models.OPENCODE_CONTEXT)

    def test_misshapen_values_fall_back(self):
        for context in (True, 0, -5, "x", 1.5):
            with self.subTest(context=context):
                self.assertEqual(self.budget("reviewer-taste", context),
                                 models.OPENCODE_CONTEXT)
        for catalog in ("not json", {}, self.catalog(0), self.catalog(True),
                        self.catalog("1048576")):
            with self.subTest(catalog=catalog):
                self.assertEqual(self.budget("reviewer-taste", catalog=catalog),
                                 models.OPENCODE_CONTEXT)

    def test_a_role_with_no_roster_entry_still_has_the_pins_budget(self):
        self.assertEqual(self.budget("reviewer-design"), models.OPENCODE_CONTEXT)

    def test_an_unknown_role_has_no_budget(self):
        self.assertEqual(self.budget("nonsense"), 0)


if __name__ == "__main__":
    unittest.main()
