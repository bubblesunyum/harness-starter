#!/usr/bin/env python3
"""Runs one harness role through opencode, on the one model opencode runs on.

    scripts/harness agent <role> <message...>                   # a fresh session
    scripts/harness agent <role> --session <id> <message...>    # one more round in it
    scripts/harness agent ps                                    # live runs and their age
    scripts/harness agent stop <run-id>                         # end one live run

    scripts/harness agent reviewer-correctness "Review /tmp/x-review.md — adds a cache"
    scripts/harness agent implement "har-abc: $(bd show har-abc)"
    scripts/harness agent implement --session ses_123 "verify fails: missing import in foo.py"

The reply goes to stdout. The session id, model and round go to stderr, as one
line — the id is what a revision round needs. A `-h`/`--help` anywhere after
the role is usage, never a brief — it exits 2 without spawning anything.

Exits 0 with a reply; 1 when the run failed and there is no reply to trust; 2 on
a usage error; 3 when the session is past its revision cap, without running; 4
when opencode refused a permission — the reply is still printed, but was
written without what it asked for; 5 when the child went silent past the idle
limit and was killed.

A silent child is killed: no output, events, or live tool commands for
HARNESS_AGENT_IDLE_SECONDS (default 300) ends the run with exit 5, whatever
the wall cap still allows. A tool command counts as activity only while it
is young: a direct child of the run, not a zombie, first seen less than
HARNESS_AGENT_TOOL_SECONDS (default 1200) ago. Past that age it stops
counting and the normal idle limit applies, so a stuck command or a
session-long helper hands control back instead of holding the run open.
While it runs, a heartbeat line goes to stderr every
HARNESS_AGENT_HEARTBEAT_SECONDS (default 120) with the elapsed time, the
last activity, worktree progress on implement runs, and the live tool
command, and .tmp/agent-runs/<run-id>.json carries the same for
`agent.py ps` and `agent.py stop`. HARNESS_AGENT_RUNS_DIR overrides the dir
(hermetic tests point it at a temp dir). An interrupted wrapper (Ctrl-C)
kills the child's process group before exiting 130, so no headless run
outlives the wrapper that was capping it.

This is how a session in any tool — Claude Code included — hands work to a
model that isn't its own: the packet or the brief is read in a separate
opencode process, off the caller's context, on OPENCODE_MODEL at
OPENCODE_VARIANT (scripts/harness models). There is no flag or variable to pick
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
# No output, events, or live tool commands for this long and the child is
# dead weight: kill it, separate from the wall cap above (a chatty run may
# still use all 45 minutes). Short enough that a stuck worker is noticed in
# minutes; a legitimately long tool command still counts as activity.
IDLE_TIMEOUT_SECONDS = 5 * 60
# A tool command counts as activity only while it is young: past this age it
# stops counting and the normal idle limit applies, so a stuck command or a
# session-long helper hands control back instead of holding the run open.
TOOL_TIMEOUT_SECONDS = 20 * 60
# How often a running child says its age on stderr and refreshes its status.
HEARTBEAT_SECONDS = 2 * 60
# How often the wait loop re-checks the idle and wall clocks.
POLL_SECONDS = 1.0
# TERM-to-KILL patience when stopping a child or a silent one.
KILL_GRACE_SECONDS = 10
# A silent child was killed (exit 1 stays the failed run, 2 the usage error).
IDLE_EXIT = 5
# Consecutive `ps` failures before the tool watch gives up for the run.
PS_STRIKES = 3
# Repo-relative dir of live-run status files: written by this runner, never
# counted as the worker's changed files.
RUNNER_OWN_PREFIX = ".tmp/agent-runs/"

IMPLEMENT_CONTRACT = """\
You are a delegated implementer. Another agent wrote this brief, will review \
your diff, and owns everything around the change. So, overriding AGENTS.md \
for this session:

