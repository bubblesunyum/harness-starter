#!/usr/bin/env python3
"""Runs one harness role through opencode, on the one model opencode runs on.

    scripts/h agent <role> <message...>                   # a fresh session
    scripts/h agent <role> --session <id> <message...>    # one more round in it
    scripts/h agent ps                                    # live runs and their age
    scripts/h agent stop <run-id>                         # end one live run

    scripts/h agent reviewer-correctness "Review /tmp/x-review.md — adds a cache"
    scripts/h agent implement "har-abc: $(bd show har-abc)"
    scripts/h agent implement --session ses_123 "verify fails: missing import in foo.py"

The reply goes to stdout. The session id, model and round go to stderr, as one
line — the id is what a revision round needs. A `-h`/`--help` anywhere after
the role is usage, never a brief — it exits 2 without spawning anything.

Exits 0 with a reply; 1 when the run failed and there is no reply to trust; 2 on
a usage error; 3 when the session is past its revision cap, without running; 4
when opencode refused a permission — the reply is still printed, but was
written without what it asked for; 5 when the child went silent past the idle
limit and was killed.

A silent child is killed: no output or events for HARNESS_AGENT_IDLE_SECONDS
(default 600) ends the run with exit 5, whatever the wall cap still allows.
While it runs, a heartbeat line goes to stderr every
HARNESS_AGENT_HEARTBEAT_SECONDS (default 120) with the elapsed time and the
last activity, and .tmp/agent-runs/<run-id>.json carries the same for
`agent.py ps` and `agent.py stop`. HARNESS_AGENT_RUNS_DIR overrides the dir
(hermetic tests point it at a temp dir). An interrupted wrapper (Ctrl-C)
kills the child's process group before exiting 130, so no headless run
outlives the wrapper that was capping it.

This is how a session in any tool — Claude Code included — hands work to a
model that isn't its own: the packet or the brief is read in a separate
opencode process, off the caller's context, on OPENCODE_MODEL at
OPENCODE_VARIANT (scripts/h models). There is no flag or variable to pick
another: a roster naming one is refused before opencode is spawned.
(Reviewers are the exception: under opencode they always run as native
subagents, never through this script.)

Roles with an agent in .opencode/agent/ (the reviewers, the librarian) run that
agent. `implement` runs opencode's own build agent behind a short contract,
because AGENTS.md — which opencode loads into every session — tells an agent to
claim beads, commit and run the review pass, and all three belong to the caller.

A session takes at most MAX_ROUNDS messages: the brief and two revisions. Past
that the script refuses, because a fourth "please fix" rarely lands where the
first three didn't, and each one re-reads the whole thread.
"""

import json
import math
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from harness_paths import HARNESS, ROOT

OPENCODE_AGENTS = ROOT / ".opencode/agent"

# The project's scripts first, so a same-path shadow wins; the harness copy
# behind it, so a shadow still finds the siblings it did not replace.
sys.path.insert(0, str(HARNESS / "scripts"))
sys.path.insert(0, str(ROOT / "scripts"))
from models import (OPENCODE_MODEL, OPENCODE_MODEL_ARG, OPENCODE_VARIANT,
                    ForeignModel, catalog_entry, model_for, opencode_bin,
                    variant_for)

MAX_ROUNDS = 3
# Long enough for an implementer that runs the gate twice; short enough that a
# hung provider is noticed before the calling session gives up on it.
TIMEOUT_SECONDS = 45 * 60
EXPORT_TIMEOUT_SECONDS = 60
# No output or events for this long and the child is dead weight: kill it,
# separate from the wall cap above (a chatty run may still use all 45 minutes).
IDLE_TIMEOUT_SECONDS = 10 * 60
# How often a running child says its age on stderr and refreshes its status.
HEARTBEAT_SECONDS = 2 * 60
# How often the wait loop re-checks the idle and wall clocks.
POLL_SECONDS = 1.0
# TERM-to-KILL patience when stopping a child or a silent one.
KILL_GRACE_SECONDS = 10
# A silent child was killed (exit 1 stays the failed run, 2 the usage error).
IDLE_EXIT = 5

