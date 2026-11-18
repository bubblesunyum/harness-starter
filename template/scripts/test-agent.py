#!/usr/bin/env python3
"""Exercise scripts/agent.py against a fake opencode on PATH.

    python3 scripts/test-agent.py

The real opencode costs a provider call per run and answers differently every
time; what's under test here is the plumbing around it — which agent and model
it asks for, how it reads the event stream, and when it refuses.
"""

import json
import os
import shutil
import signal
import sys
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
from models import OPENCODE_MODEL, OPENCODE_MODEL_ARG, OPENCODE_VARIANT

PINNED = {"model": OPENCODE_MODEL, "variant": OPENCODE_VARIANT}

# Replays whatever $FAKE_EVENTS holds as `run` output, answers `export` with
# $FAKE_ROUNDS user messages, and records its argv and the config it was given.
FAKE_OPENCODE = """#!/usr/bin/env python3
import json, os, sys, time
if len(sys.argv) > 1 and sys.argv[1] == "--version":
    print(os.environ.get("FAKE_VERSION_STDOUT", os.environ.get("FAKE_VERSION", "opencode v2.0.19")))
    if os.environ.get("FAKE_VERSION_STDERR"):
        sys.stderr.write(os.environ["FAKE_VERSION_STDERR"] + "\\n")
    sys.exit(0)
log = os.environ["FAKE_LOG"]
with open(log, "a") as f:
    f.write(json.dumps({"argv": sys.argv[1:],
                        "config": os.environ.get("OPENCODE_CONFIG_CONTENT")}) + "\\n")
if sys.argv[1:3] == ["session", "export"]:
    n = int(os.environ.get("FAKE_ROUNDS", "1"))
    print(json.dumps({"messages": [{"type": "user"}] * n}))
    sys.exit(0)
if sys.argv[1] == "models":
    print(os.environ["FAKE_MODEL"])
    print(json.dumps({"capabilities": {"input": {
        "image": os.environ.get("FAKE_IMAGE", "true") == "true"}}}))
    sys.exit(int(os.environ.get("FAKE_MODELS_EXIT", "0")))
if os.environ.get("FAKE_TOOL_SLEEP") or os.environ.get("FAKE_ZOMBIE") \
        or os.environ.get("FAKE_DAEMON"):
    import subprocess as _sp, threading as _th
if os.environ.get("FAKE_TOOL_SLEEP"):
    # A silent stand-in for a long tool command: a direct child of the fake,
    # no output, so only the process-group watch notices it. Reaped on exit,
    # like opencode reaps its tools — otherwise the zombie would hold the
    # table open past the command's life.
    _tool = _sp.Popen(["sleep", os.environ["FAKE_TOOL_SLEEP"]],
                    stdout=_sp.DEVNULL, stderr=_sp.DEVNULL)
    _th.Thread(target=_tool.wait, daemon=True).start()
if os.environ.get("FAKE_DAEMON"):
    # A backgrounded server: the shell exits at once, leaving its sleep
    # reparented to init — still in the group, but no longer the fake's
    # child, so the ppid rule drops it. Spawned before the zombie: any later
    # Popen would reap it through subprocess._cleanup.
    _dm = _sp.Popen(["sh", "-c", "sleep 8 &"])
    _dm.wait()
if os.environ.get("FAKE_ZOMBIE"):
    # An unreaped exit: the fake's child, stat Z. Spawned last for the same
    # reason. Held and never waited, so it stays a zombie until the fake
    # exits — and must not count.
    _zb = _sp.Popen(["true"])
if os.environ.get("FAKE_WAIT_FILE"):
    # Gate the fake's exit on a file the test touches: the test writes its
    # work file after the first heartbeat, then ends the wait here, so the
    # run lasts exactly as long as the assertions need, whatever the load.
    for _ in range(200):
        if os.path.exists(os.environ["FAKE_WAIT_FILE"]):
            break
        time.sleep(0.2)
sys.stdout.write(os.environ.get("FAKE_EVENTS", ""))
sys.stderr.write(os.environ.get("FAKE_STDERR", ""))
time.sleep(float(os.environ.get("FAKE_SLEEP", "0")))
sys.exit(int(os.environ.get("FAKE_EXIT", "0")))
"""


