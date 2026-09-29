#!/usr/bin/env python3
"""Runs one harness role through opencode, on the model the roster gives it.

    scripts/agent.py <role> <message...>                   # a fresh session
    scripts/agent.py <role> --session <id> <message...>    # one more round in it

    scripts/agent.py reviewer-correctness "Review /tmp/x-review.md — adds a cache"
    scripts/agent.py implement "har-abc: $(bd show har-abc)"
    scripts/agent.py implement --session ses_123 "verify fails: missing import in foo.py"

The reply goes to stdout. The session id, model and round go to stderr, as one
line — the id is what a revision round needs.

Exits 0 with a reply; 1 when the run failed and there is no reply to trust; 2 on
a usage error; 3 when the session is past its revision cap, without running; 4
when opencode refused a permission — the reply is still printed, but was
written without what it asked for.

This is how a session in any tool — Claude Code included — hands work to a
model that isn't its own: the packet or the brief is read in a separate
opencode process, off the caller's context, on whatever model
harness/models.json names for the role.

Roles with an agent in .opencode/agent/ (the reviewers, the librarian) run that
agent. `implement` runs opencode's own build agent behind a short contract,
because AGENTS.md — which opencode loads into every session — tells an agent to
claim beads, commit and run the review pass, and all three belong to the caller.

A session takes at most MAX_ROUNDS messages: the brief and two revisions. Past
that the script refuses, because a fourth "please fix" rarely lands where the
first three didn't, and each one re-reads the whole thread.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OPENCODE_AGENTS = ROOT / ".opencode/agent"

sys.path.insert(0, str(Path(__file__).resolve().parent))
from models import model_for, variant_for

MAX_ROUNDS = 3
# Long enough for an implementer that runs the gate twice; short enough that a
# hung provider is noticed before the calling session gives up on it.
TIMEOUT_SECONDS = 45 * 60
EXPORT_TIMEOUT_SECONDS = 60

IMPLEMENT_CONTRACT = """\
You are a delegated implementer. Another agent wrote this brief, will review \
your diff, and owns everything around the change. So, overriding AGENTS.md \
for this session:

- Do not commit, stage, or touch the bd ledger. The caller does all three.
- Do not run scripts/review.sh or spawn reviewers. You are being reviewed.
- Stay inside the brief. Something else worth doing goes in your report, not \
in the diff.
- Run scripts/verify.sh before you finish, and fix what it catches.

End with a short report: the files you changed, what verify.sh said, and \
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


def parse_args(argv):
    """(role, session or None, message)."""
    if len(argv) < 2 or argv[0] in ("-h", "--help"):
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        sys.exit(2)
    role, rest, session = argv[0], argv[1:], None
    if rest[:1] == ["--session"]:
        if len(rest) < 3:
            fail("--session needs an id and a message", 2)
        session, rest = rest[1], rest[2:]
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
    fail(f"no .opencode/agent/{role}.md — run scripts/opencode-agents.py, "
         f"or check the role name against harness/models.json")