- Do not commit, stage, or touch the bd ledger. The caller does all three.
- Do not run scripts/harness review or spawn reviewers. You are being reviewed.
- Stay inside the brief. Something else worth doing goes in your report, not \
in the diff.
- Run scripts/harness verify before you finish, and fix what it catches.

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
    fail(f"no .opencode/agent/{role}.md — run scripts/harness opencode-agents, "
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


def temp_dirs():
    """The system temp dirs, each spelled as written and as resolved.
    review.sh writes its packet to /tmp, and a worker's own mktemp lands in
    $TMPDIR — on macOS under /var/folders, not /tmp at all. opencode checks
    the path as the agent wrote it, and /tmp is a symlink on macOS, so both
    spellings of each are needed."""
    dirs = set()
    for tmp in ("/tmp", tempfile.gettempdir()):
        tmp = tmp.rstrip("/") or "/"
        dirs.update({tmp, os.path.realpath(tmp)})
    return sorted(dirs)


def agent_config(agent):
    """OPENCODE_CONFIG_CONTENT for one run: pinned throughout, the system temp
    dirs readable, and a generated agent runnable by `opencode run --agent`.

    Headless opencode auto-rejects every path outside the project and the
    run dies on it, so a reviewer could not read its packet and a worker
    could not read back its own mktemp output. Only temp dirs are granted.

    The generated agents are `mode: subagent` so they stay out of opencode's
    agent picker, and `run --agent` quietly falls back to the default agent for
    a subagent — a reviewer that never saw its own prompt. Promoting it for
    this one process is the only fix that touches neither. `build` is
    opencode's own primary and needs no promotion."""
    config = inherited_config()
    if not isinstance(config.get("agent", {}).get(agent, {}), dict):
        fail(f"OPENCODE_CONFIG_CONTENT sets agent.{agent} to something that "
             f"isn't an object — unset it or fix it")
    settings = config.setdefault("agent", {}).setdefault(agent, {})
    if agent != "build":
        settings["mode"] = "primary"
    permission = settings.setdefault("permission", {})
    if not isinstance(permission, dict):
        fail(f"OPENCODE_CONFIG_CONTENT sets agent.{agent}.permission to something "
             f"that isn't an object — unset it or fix it")
    outside = permission.setdefault("external_directory", {})
    if not isinstance(outside, dict):
        fail(f"OPENCODE_CONFIG_CONTENT sets agent.{agent}.permission.external_directory "
             f"to something that isn't an object — unset it or fix it")
    for tmp in temp_dirs():
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


def _select_live_tools(rows, child_pid, tool_timeout, seen, now):
    """[(pid, command)] counted as live tool commands from parsed ps rows
    (pid, ppid, stat, command). A row counts only when it is a direct child
    of the run (a backgrounded server reparented to init drops out — group
    membership rides on ppid, not pgid), is not a zombie, and was first seen
    less than tool_timeout ago. Pids gone from the table are forgotten, so a
    reused pid starts a fresh age."""
    live, present = [], set()
    for pid, ppid, stat, command in rows:
        if ppid != child_pid or stat.startswith("Z"):
            continue
        present.add(pid)
        if now - seen.setdefault(pid, now) >= tool_timeout:
            continue
        live.append((pid, command))
    for pid in list(seen):
        if pid not in present:
            del seen[pid]
    return live


def _live_tool_procs(child_pid, tool_timeout, seen, now):
    """[(pid, command)] for the run's live tool commands, or None when `ps`
    fails. Bytes off the pipe, decoded with replace: an undecodable argv
    never raises its way out of the wait loop."""
    try:
        out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,pgid=,stat=,command="],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=2)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    try:
        rows = []
        for line in out.stdout.decode("utf-8", errors="replace").splitlines():
            parts = line.split(None, 4)
            if len(parts) < 4:
                continue
            try:
                pid, ppid = int(parts[0]), int(parts[1])
            except ValueError:
                continue
            rows.append((pid, ppid, parts[3], parts[4] if len(parts) > 4 else ""))
        return _select_live_tools(rows, child_pid, tool_timeout, seen, now)
    except ValueError:
        return None


def _git_snapshot():
    """(porcelain {path: status}, added, deleted) of the worktree, or None
    outside a git checkout. Best effort: a repo the wrapper can't read says
    nothing rather than failing the run it describes."""
    try:
        porcelain = subprocess.run(["git", "status", "--porcelain", "-uall"], stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, cwd=ROOT, timeout=5)
        shortstat = subprocess.run(["git", "diff", "--shortstat"], stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, cwd=ROOT, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if porcelain.returncode != 0 or shortstat.returncode != 0:
        return None
    try:
        files = {}
        for line in porcelain.stdout.decode("utf-8", errors="replace").splitlines():
            # The runner's own status files are not the worker's progress;
            # -uall lists them one by one, so they must be skipped by name.
            if len(line) > 3 and not line[3:].startswith(RUNNER_OWN_PREFIX):
                files[line[3:]] = line[:2]
        added = deleted = 0
        short = shortstat.stdout.decode("utf-8", errors="replace")
        match = re.search(r"(\d+) insertion", short)
        if match:
            added = int(match.group(1))
        match = re.search(r"(\d+) deletion", short)
        if match:
            deleted = int(match.group(1))
        return files, added, deleted
    except ValueError:
        return None


def _worktree_progress(snapshot):
    """'N file(s), +A/-D since start' against the spawn snapshot, or None
    when there is no snapshot. N counts files whose porcelain status changed;
    the shortstat delta is an approximation — it misses untracked files,
    which the porcelain count still catches. Deltas clamp at zero, so a
    revert below the snapshot reads +0/-0 instead of printing a doubled
    sign; the file count still shows something moved."""
    if snapshot is None:
        return None
    old_files, old_added, old_deleted = snapshot
    current = _git_snapshot()
    if current is None:
        return None
    new_files, new_added, new_deleted = current
    changed = sum(1 for path in set(old_files) | set(new_files)
                  if old_files.get(path) != new_files.get(path))
    word = "file" if changed == 1 else "files"
    added = max(0, new_added - old_added)
    removed = max(0, new_deleted - old_deleted)
    return f"{changed} {word}, +{added}/-{removed} since start"


def _running_command(tool_procs):
    """'running: <cmd>' for the youngest live tool command, or '' when none
    is counted. The youngest is the highest pid — good enough to name the
    tool at work."""
    if not tool_procs:
        return ""
    youngest = max(tool_procs, key=lambda proc: proc[0])[1]
    return "running: " + re.sub(r"\s+", " ", youngest).strip()[:60]


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
    print("RUN ROLE SESSION ELAPSED IDLE PID PROGRESS")
    for info in sorted(live, key=lambda i: i.get("started_at", 0)):
        print(f"{info['run_id']} {info.get('role', '?')} "
              f"{info.get('session') or '-'} {fmt_age(info['elapsed'])} "
              f"{fmt_age(info['idle_for'])} {info.get('child_pid', '?')} "
              f"{info.get('progress') or '-'}")
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
             f"only on {OPENCODE_MODEL_ARG} (scripts/harness models)")


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
    # agent promotion and no temp-dir grant) and interrupts runs sharing it.
    command = [opencode_bin(), "run", "--standalone", "--format", "json", "--agent", agent,
               "-m", OPENCODE_MODEL_ARG]
    if session:
        command += ["--session", session]
    env = dict(os.environ)
    env["OPENCODE_CONFIG_CONTENT"] = agent_config(agent)
    # The opencode session plugin injects the brief into every session's
    # system prompt; a headless run already carries its brief in the message,
    # so it opts out here rather than paying for the brief twice.
    env["HARNESS_AGENT_RUN"] = "1"
    idle_timeout = _seconds_env("HARNESS_AGENT_IDLE_SECONDS", IDLE_TIMEOUT_SECONDS)
    heartbeat_every = _seconds_env("HARNESS_AGENT_HEARTBEAT_SECONDS", HEARTBEAT_SECONDS)
    tool_timeout = _seconds_env("HARNESS_AGENT_TOOL_SECONDS", TOOL_TIMEOUT_SECONDS)
    # Worktree progress is implement-only: other roles shouldn't move the tree.
    spawn_snapshot = _git_snapshot() if role == "implement" else None
    # Before spawning: a bad HARNESS_AGENT_RUNS_DIR must fail while no child
    # exists, not orphan one while reporting the dir.
    status_dir = runs_dir()
    start = time.time()
    shared = {"last_activity": start, "session_id": session}
    out_chunks, err_chunks = [], []
    run_id = time.strftime("%Y%m%d-%H%M%S", time.localtime(start)) + f"-{os.getpid()}"
    status_path = status_dir / f"{run_id}.json"

    def refresh_status(progress=""):
        write_status(status_path, run_id=run_id, role=role, agent=agent,
                     agent_pid=os.getpid(), child_pid=proc.pid,
                     session=shared["session_id"], started_at=start,
                     last_activity_at=shared["last_activity"],
                     progress=progress)

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
    # Everything from here on sits inside the cleanup below: once the child
    # exists, an interrupt anywhere must still kill its group.
    try:
        readers = [threading.Thread(target=_drain, args=(proc.stdout, out_chunks, shared, True),
                                    daemon=True),
                   threading.Thread(target=_drain, args=(proc.stderr, err_chunks, shared, False),
                                    daemon=True)]
        for reader in readers:
            reader.start()
        refresh_status(_worktree_progress(spawn_snapshot) or "")
        outcome, next_beat = None, start + heartbeat_every
        # ps gets three strikes in a row before the watch goes output-only: one
        # load spike must not blind the guard for the rest of a 45-minute run.
        ps_failures, running_detail, seen = 0, "", {}
        while proc.poll() is None:
            now = time.time()
            if ps_failures >= PS_STRIKES:
                tool_procs = []
            else:
                tool_procs = _live_tool_procs(proc.pid, tool_timeout, seen, now)
                if tool_procs is None:
                    # `ps` is how a live tool command counts as activity;
                    # without it the idle guard watches output only, said once.
                    ps_failures += 1
                    tool_procs = []
                    if ps_failures == PS_STRIKES:
                        print("agent.py: `ps` keeps failing — idle guard watches output only",
                              file=sys.stderr)
                else:
                    ps_failures = 0
            if tool_procs:
                # A running tool command is activity: the idle clock restarts
                # here instead of advancing, so a legitimately long silent
                # command doesn't read as a stuck run. The wall cap below
                # still bounds it, so a hung tool still dies at the wall.
                # max(): ps can block, and a drain thread may have stamped a
                # later time meanwhile — never rewind the clock it set.
                shared["last_activity"] = max(shared["last_activity"], now)
                running_detail = _running_command(tool_procs)
            else:
                running_detail = ""
            if now - shared["last_activity"] >= idle_timeout:
                outcome = "idle"
                break
            if now - start >= TIMEOUT_SECONDS:
                outcome = "wall"
                break
            if now >= next_beat:
                progress = _worktree_progress(spawn_snapshot) or ""
                refresh_status(progress)
                beat = (f"agent.py: {role} still running — {fmt_age(now - start)} "
                        f"elapsed, last activity {fmt_age(now - shared['last_activity'])} ago")
                if progress:
                    beat += f" · {progress}"
                if running_detail:
                    beat += f" · {running_detail}"
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
        fail(f"no output or tool activity for {fmt_age(idle_timeout)} — killed "
             f"the silent run{where}; "
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
    # A shell starts background jobs with SIGINT ignored, and Python keeps an
    # inherited SIG_IGN: launched that way (the gate's parallel probes, any
    # `&`), a SIGINT would never reach run_agent's cleanup and the child group
    # would outlive the wrapper.
    signal.signal(signal.SIGINT, signal.default_int_handler)
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