def text_event(text, session="ses_fake"):
    return json.dumps({"type": "text", "sessionID": session,
                       "part": {"type": "text", "text": text}}) + "\n"


def error_event(message):
    return json.dumps({"type": "error", "sessionID": "ses_fake",
                       "error": {"name": "APIError", "data": {"message": message}}}) + "\n"


class AgentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="agent harness ")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        (root / "scripts").mkdir()
        for name in ("agent.py", "harness_paths.py", "models.py"):
            shutil.copy(SCRIPTS / name, root / "scripts" / name)
        (root / "harness").mkdir()
        self.roster = root / "harness/models.json"
        self.roster.write_text(json.dumps({
            "reviewer-taste": PINNED,
            "reviewer-design": PINNED,
            "implement": PINNED,
        }))
        (root / ".opencode/agent").mkdir(parents=True)
        (root / ".opencode/agent/reviewer-taste.md").write_text("---\nmode: subagent\n---\n")
        (root / ".opencode/agent/reviewer-correctness.md").write_text("---\nmode: subagent\n---\n")
        (root / ".opencode/agent/reviewer-design.md").write_text("---\nmode: subagent\n---\n")
        bin_dir = root / "bin"
        bin_dir.mkdir()
        fake = bin_dir / "opencode"
        fake.write_text(FAKE_OPENCODE)
        fake.chmod(0o755)
        self.root, self.log = root, root / "calls.jsonl"
        self.env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}",
                        FAKE_LOG=str(self.log), FAKE_MODEL=OPENCODE_MODEL)
        self.env.pop("OPENCODE_CONFIG_CONTENT", None)
        # An empty home, so the ~/.opencode/bin fallback never reaches this
        # machine's real install: every test runs the fake or nothing.
        home = root / "home"
        home.mkdir()
        self.env["HOME"] = str(home)
        self.env.pop("OPENCODE_BIN", None)

    def agent(self, *args, **fake):
        env = dict(self.env, **{f"FAKE_{k.upper()}": v for k, v in fake.items()})
        return subprocess.run([sys.executable, str(self.root / "scripts/agent.py"), *args],
                              capture_output=True, text=True, env=env)

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(l) for l in self.log.read_text().splitlines()]

    def _wait_for_line(self, lines, needle, timeout):
        """Block until a collected stderr line holds needle. Heartbeats prove
        where the run got to, so waiting on them — not on a sleep — is what
        keeps the timing tests free of ordering races under load."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            if any(needle in line for line in lines):
                return
            time.sleep(0.05)
        self.fail(f"timed out waiting for {needle!r} in agent output:\n"
                  + "".join(lines))

    def test_reviewer_runs_its_own_agent_promoted_to_primary(self):
        out = self.agent("reviewer-taste", "review", "it", events=text_event("no findings"))
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), "no findings")
        self.assertIn("session ses_fake", out.stderr)
        call = self.calls()[0]
        self.assertEqual(call["argv"][:8],
                         ["run", "--standalone", "--format", "json", "--agent", "reviewer-taste",
                          "-m", OPENCODE_MODEL_ARG])
        self.assertEqual(call["argv"][-2:], ["--", "review it"])
        settings = json.loads(call["config"])["agent"]["reviewer-taste"]
        self.assertEqual(settings["mode"], "primary")
        # review.sh's packet lives in /tmp; headless opencode refuses it otherwise.
        self.assertEqual(settings["permission"]["external_directory"]["/tmp/*"], "allow")

    def test_every_role_can_read_its_own_mktemp_output(self):
        # macOS mktemp lands in $TMPDIR under /var/folders, not /tmp; a refused
        # read there killed a live worker. The implementer runs `build`.
        scratch = self.root / "sys-tmp"
        scratch.mkdir()
        self.env["TMPDIR"] = f"{scratch}/"
        temp_dirs = {"/tmp", os.path.realpath("/tmp"), str(scratch), os.path.realpath(scratch)}
        for role, agent in (("implement", "build"), ("reviewer-taste", "reviewer-taste")):
            with self.subTest(role=role):
                self.agent(role, "go do it", events=text_event("ok"))
                settings = json.loads(self.calls()[-1]["config"])["agent"][agent]
                # Exactly the temp dirs, both spellings: nothing else outside.
                self.assertEqual(settings["permission"]["external_directory"],
                                 {f"{tmp}/*": "allow" for tmp in temp_dirs})

    def test_build_is_not_promoted_and_its_permissions_still_fail_loudly(self):
        self.agent("implement", "go do it", events=text_event("ok"))
        self.assertNotIn("mode", json.loads(self.calls()[-1]["config"])["agent"]["build"])
        self.env["OPENCODE_CONFIG_CONTENT"] = '{"agent": {"build": {"permission": "allow"}}}'
        out = self.agent("implement", "go do it", events=text_event("ok"))
        self.assertEqual(out.returncode, 1)
        self.assertNotIn("Traceback", out.stderr)
        self.assertIn("agent.build.permission", out.stderr)

    def test_existing_config_content_is_merged_not_replaced(self):
        self.env["OPENCODE_CONFIG_CONTENT"] = '{"theme": "x", "agent": {"other": {"mode": "all"}}}'
        self.agent("reviewer-taste", "go do it", events=text_event("ok"))
        config = json.loads(self.calls()[0]["config"])
        self.assertEqual(config["theme"], "x")
        self.assertEqual(config["agent"]["other"]["mode"], "all")
        self.assertEqual(config["agent"]["reviewer-taste"]["mode"], "primary")

    def test_every_inherited_config_model_is_overwritten_with_the_pin(self):
        # OPENCODE_CONFIG_CONTENT outranks opencode.json, and -m covers only
        # the primary — an inherited `general` would run the subagents.
        for role in ("reviewer-taste", "implement"):
            with self.subTest(role=role):
                self.env["OPENCODE_CONFIG_CONTENT"] = json.dumps({
                    "model": "go/cheap",
                    "agent": {"reviewer-taste": {"model": "go/cheap", "variant": "low"},
                              "general": {"model": "go/cheap"}},
                    "agents": {"explore": {"model": "go/cheap"}}})
                self.agent(role, "go do it", events=text_event("ok"))
                config = json.loads(self.calls()[-1]["config"])
                self.assertEqual(config["model"], OPENCODE_MODEL_ARG)
                for settings in (*config["agent"].values(), *config["agents"].values()):
                    self.assertEqual((settings["model"], settings["variant"]),
                                     (OPENCODE_MODEL, OPENCODE_VARIANT))

    def test_implement_runs_build_behind_the_contract_on_the_first_round_only(self):
        self.agent("implement", "do the thing", events=text_event("done"))
        first = self.calls()[0]
        self.assertIn("build", first["argv"])
        self.assertEqual(json.loads(first["config"])["model"], OPENCODE_MODEL_ARG)
        self.assertTrue(first["argv"][-1].startswith("You are a delegated implementer"))
        self.assertTrue(first["argv"][-1].endswith("do the thing"))
        self.agent("implement", "--session", "ses_1", "fix it", events=text_event("fixed"), rounds="1")
        revision = self.calls()[-1]
        self.assertEqual(revision["argv"][-1], "fix it")
        self.assertIn("--session", revision["argv"])

    def test_every_role_runs_on_the_pin(self):
        for role in ("implement", "reviewer-taste", "reviewer-correctness"):
            with self.subTest(role=role):
                out = self.agent(role, "go do it", events=text_event("done"))
                self.assertEqual(out.returncode, 0, out.stderr)
                self.assertIn(f"on {OPENCODE_MODEL} ({OPENCODE_VARIANT})", out.stderr)
                argv = self.calls()[-1]["argv"]
                self.assertEqual(argv[argv.index("-m") + 1], OPENCODE_MODEL_ARG)

    def test_a_foreign_roster_model_is_refused_before_opencode_runs(self):
        for entry in ({"model": "opencode-go/cheap-bulk", "variant": OPENCODE_VARIANT},
                      {"model": "ollama/qwen3:4b"},
                      "opencode-go/cheap-bulk"):
            with self.subTest(entry=entry):
                self.log.unlink(missing_ok=True)
                self.roster.write_text(json.dumps({"implement": entry}))
                out = self.agent("implement", "go do it", events=text_event("done"))
                self.assertEqual(out.returncode, 1)
                self.assertIn(f"opencode runs only on {OPENCODE_MODEL}", out.stderr)
                self.assertNotIn("run", [c["argv"][0] for c in self.calls()])

    def test_a_variant_mismatch_is_refused_before_opencode_runs(self):
        for variant in ("low", "max", None):
            with self.subTest(variant=variant):
                self.log.unlink(missing_ok=True)
                entry = {"model": OPENCODE_MODEL}
                if variant:
                    entry["variant"] = variant
                self.roster.write_text(json.dumps({"reviewer-taste": entry}))
                out = self.agent("reviewer-taste", "go do it", events=text_event("ok"))
                self.assertEqual(out.returncode, 1)
                self.assertIn("scripts/harness models ensure", out.stderr)
                self.assertNotIn("run", [c["argv"][0] for c in self.calls()])

    def test_visual_reviewer_runs_only_with_an_image_capable_model(self):
        out = self.agent("reviewer-design", "review", events=text_event("visual ok"))
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), "visual ok")
        self.assertEqual([c["argv"][0] for c in self.calls()], ["models", "run"])
        argv = self.calls()[1]["argv"]
        self.assertEqual(argv[argv.index("-m") + 1], OPENCODE_MODEL_ARG)

    def test_visual_reviewer_refuses_a_text_only_or_unknown_model(self):
        for fake in ({"image": "false"}, {"model": "go/other"},
                     {"models_exit": "1"}):
            with self.subTest(fake=fake):
                self.log.unlink(missing_ok=True)
                out = self.agent("reviewer-design", "review", **fake)
                self.assertEqual(out.returncode, 1)
                self.assertIn("cannot verify image support", out.stderr)
                self.assertEqual([c["argv"][0] for c in self.calls()], ["models"])

    def test_a_message_starting_with_a_dash_is_not_a_flag(self):
        self.agent("reviewer-taste", "- fix naming", events=text_event("ok"))
        self.assertEqual(self.calls()[0]["argv"][-2:], ["--", "- fix naming"])

    def test_a_session_past_the_cap_is_refused_without_running(self):
        out = self.agent("implement", "--session", "ses_1", "again", rounds="3")
        self.assertEqual(out.returncode, 3)
        self.assertIn("Stop revising", out.stderr)
        self.assertEqual([c["argv"][0] for c in self.calls()], ["session"])

    def test_the_last_allowed_round_runs(self):
        out = self.agent("implement", "--session", "ses_1", "last", rounds="2",
                         events=text_event("ok"))
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("round 3 of 3", out.stderr)

    def test_an_empty_reply_fails_rather_than_reading_as_no_findings(self):
        out = self.agent("reviewer-taste", "review", events="")
        self.assertEqual(out.returncode, 1)
        self.assertEqual(out.stdout, "")
        self.assertIn("no reply", out.stderr)

    def test_a_refused_permission_fails_but_keeps_the_reply(self):
        out = self.agent("implement", "go do it", events=text_event("changed foo.py"),
                         stderr="\x1b[93m! \x1b[0mpermission requested: external_directory (/x/*); auto-rejecting\n")
        self.assertEqual(out.returncode, 4)
        self.assertEqual(out.stdout.strip(), "changed foo.py")
        self.assertIn("permission requested: external_directory (/x/*)", out.stderr)
        self.assertNotIn("\x1b", out.stderr)

    def test_only_the_final_step_is_the_reply(self):
        step = json.dumps({"type": "step_start", "sessionID": "ses_fake"}) + "\n"
        out = self.agent("reviewer-taste", "go do it", events=(
            step + text_event("Let me read the packet.") + step + text_event("## Findings")))
        self.assertEqual(out.stdout.strip(), "## Findings")

    def test_a_failed_run_with_a_reply_says_it_was_discarded(self):
        out = self.agent("reviewer-taste", "go do it", events=text_event("half"), exit="2")
        self.assertEqual(out.returncode, 1)
        self.assertIn("exited 2", out.stderr)
        self.assertIn("discarded", out.stderr)

    def test_a_misshapen_config_content_fails_in_the_scripts_voice(self):
        for shape in ('{"agent": "primary"}',
                      '{"agent": {"reviewer-taste": {"permission": "allow"}}}',
                      '{"agent": {"reviewer-taste": {"permission": {"external_directory": "allow"}}}}'):
            with self.subTest(shape=shape):
                self.env["OPENCODE_CONFIG_CONTENT"] = shape
                out = self.agent("reviewer-taste", "go do it", events=text_event("ok"))
                self.assertEqual(out.returncode, 1)
                self.assertNotIn("Traceback", out.stderr)
                self.assertIn("OPENCODE_CONFIG_CONTENT", out.stderr)

    def test_a_provider_error_is_reported(self):
        out = self.agent("reviewer-taste", "review", events=error_event("rate limited"))
        self.assertEqual(out.returncode, 1)
        self.assertIn("rate limited", out.stderr)

    def test_v2_error_shape_reads_the_message_directly(self):
        # Live v2 errors carry the message on the error itself ({type,
        # message}), not under data — printing anything else is a dict repr.
        v2 = (json.dumps({"type": "error", "sessionID": "ses_fake",
                          "error": {"type": "provider.no-route",
                                    "message": "Model unavailable: x/y"}}) + "\n")
        out = self.agent("reviewer-taste", "review", events=v2)
        self.assertEqual(out.returncode, 1)
        self.assertIn("Model unavailable: x/y", out.stderr)
        self.assertNotIn("{'type'", out.stderr)

    def test_image_catalog_covers_a_legacy_models_failure(self):
        # opencode 2 dropped `models --verbose`, so the legacy check fails —
        # the cached models.dev catalog is what's left to ask.
        cache = Path(self.env["HOME"]) / ".cache/opencode"
        cache.mkdir(parents=True)
        provider, _, name = OPENCODE_MODEL.partition("/")
        (cache / "models.json").write_text(json.dumps({
            provider: {"models": {name:
                                  {"modalities": {"input": ["text", "image"]}}}}}))
        out = self.agent("reviewer-design", "review", models_exit="1",
                         events=text_event("visual ok"))
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), "visual ok")

    def test_no_roster_at_all_still_runs_on_the_pin(self):
        self.roster.unlink()
        out = self.agent("reviewer-correctness", "review", events=text_event("ok"))
        self.assertEqual(out.returncode, 0, out.stderr)
        argv = self.calls()[-1]["argv"]
        self.assertEqual(argv[argv.index("-m") + 1], OPENCODE_MODEL_ARG)

    def test_a_role_without_an_agent_is_refused(self):
        out = self.agent("nonsense", "review")
        self.assertEqual(out.returncode, 1)
        self.assertIn(".opencode/agent/nonsense.md", out.stderr)

    def test_missing_opencode_is_named(self):
        self.env["PATH"] = "/usr/bin:/bin"
        out = self.agent("reviewer-taste", "review")
        self.assertEqual(out.returncode, 1)
        self.assertIn("opencode is not on PATH", out.stderr)

    def test_the_installer_bin_is_found_off_path(self):
        # The official installer adds ~/.opencode/bin to PATH only in ~/.zshrc,
        # which agent shells never source.
        installed = Path(self.env["HOME"]) / ".opencode/bin"
        installed.mkdir(parents=True)
        shutil.move(str(self.root / "bin/opencode"), installed / "opencode")
        self.env["PATH"] = "/usr/bin:/bin"
        out = self.agent("reviewer-taste", "review", events=text_event("ok"))
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), "ok")

    def test_opencode_bin_overrides_path(self):
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        shutil.move(str(self.root / "bin/opencode"), elsewhere / "opencode")
        self.env["OPENCODE_BIN"] = str(elsewhere / "opencode")
        out = self.agent("reviewer-taste", "review", events=text_event("ok"))
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), "ok")

    def test_opencode_1x_is_refused_with_the_upgrade(self):
        for version in ("1.18.31", "opencode v1.18.33", "v1.18.31"):
            with self.subTest(version=version):
                self.log.unlink(missing_ok=True)
                out = self.agent("reviewer-taste", "review", version=version,
                                 events=text_event("ok"))
                self.assertEqual(out.returncode, 1)
                self.assertIn("needs opencode 2", out.stderr)
                self.assertIn("opencode-v2", out.stderr)
                self.assertEqual(self.calls(), [])

    def test_a_version_on_stderr_behind_blank_stdout_still_passes(self):
        out = self.agent("reviewer-taste", "review", version_stdout=chr(10),
                         version_stderr="opencode v2.0.19",
                         events=text_event("ok"))
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), "ok")

    def test_ctrl_c_kills_the_child_group_and_keeps_exit_130(self):
        # Ctrl-C on the wrapper must not orphan the headless child: the wall
        # cap died with the wrapper, so the group dies here instead.
        env = dict(self.env, FAKE_LOG=str(self.log), FAKE_MODEL=OPENCODE_MODEL,
                   FAKE_SLEEP="30", HARNESS_AGENT_IDLE_SECONDS="600",
                   HARNESS_AGENT_HEARTBEAT_SECONDS="60")
        proc = subprocess.Popen(
            [sys.executable, str(self.root / "scripts/agent.py"),
             "reviewer-taste", "go now please"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        try:
            runs = self.root / ".tmp" / "agent-runs"
            child = None
            for _ in range(100):
                files = list(runs.glob("*.json")) if runs.exists() else []
                if files:
                    child = json.loads(files[0].read_text()).get("child_pid")
                    break
                time.sleep(0.1)
            self.assertIsNotNone(child, "no status file for the live run")
            proc.send_signal(signal.SIGINT)
            try:
                proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                proc.kill()
                self.fail("agent did not exit after SIGINT")
            self.assertEqual(proc.returncode, 130)
            with self.assertRaises(OSError):
                os.kill(child, 0)
            self.assertEqual(list(runs.glob("*.json")), [])
        finally:
            if proc.poll() is None:
                proc.kill()

    def test_non_finite_timeouts_are_refused(self):
        # nan parses and compares False against everything, so without an
        # explicit check it would silently disable the clock it was meant to set.
        for name, bad in (("HARNESS_AGENT_IDLE_SECONDS", "nan"),
                          ("HARNESS_AGENT_IDLE_SECONDS", "inf"),
                          ("HARNESS_AGENT_HEARTBEAT_SECONDS", "-inf")):
            with self.subTest(name=name, bad=bad):
                self.env[name] = bad
                try:
                    out = self.agent("reviewer-taste", "go now please")
                finally:
                    del self.env[name]
                self.assertEqual(out.returncode, 2)
                self.assertIn("finite", out.stderr)

    def test_broken_shim_shadowing_path_still_fails_in_the_scripts_voice(self):
        bad = self.root / "badbin"
        bad.mkdir()
        shim = bad / "opencode"
        shim.write_text("this is not a binary")
        shim.chmod(0o644)
        self.env["PATH"] = str(bad)
        out = self.agent("reviewer-taste", "review", events=text_event("ok"))
        self.assertEqual(out.returncode, 1)
        self.assertIn("agent.py:", out.stderr)
        self.assertNotIn("Traceback", out.stderr)

    def test_idle_default_is_five_minutes(self):
        import agent
        self.assertEqual(agent.IDLE_TIMEOUT_SECONDS, 300)
        self.assertEqual(agent.TOOL_TIMEOUT_SECONDS, 1200)

    def test_silent_run_dies_at_the_idle_limit(self):
        # HARNESS_AGENT_IDLE_SECONDS=1.5 proves the env override end to end:
        # on the 300s default this run would outlive its fake instead. The
        # zombie (dead, still the fake's child) and the daemon (live,
        # reparented to init) must neither count as tool activity.
        self.env["HARNESS_AGENT_IDLE_SECONDS"] = "1.5"
        try:
            start = time.time()
            out = self.agent("reviewer-taste", "go do it", sleep="10",
                             zombie="1", daemon="1")
        finally:
            del self.env["HARNESS_AGENT_IDLE_SECONDS"]
        elapsed = time.time() - start
        self.assertEqual(out.returncode, 5, out.stderr)
        self.assertIn("no output or tool activity for", out.stderr)
        self.assertLess(elapsed, 10)

    def test_live_tool_command_counts_as_activity(self):
        # The fake's sleep child is silent but a direct one: the idle clock
        # must not advance for the 3s it lives, then must kill the run once
        # it exits and silence continues. Bounds sit seconds clear of both
        # the expected kill (~5s) and the no-counting kill (~2s).
        self.env["HARNESS_AGENT_IDLE_SECONDS"] = "2"
        try:
            start = time.time()
            out = self.agent("reviewer-taste", "go do it", sleep="10", tool_sleep="3")
        finally:
            del self.env["HARNESS_AGENT_IDLE_SECONDS"]
        elapsed = time.time() - start
        self.assertEqual(out.returncode, 5, out.stderr)
        self.assertGreaterEqual(elapsed, 4)
        self.assertLess(elapsed, 10)

    def test_tool_command_ages_out_of_activity(self):
        # Past HARNESS_AGENT_TOOL_SECONDS a live tool stops counting: the
        # run dies of idleness while the tool is still alive. Killed near
        # first-seen + 2 + 1 (~4s), seconds clear of the tool's own exit.
        self.env["HARNESS_AGENT_IDLE_SECONDS"] = "1"
        self.env["HARNESS_AGENT_TOOL_SECONDS"] = "2"
        try:
            start = time.time()
            out = self.agent("reviewer-taste", "go do it", sleep="10", tool_sleep="7")
        finally:
            del self.env["HARNESS_AGENT_IDLE_SECONDS"]
            del self.env["HARNESS_AGENT_TOOL_SECONDS"]
        elapsed = time.time() - start
        self.assertEqual(out.returncode, 5, out.stderr)
        self.assertGreaterEqual(elapsed, 2.5)
        self.assertLess(elapsed, 7)

    def test_select_live_tools_counts_only_young_direct_non_zombie_children(self):
        import agent
        seen = {}
        rows = [(100, 50, "S", "sleep 9"),
                (101, 50, "Z+", "true <defunct>"),
                (102, 1, "S", "sleep 8"),
                (103, 99, "S", "sleep 8"),
                (104, 50, "S", "old helper")]
        seen[104] = 0.0
        live = agent._select_live_tools(rows, 50, 1200, seen, 2000.0)
        self.assertEqual(live, [(100, "sleep 9")])

    def test_negative_delta_clamps_without_double_sign(self):
        import agent
        real = agent._git_snapshot
        try:
            agent._git_snapshot = lambda: ({"f": "M "}, 0, 3)
            progress = agent._worktree_progress(({"f": " M"}, 5, 0))
        finally:
            agent._git_snapshot = real
        self.assertEqual(progress, "1 file, +0/-3 since start")
        try:
            agent._git_snapshot = lambda: ({"a": " M", "b": "??"}, 3, 1)
            progress = agent._worktree_progress(({}, 0, 0))
        finally:
            agent._git_snapshot = real
        self.assertEqual(progress, "2 files, +3/-1 since start")

    def test_implement_heartbeat_reports_progress_and_running_command(self):
        subprocess.run(["git", "init", "-q", str(self.root)], check=True,
                       capture_output=True)
        subprocess.run(["git", "-C", str(self.root), "config", "user.email", "t@t"],
                       check=True, capture_output=True)
        subprocess.run(["git", "-C", str(self.root), "config", "user.name", "t"],
                       check=True, capture_output=True)
        tracked = self.root / "work.txt"
        tracked.write_text("one\n")
        subprocess.run(["git", "-C", str(self.root), "add", "work.txt"],
                       check=True, capture_output=True)
        subprocess.run(["git", "-C", str(self.root), "commit", "-qm", "init"],
                       check=True, capture_output=True)
        # Pre-create the files the run itself writes (the fake's call log
        # and the runs dir): untracked paths present at snapshot keep the
        # same porcelain status, so only the edit below counts as changed.
        self.log.write_text("")
        (self.root / ".tmp" / "agent-runs").mkdir(parents=True, exist_ok=True)
        # An empty dir is invisible to git: seed a placeholder so ?? .tmp/
        # exists at snapshot and the status file lands inside it uncounted.
        (self.root / ".tmp" / "agent-runs" / ".keep").write_text("")
        done_file = self.root / "fake-done"
        env = dict(self.env, HARNESS_AGENT_HEARTBEAT_SECONDS="1",
                   HARNESS_AGENT_IDLE_SECONDS="60", FAKE_SLEEP="0.5",
                   FAKE_WAIT_FILE=str(done_file),
                   FAKE_TOOL_SLEEP="8", FAKE_EVENTS=text_event("done"))
        proc = subprocess.Popen(
            [sys.executable, str(self.root / "scripts/agent.py"),
             "implement", "do the thing"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        lines = []
        def _collect():
            # Live stderr, line by line: stderr is never block-buffered, so
            # each heartbeat lands here as the run prints it.
            try:
                for line in proc.stderr:
                    lines.append(line)
            except ValueError:
                pass
        reader = threading.Thread(target=_collect, daemon=True)
        reader.start()
        try:
            # The first beat proves the spawn snapshot is taken; only then
            # does the edit land, so no startup delay can hide it from every
            # later beat. The tool outlives the run, spanning every heartbeat
            # (it lingers a few seconds past the run as an orphan, then exits
            # alone — nothing accumulates).
            self._wait_for_line(lines, "still running", timeout=20)
            with tracked.open("a") as handle:
                handle.write("two\n")
            self._wait_for_line(lines, "1 file, +1/-0 since start", timeout=20)
        finally:
            done_file.write_text("")
        try:
            proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            proc.kill()
            self.fail("agent run hung")
        reader.join(timeout=10)
        out, err = proc.stdout.read(), "".join(lines)
        self.assertEqual(proc.returncode, 0, err)
        self.assertIn("done", out)
        self.assertTrue(any("1 file, +1/-0 since start" in line for line in lines), err)
        self.assertGreaterEqual(sum("running:" in line for line in lines), 2, err)
        self.assertTrue(any("sleep" in line for line in lines), err)

    def test_ps_shows_progress(self):
        runs = self.root / "runs"
        runs.mkdir()
        self.env["HARNESS_AGENT_RUNS_DIR"] = str(runs)
        try:
            (runs / "run1.json").write_text(json.dumps({
                "agent_pid": os.getpid(), "child_pid": 1234,
                "role": "implement", "session": "ses_1",
                "started_at": time.time() - 60,
                "last_activity_at": time.time() - 5,
                "progress": "1 file, +1/-0 since start"}))
            out = self.agent("ps")
        finally:
            del self.env["HARNESS_AGENT_RUNS_DIR"]
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("PROGRESS", out.stdout)
        self.assertIn("1 file, +1/-0 since start", out.stdout)


if __name__ == "__main__":
    unittest.main()