def require_image_model(model):
    """Refuse a visual review unless OpenCode says its model accepts images."""
    provider, separator, _ = model.partition("/")
    if not separator:
        fail(f"reviewer-design model {model} has no provider ID")
    try:
        out = subprocess.run(["opencode", "models", provider, "--verbose"],
                             capture_output=True, text=True, stdin=subprocess.DEVNULL,
                             cwd=ROOT, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        fail(f"cannot verify image support for {model}; run reviewer-design natively")
    if out.returncode != 0:
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


def agent_config(agent):
    """OPENCODE_CONFIG_CONTENT that lets `opencode run --agent` use a generated
    agent, and lets it read what review.sh hands it.

    The generated agents are `mode: subagent` so they stay out of opencode's
    agent picker, and `run --agent` quietly falls back to the default agent for
    a subagent — a reviewer that never saw its own prompt. Promoting it for
    this one process is the only fix that touches neither.

    review.sh writes the packet and the captures to /tmp, outside the project,
    and headless opencode auto-rejects every read out there. Both spellings are
    granted because /tmp is a symlink on macOS and opencode checks the path as
    the agent wrote it."""
    existing = os.environ.get("OPENCODE_CONFIG_CONTENT", "").strip()
    try:
        config = json.loads(existing) if existing else {}
    except json.JSONDecodeError:
        fail("OPENCODE_CONFIG_CONTENT is set but is not JSON — unset it or fix it")
    if not isinstance(config, dict) or not isinstance(config.get("agent", {}), dict):
        fail("OPENCODE_CONFIG_CONTENT is set but is not a JSON object with an "
             "object for `agent`")
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
    return json.dumps(config)


def rounds_so_far(session):
    """User messages already in a session, read back from opencode itself so
    the cap can't be dodged by losing a counter file."""
    try:
        out = subprocess.run(["opencode", "export", session], capture_output=True,
                             text=True, stdin=subprocess.DEVNULL, cwd=ROOT,
                             timeout=EXPORT_TIMEOUT_SECONDS)
    except FileNotFoundError:
        fail("opencode is not on PATH — install it, or spawn the role natively")
    except subprocess.TimeoutExpired:
        fail(f"`opencode export {session}` hung for {EXPORT_TIMEOUT_SECONDS}s — "
             f"the round count can't be checked, so nothing was sent")
    try:
        messages = json.loads(out.stdout)["messages"]
    except (json.JSONDecodeError, KeyError, TypeError):
        fail(f"can't read session {session} back from opencode "
             f"(`opencode export {session}` exited {out.returncode}) — "
             f"check the id; a revision needs the session it revises")
    return sum(1 for m in messages if m.get("info", {}).get("role") == "user")


def explain(error):
    """One line for an opencode error event, with the fix where one is known."""
    data = error.get("data", {}) if isinstance(error, dict) else {}
    message = data.get("message") or error.get("name") or str(error)
    if "free tier can only be used from within OpenCode" in message:
        return (f"{message}\n  OpenCode's free models refuse every agent but "
                f"opencode's built-in ones. Point this role at a paid model "
                f"in harness/models.json.")
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


def run_agent(agent, model, variant, session, prompt):
    """(reply, session id, refused permissions) from one `opencode run`, or
    fail loudly."""
    command = ["opencode", "run", "--format", "json", "--agent", agent,
               "-m", model]
    if variant:
        # No generated file carries it, so the flag is the whole mechanism —
        # including for `implement`, which runs opencode's own build agent
        # with no file of ours at all.
        command += ["--variant", variant]
    if session:
        command += ["--session", session]
    env = dict(os.environ)
    if agent != "build":
        env["OPENCODE_CONFIG_CONTENT"] = agent_config(agent)
    try:
        # `--`, or a message starting with "-" is read as a flag and dropped.
        out = subprocess.run(command + ["--", prompt], capture_output=True, text=True,
                             stdin=subprocess.DEVNULL, cwd=ROOT, env=env,
                             timeout=TIMEOUT_SECONDS)
    except FileNotFoundError:
        fail("opencode is not on PATH — install it, or spawn the role natively")
    except subprocess.TimeoutExpired:
        fail(f"no reply after {TIMEOUT_SECONDS // 60} minutes — "
             f"`opencode session list` shows where it got to")

    texts, errors, session_id = parse_events(out.stdout, session)
    if errors:
        fail("opencode reported an error:\n  " + "\n  ".join(errors))
    reply = "\n\n".join(t.strip() for t in texts if t.strip())
    # Headless opencode answers every permission prompt with no, and the agent
    # carries on without whatever it asked for. A reviewer that couldn't open
    # the packet still replies — about something else.
    refused = [strip_ansi(l) for l in out.stderr.splitlines() if "auto-rejecting" in l]
    if out.returncode != 0 or not reply:
        # An empty reply is not a clean review. Say so rather than print
        # nothing, which the caller would read as "no findings".
        tail = (out.stderr or out.stdout).strip().splitlines()[-5:]
        what = ("with no reply" if not reply
                else "— its reply was discarded, since a failed run's half-answer "
                     "reads like a whole one")
        fail(f"opencode exited {out.returncode} {what}"
             + "".join(f"\n  {strip_ansi(l)}" for l in tail))
    return reply, session_id, refused


def main(argv):
    role, session, message = parse_args(argv)
    agent = agent_for(role)
    model = model_for(role)
    if not model:
        fail(f"no model for {role} in harness/models.json — "
             f"run scripts/models.py ensure")
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
    variant = variant_for(role)
    reply, session_id, refused = run_agent(agent, model, variant, session, prompt)
    print(reply)
    model_label = f"{model} ({variant})" if variant else model
    print(f"agent.py: {role} on {model_label} · session {session_id} · "
          f"round {round_number} of {MAX_ROUNDS}", file=sys.stderr)
    if refused:
        # The reply is printed anyway — an implementer's report still says what
        # it changed — but the exit says the run was missing something.
        fail("opencode refused it a permission, so the reply above was written "
             "without it:\n  " + "\n  ".join(refused), 4)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
