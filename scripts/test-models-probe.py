#!/usr/bin/env python3
"""Exercise the models.py roster probe against a fake opencode on PATH.

    python3 scripts/test-models-probe.py

A probe is one trivial `opencode run` per distinct pick at `ensure` time, so
a candidate that can't run here fails at prompt time instead of mid-review.
The fake answers runs; what's under test is the error reading, the argv the
probe sends, and the pick-again-or-keep loop around it.
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


class ProbeModelTests(unittest.TestCase):
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

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(l)["argv"] for l in self.log.read_text().splitlines()]

    def test_answering_model_probes_clean(self):
        # The fake is on PATH through the environment; the probe inherits it.
        # No variant: the probe certifies the model answers, nothing more —
        # variants ride -m only once the runner speaks it, so the probe
        # must not bless what the runtime can't execute.
        with mock.patch.dict(os.environ, self.env):
            err = models.probe_model("go/fine")
        self.assertIsNone(err)
        argv = self.calls()[0]
        self.assertIn("-m", argv)
        self.assertEqual(argv[argv.index("-m") + 1], "go/fine")
        self.assertIn("--standalone", argv)
        self.assertNotIn("--variant", argv)
        self.assertEqual(argv[-1], models.PROBE_PROMPT)

    def test_provider_error_is_the_failure_line(self):
        env = dict(self.env, FAKE_EVENTS=error_event("region not enabled"),
                   FAKE_EXIT="1")
        with mock.patch.dict(os.environ, env):
            err = models.probe_model("go/region-locked")
        self.assertEqual(err, "region not enabled")

    def test_live_error_shape_reads_the_message(self):
        out = json.dumps({"type": "error",
                          "error": {"type": "provider.no-route",
                                    "message": "Model unavailable: x/y"}}) + "\n"
        self.assertEqual(models.probe_error(out, 1, ""), "Model unavailable: x/y")

    def test_missing_opencode_keeps_on_trust(self):
        # An empty HOME so the ~/.opencode/bin fallback misses too: without
        # it the test reads this machine's real install instead of nothing.
        home = Path(self.temp.name) / "home"
        home.mkdir()
        with mock.patch.dict(os.environ, {"PATH": self.temp.name,
                                           "HOME": str(home)}):
            err = models.probe_model("go/whatever")
        self.assertIn("cannot probe", err)

    def test_hung_model_reports_the_timeout(self):
        env = dict(self.env, FAKE_SLEEP="5")
        with mock.patch.dict(os.environ, env):
            with mock.patch.object(models, "PROBE_TIMEOUT_SECONDS", 1):
                err = models.probe_model("go/slow")
        self.assertIn("no reply in 1s", err)


class EnsureLoopTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="models ensure ")
        self.addCleanup(self.temp.cleanup)
        self.fake_root = Path(self.temp.name)
        self.roster = self.fake_root / "harness" / "models.json"

    def ensure(self, inputs, previous=None, probes=None,
               which="/fake/opencode", candidates=("m1", "m2")):
        if previous is not None:
            self.roster.parent.mkdir(parents=True, exist_ok=True)
            self.roster.write_text(json.dumps(previous))
        probed = probes if probes is not None else {}
        calls = []

        def fake_probe(model):
            calls.append(model)
            return probed.get(model, None)

        stdin = mock.Mock()
        stdin.isatty.return_value = True
        with mock.patch.object(models, "ROOT", self.fake_root), \
             mock.patch.object(models, "ROSTER", self.roster), \
             mock.patch.object(models, "detect", return_value=(list(candidates), ["opencode"])), \
             mock.patch.object(models, "probe_model", side_effect=fake_probe), \
             mock.patch("builtins.input", side_effect=inputs), \
             mock.patch.object(models.sys, "stdin", stdin), \
             mock.patch.object(models.shutil, "which", return_value=which):
            self.assertEqual(models.ensure(again=True), 0)
        return json.loads(self.roster.read_text()), calls

    def test_failed_probe_re_picks_and_probes_once_per_model(self):
        roster, calls = self.ensure(["1", "2", "", "", "", "", ""],
                                    probes={"m1": "region not enabled"})
        self.assertTrue(all(entry["model"] == "m2" for entry in roster.values()))
        self.assertEqual(calls, ["m1", "m2"])

    def test_re_picking_the_failed_model_keeps_it_on_trust(self):
        roster, calls = self.ensure(["1", "1", "", "", "", "", ""],
                                    probes={"m1": "region not enabled"})
        self.assertTrue(all(entry["model"] == "m1" for entry in roster.values()))
        self.assertEqual(calls, ["m1"])

    def test_previous_variant_and_context_survive(self):
        previous = {"reviewer-taste": {"model": "old", "variant": "xhigh", "context": 99}}
        roster, calls = self.ensure(["2", "", "", "", "", ""],
                                    previous=previous)
        taste = roster["reviewer-taste"]
        self.assertEqual((taste["model"], taste["variant"], taste["context"]),
                         ("m2", "xhigh", 99))
        self.assertIn("m2", calls)

    def test_no_opencode_writes_without_probing(self):
        roster, calls = self.ensure(["", "", "", "", "", ""],
                                    which=None, candidates=("m1",))
        self.assertTrue(all(entry["model"] == "m1" for entry in roster.values()))
        self.assertEqual(calls, [])

    def test_first_default_skips_free_tier_ids(self):
        # Free-tier ids refuse every custom agent, so the chained default
        # starts at the first paid id — free stays pickable by number.
        roster, _ = self.ensure(["", "", "", "", "", ""],
                                candidates=("m1-free", "m2"))
        self.assertTrue(all(entry["model"] == "m2" for entry in roster.values()))

    def test_all_free_candidates_still_default_to_first(self):
        roster, _ = self.ensure(["", "", "", "", "", ""],
                                candidates=("m1-free",))
        self.assertTrue(all(entry["model"] == "m1-free"
                            for entry in roster.values()))

    def test_explicit_free_pick_for_a_reviewer_warns(self):
        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            roster, _ = self.ensure(["1", "", "", "", "", ""],
                                    candidates=("m1-free", "m2"))
        self.assertTrue(all(entry["model"] == "m1-free"
                            for entry in roster.values()))
        self.assertIn("free-tier", buf.getvalue())


class BudgetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="models budget ")
        self.addCleanup(self.temp.cleanup)
        self.fake_root = Path(self.temp.name)
        self.roster = self.fake_root / "harness" / "models.json"
        self.xdg = self.fake_root / "cache"

    def budget(self, role, roster, catalog="absent"):
        self.roster.parent.mkdir(parents=True, exist_ok=True)
        self.roster.write_text(json.dumps(roster))
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
        return {"p": {"models": {"m": {"limit": {"context": context}}}}}

    def test_explicit_context_wins_over_the_catalog(self):
        roster = {"reviewer-taste": {"model": "p/m", "context": 99}}
        self.assertEqual(self.budget("reviewer-taste", roster,
                                     self.catalog(1048576)), 99)

    def test_catalog_limit_replaces_the_8192_fallback(self):
        roster = {"reviewer-taste": {"model": "p/m"}}
        self.assertEqual(self.budget("reviewer-taste", roster,
                                     self.catalog(1048576)), 1048576)

    def test_missing_cache_falls_back_to_the_heuristic(self):
        self.assertEqual(self.budget("reviewer-taste",
                                     {"reviewer-taste": {"model": "p/m"}}), 8192)
        self.assertEqual(self.budget("reviewer-taste",
                                     {"reviewer-taste": {"model": "anthropic/sonnet"}}),
                         200000)

    def test_misshapen_cache_falls_back_to_the_heuristic(self):
        roster = {"reviewer-taste": {"model": "p/m"}}
        for catalog in ("not json", {}, {"p": {}},
                        {"p": {"models": {}}},
                        {"p": {"models": {"m": {}}}},
                        self.catalog(0), self.catalog(-5),
                        self.catalog("1048576"), self.catalog(True),
                        {"p": {"models": {"other": {"limit": {"context": 1}}}}}):
            with self.subTest(catalog=catalog):
                self.assertEqual(self.budget("reviewer-taste", roster, catalog), 8192)

    def test_model_without_a_provider_misses_the_catalog(self):
        self.assertEqual(self.budget("reviewer-taste",
                                     {"reviewer-taste": {"model": "bare"}},
                                     self.catalog(1048576)), 8192)

    def test_role_without_a_model_has_no_budget(self):
        self.assertEqual(self.budget("reviewer-taste", {}), 0)


if __name__ == "__main__":
    unittest.main()