IMPLEMENT_CONTRACT = """\
You are a delegated implementer. Another agent wrote this brief, will review \
your diff, and owns everything around the change. So, overriding AGENTS.md \
for this session:

- Do not commit, stage, or touch the bd ledger. The caller does all three.
- Do not run scripts/h review or spawn reviewers. You are being reviewed.
- Stay inside the brief. Something else worth doing goes in your report, not \
in the diff.
- Run scripts/h verify before you finish, and fix what it catches.

End with a short report: the files you changed, what the verify run said, and \
anything you were unsure of or left undone. Say so plainly if you could not \
finish — a half-done change reported as done costs the caller a review round.

The brief:

"""


def strip_ansi(line):
    """A line of opencode's stderr without its colour codes."""
    return re.sub(r"\x1b\[[0-9;]*m", "", line).strip()


def fail(message, code=1):
    print(f"agent.py: {message}", file=sys.stderr)
    sys.exit(code)


def require_opencode_v2():
    """Refuse opencode 1.x, which can't read the DB the 2.x app migrates and
    lacks the flags this script uses (--standalone, -m model#variant). Brew's
    `opencode` formula is still 1.x; v2 is the official install script or a
    separate formula, so `brew upgrade opencode` alone stays broken."""
    try:
        out = subprocess.run([opencode_bin(), "--version"], capture_output=True,
                             text=True, stdin=subprocess.DEVNULL, cwd=ROOT,
                             timeout=30)
    except FileNotFoundError:
        fail("opencode is not on PATH or in ~/.opencode/bin — install it, set OPENCODE_BIN, "
             "or spawn the role natively")
    except OSError as exc:
        fail(f"opencode can't be run ({exc}) — check the install")
    except subprocess.TimeoutExpired:
        fail("`opencode --version` hung — check the install")
    raw = out.stdout.strip() or out.stderr.strip()
    version = raw.split()[-1].lstrip("v") if raw else ""
    major = version.split(".")[0] if version else ""
    if out.returncode != 0 or not major.isdigit() or int(major) < 2:
        found = version or "unknown"
        fail(f"opencode {found} is too old — this harness needs opencode 2 "
             f"(the 2.x app migrates the session DB that 1.x can't read). "
             f"Install it with `curl -fsSL https://opencode.ai/v2/install | bash` "
             f"or `brew install anomalyco/tap/opencode-v2` "
             f"(uninstall brew's 1.x `opencode` first — they conflict)")


def parse_args(argv):
    """(role, session or None, message). `-h`/`--help` after the role is usage,
    never a brief; only an empty message is refused."""
    if len(argv) < 2 or argv[0] in ("-h", "--help"):
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        sys.exit(2)
    role, rest, session = argv[0], argv[1:], None
    if rest[:1] == ["--session"]:
        if len(rest) < 3:
            fail("--session needs an id and a message", 2)
        session, rest = rest[1], rest[2:]
    if any(token in ("-h", "--help") for token in rest):
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        sys.exit(2)
    message = " ".join(rest).strip()
    if not message:
        fail("an empty message — say what the role should do", 2)
    return role, session, message


def agent_for(role):
    """The opencode agent that plays a role: its generated file, or `build`
    for implement. Anything else has nothing to run."""
    if role == "implement":
        return "build"
    if (OPENCODE_AGENTS / f"{role}.md").is_file():
        return role
    fail(f"no .opencode/agent/{role}.md — run scripts/h opencode-agents, "
         f"or check the role name against .claude/agents/")


def catalog_accepts_images(model):
    """Whether opencode's cached models.dev catalog lists `model` as taking
    images. opencode 2 dropped `models --verbose`; the catalog it refreshes
    is what's left to ask."""
    entry = catalog_entry(model)
    if entry is None:
        return False
    modalities = entry.get("modalities", {})
    inputs = modalities.get("input") if isinstance(modalities, dict) else None
    return isinstance(inputs, list) and "image" in inputs


def require_image_model(model):
    """Refuse a visual review unless OpenCode says its model accepts images."""
    provider, separator, _ = model.partition("/")
    if not separator:
        fail(f"reviewer-design model {model} has no provider ID")
    try:
        out = subprocess.run([opencode_bin(), "models", provider, "--verbose"],
                             capture_output=True, text=True, stdin=subprocess.DEVNULL,
                             cwd=ROOT, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        fail(f"cannot verify image support for {model}; run reviewer-design natively")
    if out.returncode != 0:
        if catalog_accepts_images(model):
            return
        fail(f"cannot verify image support for {model}; run reviewer-design natively")
    lines = out.stdout.splitlines(keepends=True)
    for index, line in enumerate(lines):
        if line.rstrip("\r\n") != model:
            continue
        try:
            details, _ = json.JSONDecoder().raw_decode("".join(lines[index + 1:]).lstrip())
        except json.JSONDecodeError:
            break
        capabilities = details.get("capabilities", {}) if isinstance(details, dict) else {}
        inputs = capabilities.get("input", {}) if isinstance(capabilities, dict) else {}
        if isinstance(inputs, dict) and inputs.get("image") is True:
            return
        break
    fail(f"cannot verify image support for {model}; run reviewer-design natively")


def pin_config(config):
    """Every model choice in an inherited config, overwritten with the pin.
    OPENCODE_CONFIG_CONTENT outranks opencode.json, so a `general` or
    `explore` model inherited from the caller's environment would otherwise
    run the implementer's own subagents on it — -m covers only the primary."""
    config["model"] = OPENCODE_MODEL_ARG
    for group in ("agent", "agents", "mode"):
        agents = config.get(group)
        if not isinstance(agents, dict):
            continue
        for settings in agents.values():
            if isinstance(settings, dict):
                settings["model"], settings["variant"] = OPENCODE_MODEL, OPENCODE_VARIANT
    return config


def inherited_config():
    """The caller's OPENCODE_CONFIG_CONTENT as an object, or fail loudly."""
    existing = os.environ.get("OPENCODE_CONFIG_CONTENT", "").strip()
    try:
        config = json.loads(existing) if existing else {}
    except json.JSONDecodeError:
        fail("OPENCODE_CONFIG_CONTENT is set but is not JSON — unset it or fix it")
    if not isinstance(config, dict) or not isinstance(config.get("agent", {}), dict):
        fail("OPENCODE_CONFIG_CONTENT is set but is not a JSON object with an "
             "object for `agent`")
    return config


def agent_config(agent):
    """OPENCODE_CONFIG_CONTENT that lets `opencode run --agent` use a generated
    agent, and lets it read what review.sh hands it — pinned throughout.

    The generated agents are `mode: subagent` so they stay out of opencode's
    agent picker, and `run --agent` quietly falls back to the default agent for
    a subagent — a reviewer that never saw its own prompt. Promoting it for
    this one process is the only fix that touches neither.

    review.sh writes the packet and the captures to /tmp, outside the project,
    and headless opencode auto-rejects every read out there. Both spellings are
    granted because /tmp is a symlink on macOS and opencode checks the path as
    the agent wrote it."""
    config = inherited_config()
    if not isinstance(config.get("agent", {}).get(agent, {}), dict):
        fail(f"OPENCODE_CONFIG_CONTENT sets agent.{agent} to something that "
             f"isn't an object — unset it or fix it")
    settings = config.setdefault("agent", {}).setdefault(agent, {})
    settings["mode"] = "primary"
    permission = settings.setdefault("permission", {})
    if not isinstance(permission, dict):
        fail(f"OPENCODE_CONFIG_CONTENT sets agent.{agent}.permission to something "
             f"that isn't an object — unset it or fix it")
    outside = permission.setdefault("external_directory", {})
    if not isinstance(outside, dict):
        fail(f"OPENCODE_CONFIG_CONTENT sets agent.{agent}.permission.external_directory "
             f"to something that isn't an object — unset it or fix it")
    for tmp in sorted({"/tmp", os.path.realpath("/tmp")}):
        outside[f"{tmp}/*"] = "allow"
    return json.dumps(pin_config(config))


def rounds_so_far(session):
    """User messages already in a session, read back from opencode itself so
    the cap can't be dodged by losing a counter file."""
    try:
        # Export to a file, not a pipe: opencode exits before draining a pipe, so
        # a long session's JSON arrives truncated and reads as a bad id.
        with tempfile.TemporaryFile(mode="w+") as sink:
            code = subprocess.run([opencode_bin(), "session", "export", session], stdout=sink,
                                  stderr=subprocess.DEVNULL, text=True, stdin=subprocess.DEVNULL,
                                  cwd=ROOT, timeout=EXPORT_TIMEOUT_SECONDS).returncode
            sink.seek(0)
            out = subprocess.CompletedProcess([], code, sink.read(), "")
    except FileNotFoundError:
        fail("opencode is not on PATH or in ~/.opencode/bin — install it, set OPENCODE_BIN, "
             "or spawn the role natively")
    except subprocess.TimeoutExpired:
        fail(f"`opencode session export {session}` hung for {EXPORT_TIMEOUT_SECONDS}s — "
             f"the round count can't be checked, so nothing was sent")
    try:
        messages = json.loads(out.stdout)["messages"]
    except (json.JSONDecodeError, KeyError, TypeError):
        fail(f"can't read session {session} back from opencode "
             f"(`opencode session export {session}` exited {out.returncode}) — "
             f"check the id; a revision needs the session it revises")
    return sum(1 for m in messages if m.get("type") == "user")


def explain(error):
    """One line for an opencode error event, with the fix where one is known."""
    if not isinstance(error, dict):
        return str(error)
    data = error.get("data", {})
    message = data.get("message") if isinstance(data, dict) else None
    message = message or error.get("message") or error.get("name") or str(error)
    return message


def parse_events(stdout, session):
    """(reply texts, error lines, session id) from `opencode run --format json`."""
    texts, errors, session_id = [], [], session
    for line in stdout.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        session_id = event.get("sessionID") or session_id
        if event.get("type") == "step_start":
            # Only the last step is the answer; earlier ones are the model
            # narrating its tool calls ("let me read the packet…").
            texts = []
        elif event.get("type") == "text":
            texts.append(event.get("part", {}).get("text", ""))
        elif event.get("type") == "error":
            errors.append(explain(event.get("error", {})))
    return texts, errors, session_id


def fmt_age(seconds):
    """90 -> '1m30s': compact ages for heartbeats and `ps`."""
    seconds = int(seconds)
    if seconds < 60:
        return f"{seconds}s"
    minutes, seconds = divmod(seconds, 60)
    if minutes < 60:
        return f"{minutes}m{seconds:02d}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h{minutes:02d}m"


def _seconds_env(name, default):
    """An env timeout override, or the default; garbage fails loudly rather
    than silently stretching or shrinking a bound nobody can see."""
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        fail(f"{name}={raw!r} is not a number of seconds — unset it or fix it", 2)
    if not math.isfinite(value):
        # nan parses and compares False against everything, so without this
        # a nan timeout silently disables the clock it was meant to set.
        fail(f"{name}={raw!r} is not a finite number of seconds — unset it or fix it", 2)
    if value <= 0:
        fail(f"{name}={raw!r} is not positive — unset it or fix it", 2)
    return value


def runs_dir():
    """Where live-run status files live: the project's .tmp/, overridden for
    hermetic tests. The dir existing is load-bearing — `ps` reads it."""
    override = os.environ.get("HARNESS_AGENT_RUNS_DIR", "").strip()
    base = Path(override) if override else ROOT / ".tmp" / "agent-runs"
    try:
        base.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        fail(f"cannot make runs dir {base} ({exc})")
    return base


def write_status(path, **fields):
    """Best-effort status refresh: losing it must never fail the run it
    describes."""
    try:
        path.write_text(json.dumps(fields))
    except OSError:
        pass


def _alive(pid):
    """Whether a pid answers a signal — the liveness half of `ps`."""
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def live_runs():
    """Live status dicts (each with run_id, elapsed, idle_for), pruning files
    whose agent is gone — a killed session must not haunt `ps` forever."""
    directory = runs_dir()
    live, now = [], time.time()
    for path in sorted(directory.glob("*.json")):
        try:
            info = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(info.get("agent_pid"), int) or not _alive(info["agent_pid"]):
            try:
                path.unlink()
            except OSError:
                pass
            continue
        info["run_id"] = path.stem
        info["elapsed"] = max(0.0, now - info.get("started_at", now))
        info["idle_for"] = max(0.0, now - info.get("last_activity_at",
                                                  info.get("started_at", now)))
        live.append(info)
    return live


def cmd_ps():
    """Every live run with its age: the answer to "is it stuck or working?"."""
    live = live_runs()
    if not live:
        print("agent.py: no live runs", file=sys.stderr)
        return 0
    print("RUN ROLE SESSION ELAPSED IDLE PID")
    for info in sorted(live, key=lambda i: i.get("started_at", 0)):
        print(f"{info['run_id']} {info.get('role', '?')} "
              f"{info.get('session') or '-'} {fmt_age(info['elapsed'])} "
              f"{fmt_age(info['idle_for'])} {info.get('child_pid', '?')}")
    return 0


def _signal_group(pid, sig):
    """A whole child group (grandchildren die too), or the child alone where
    groups don't exist."""
    killpg = getattr(os, "killpg", None)
    if killpg is not None:
        try:
            killpg(pid, sig)
            return
        except OSError:
            pass
    try:
        os.kill(pid, sig)
    except OSError:
        pass


def cmd_stop(args):
    """End one live run: TERM its group, KILL it when it lingers."""
    if len(args) != 1 or args[0] in ("-h", "--help"):
        print("usage: agent.py stop <run-id>  (full id or unique prefix; see `agent.py ps`)",
              file=sys.stderr)
        return 2
    want = args[0]
    matches = [i for i in live_runs()
               if i["run_id"] == want or i["run_id"].startswith(want)]
    if not matches:
        print(f"agent.py: no live run {want} (`agent.py ps` lists live runs)",
              file=sys.stderr)
        return 1
    if len(matches) > 1:
        print(f"agent.py: {want!r} matches {len(matches)} runs — use the full id",
              file=sys.stderr)
        return 2
    info = matches[0]
    child = info.get("child_pid")
    if not isinstance(child, int):
        fail(f"run {info['run_id']} has no child pid recorded", 1)
    _signal_group(child, signal.SIGTERM)
    deadline = time.time() + KILL_GRACE_SECONDS
    while time.time() < deadline and _alive(child):
        time.sleep(0.5)
    if _alive(child):
        _signal_group(child, signal.SIGKILL)
    print(f"agent.py: stopped {info['run_id']} ({info.get('role', '?')})",
          file=sys.stderr)
    return 0


def _drain(stream, chunks, shared, sniff_session):
    """One pipe's reader thread: bank every chunk, stamp the activity clock,
    and (stdout only) pick up the session id from the event stream."""
    buf = ""
    try:
        for chunk in iter(lambda: stream.read(65536), ""):
            chunks.append(chunk)
            shared["last_activity"] = time.time()
            if not sniff_session:
                continue
            buf += chunk
            *lines, buf = buf.split("\n")
            for line in lines:
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(event, dict) and event.get("sessionID"):
                    shared["session_id"] = event["sessionID"]
    except (OSError, ValueError):
        pass
    finally:
        try:
            stream.close()
        except OSError:
            pass


def _kill_proc(proc):
    """TERM a silent or walled child's group (grandchildren die too), KILL it
    when it lingers past the grace period."""
    _signal_group(proc.pid, signal.SIGTERM)
    try:
        proc.wait(timeout=KILL_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        _signal_group(proc.pid, signal.SIGKILL)
        proc.wait()


def require_pin(model, variant):
    """The last check before opencode is spawned: whatever the roster said,
    the run goes out on the pin or not at all. Redundant with model_for today,
    on purpose — a future caller that skips it still can't reach opencode."""
    if (model, variant) != (OPENCODE_MODEL, OPENCODE_VARIANT):
        fail(f"refusing to run opencode on {model}#{variant} — opencode runs "
             f"only on {OPENCODE_MODEL_ARG} (scripts/h models)")


def run_agent(role, agent, model, variant, session, prompt):
    """(reply, session id, refused permissions) from one `opencode run`, or
    fail loudly. Output is drained on threads so the wait loop can watch the
    idle and wall clocks, heartbeat, and keep the status file fresh."""
    require_pin(model, variant)
    # -m carries the variant too, including for `implement`, which runs
    # opencode's own build agent with no file of ours at all. opencode 2
    # dropped `--variant` for `-m provider/model#variant`.
    # `--standalone`: opencode 2 otherwise hands the run to a shared background
    # service, which never sees this process's OPENCODE_CONFIG_CONTENT (so no
    # agent promotion and no /tmp grant) and interrupts runs sharing it.
    command = [opencode_bin(), "run", "--standalone", "--format", "json", "--agent", agent,
               "-m", OPENCODE_MODEL_ARG]
    if session:
        command += ["--session", session]
    env = dict(os.environ)
    env["OPENCODE_CONFIG_CONTENT"] = (json.dumps(pin_config(inherited_config()))
                                      if agent == "build" else agent_config(agent))
    idle_timeout = _seconds_env("HARNESS_AGENT_IDLE_SECONDS", IDLE_TIMEOUT_SECONDS)
    heartbeat_every = _seconds_env("HARNESS_AGENT_HEARTBEAT_SECONDS", HEARTBEAT_SECONDS)
    # Before spawning: a bad HARNESS_AGENT_RUNS_DIR must fail while no child
    # exists, not orphan one while reporting the dir.
    status_dir = runs_dir()
    try:
        # A group of its own, so killing a silent run takes the grandchildren
        # (opencode's tool processes) with it instead of orphaning them.
        proc = subprocess.Popen(command + ["--", prompt], stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True,
                                stdin=subprocess.DEVNULL, cwd=ROOT, env=env,
                                start_new_session=(os.name == "posix"))
    except FileNotFoundError:
        fail("opencode is not on PATH or in ~/.opencode/bin — install it, set OPENCODE_BIN, "
             "or spawn the role natively")
    except OSError as exc:
        fail(f"opencode can't be run ({exc}) — check the install")
    start = time.time()
    shared = {"last_activity": start, "session_id": session}
    out_chunks, err_chunks = [], []
    readers = [threading.Thread(target=_drain, args=(proc.stdout, out_chunks, shared, True),
                                daemon=True),
               threading.Thread(target=_drain, args=(proc.stderr, err_chunks, shared, False),
                                daemon=True)]
    for reader in readers:
        reader.start()
    run_id = time.strftime("%Y%m%d-%H%M%S", time.localtime(start)) + f"-{os.getpid()}"
    status_path = status_dir / f"{run_id}.json"

    def refresh_status():
        write_status(status_path, run_id=run_id, role=role, agent=agent,
                     agent_pid=os.getpid(), child_pid=proc.pid,
                     session=shared["session_id"], started_at=start,
                     last_activity_at=shared["last_activity"])

    refresh_status()
    outcome, next_beat = None, start + heartbeat_every
    try:
        while proc.poll() is None:
            now = time.time()
            if now - shared["last_activity"] >= idle_timeout:
                outcome = "idle"
                break
            if now - start >= TIMEOUT_SECONDS:
                outcome = "wall"
                break
            if now >= next_beat:
                refresh_status()
                beat = (f"agent.py: {role} still running — {fmt_age(now - start)} "
                        f"elapsed, last output {fmt_age(now - shared['last_activity'])} ago")
                if shared["session_id"]:
                    beat += f" (session {shared['session_id']})"
                print(beat, file=sys.stderr)
                next_beat = now + heartbeat_every
            time.sleep(POLL_SECONDS)
        if outcome is not None:
            _kill_proc(proc)
        for reader in readers:
            reader.join(timeout=30)
    except KeyboardInterrupt:
        # Ctrl-C must not orphan the headless child: the wall cap died with
        # this wrapper, so kill the whole group here, then exit 130 — the
        # same code a signal-killed process reports, not 0/1.
        _kill_proc(proc)
        print("agent.py: interrupted — killed the child group", file=sys.stderr)
        sys.exit(130)
    except BaseException:
        # A bug above gets the same cleanup, then the original exit proceeds.
        _kill_proc(proc)
        raise
    finally:
        # A finished run is not a live one: `ps` must stop listing it.
        try:
            status_path.unlink()
        except OSError:
            pass
    stdout_text, stderr_text = "".join(out_chunks), "".join(err_chunks)
    if outcome == "idle":
        where = f" (session {shared['session_id']})" if shared["session_id"] else ""
        fail(f"no output for {fmt_age(idle_timeout)} — killed the silent run{where}; "
             f"`opencode session list` shows where it got to", IDLE_EXIT)
    if outcome == "wall":
        fail(f"no reply after {TIMEOUT_SECONDS // 60} minutes — "
             f"`opencode session list` shows where it got to")

    texts, errors, session_id = parse_events(stdout_text, session)
    if errors:
        fail("opencode reported an error:\n  " + "\n  ".join(errors))
    reply = "\n\n".join(t.strip() for t in texts if t.strip())
    # Headless opencode answers every permission prompt with no, and the agent
    # carries on without whatever it asked for. A reviewer that couldn't open
    # the packet still replies — about something else.
    refused = [strip_ansi(l) for l in stderr_text.splitlines() if "auto-rejecting" in l]
    if proc.returncode != 0 or not reply:
        # An empty reply is not a clean review. Say so rather than print
        # nothing, which the caller would read as "no findings".
        tail = (stderr_text or stdout_text).strip().splitlines()[-5:]
        what = ("with no reply" if not reply
                else "— its reply was discarded, since a failed run's half-answer "
                     "reads like a whole one")
        fail(f"opencode exited {proc.returncode} {what}"
             + "".join(f"\n  {strip_ansi(l)}" for l in tail))
    return reply, session_id, refused


def main(argv):
    if argv[:1] == ["ps"]:
        if len(argv) > 1:
            print("usage: agent.py ps", file=sys.stderr)
            return 2
        return cmd_ps()
    if argv[:1] == ["stop"]:
        return cmd_stop(argv[1:])
    role, session, message = parse_args(argv)
    require_opencode_v2()
    agent = agent_for(role)
    try:
        model, variant = model_for(role), variant_for(role)
    except ForeignModel as exc:
        fail(str(exc))
    if role == "reviewer-design":
        require_image_model(model)

    round_number = 1
    if session:
        round_number = rounds_so_far(session) + 1
        if round_number > MAX_ROUNDS:
            fail(f"session {session} has had {round_number - 1} rounds, the "
                 f"most one gets. Stop revising: finish the change yourself, "
                 f"or file what's left (bd q) and start a fresh session with a "
                 f"brief that says what the last one didn't.", 3)

    prompt = message
    if role == "implement" and not session:
        prompt = IMPLEMENT_CONTRACT + message
    reply, session_id, refused = run_agent(role, agent, model, variant, session, prompt)
    print(reply)
    print(f"agent.py: {role} on {model} ({variant}) · session {session_id} · "
          f"round {round_number} of {MAX_ROUNDS}", file=sys.stderr)
    if refused:
        # The reply is printed anyway — an implementer's report still says what
        # it changed — but the exit says the run was missing something.
        fail("opencode refused it a permission, so the reply above was written "
             "without it:\n  " + "\n  ".join(refused), 4)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
