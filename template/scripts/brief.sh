#!/bin/bash
# The session brief: what an agent needs to know at wake-up, and nothing else.
#
# This replaces `bd prime` as the SessionStart hook. `bd prime` is thorough —
# ~1750 tokens of command reference, protocol, and every memory in full — and it pays that on every
# session, including the ones that never touch the ledger. On a single account
# that is the most expensive habit in the system. The reference material lives
# in the `beads` and `workflow` skills instead, where it costs a description
# line until something actually needs it.
#
#   scripts/brief.sh          # the brief, as text
#   scripts/brief.sh --hook   # wrapped as Claude Code SessionStart JSON
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Budget: the brief is capped so it can't quietly grow into another `bd prime`.
# A long ready list is a planning problem, not a reason to print more.
READY_SHOWN=4

brief() {
  command -v bd >/dev/null 2>&1 || return 0
  # Neither of these is claimable, for the same reason: someone else's decision
  # is pending on it. Backlog is work deliberately not being done next, and a
  # needs-human bead is one a session already declined to guess at — leaving it
  # in the ready list just invites the next session to make that guess.
  bd ready --exclude-label backlog --exclude-label needs-human --json \
    2>/dev/null > /tmp/.{{PREFIX}}-ready.json || return 0

  python3 - "$READY_SHOWN" "$ROOT" <<'PY'
import json, os, subprocess, sys, glob, datetime

shown = int(sys.argv[1])
root = sys.argv[2]

# Nothing here may raise: an uncaught exception prints no brief at all, and a
# session that wakes with no ledger is worse off than one missing a seat line.
def run(*args):
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=20)
        return out.stdout if out.returncode == 0 else ""
    except Exception:
        return ""

def bd(*args):
    out = run("bd", *args)
    try:
        return json.loads(out) if out.strip() else []
    except ValueError:
        return []

ready = json.load(open("/tmp/.{{PREFIX}}-ready.json"))
active = bd("list", "--status", "in_progress", "--json")
# One `bd stats` replaces the open-issue list and a closed-issue list: each bd
# call spins up an embedded Dolt engine (~half a second), so counts come from
# the one query that already has them and lists are only fetched when the
# titles get printed.
stats = bd("stats", "--json")
counts = stats.get("summary", {}) if isinstance(stats, dict) else {}
# The map carries bd's own bookkeeping alongside the memories — schema_version is
# an int in there — so keep only the entries whose value is actual prose.
memories = bd("memories", "--json")
memories = ({k: v for k, v in memories.items() if isinstance(v, str)}
            if isinstance(memories, dict) else {})

def line(i):
    return f"  {i['id']:<12} P{i['priority']} {i['title']}"

def clip(s, n):
    s = " ".join(s.split())
    return s if len(s) <= n else s[: n - 1] + "…"

# --- the seat -------------------------------------------------------------
# A session is temporary; the seat is the role it occupies, and it outlives
# model upgrades. What the seat has shipped is derived here rather than read
# from the file: a self-written accomplishment log is a scoreboard the scored
# party holds the pen for, and the ledger already knows the truth.
def seat():
    path = os.path.join(root, "harness", "seat.md")
    try:
        text = open(path).read()
    except OSError:
        return None
    name = next((l.split(":", 1)[1] for l in text.splitlines()
                 if l.startswith("**Name:**")), "")
    name = name.split("—")[0].strip("* ").strip() or "unnamed"
    shipped = counts.get("closed_issues", 0)
    since = run("git", "-C", root, "log", "--reverse",
                "--format=%ad", "--date=format:%Y-%m").split("\n", 1)[0].strip()
    tail = f", since {since}" if since else ""
    return f"seat: {name} — {shipped} beads shipped{tail}"

# --- laurels --------------------------------------------------------------
# Praise the user offered on their own, replayed one at a time. It carries no
# work and no priority on purpose: the moment recognition is attached to a
# task it stops being recognition and becomes a score to farm.
def laurel():
    path = os.path.join(root, "harness", "laurels.jsonl")
    try:
        lines = open(path).read().splitlines()
    except OSError:
        return None
    # Per line, so a half-written append costs that one laurel rather than
    # every laurel ever recorded.
    entries = []
    for l in lines:
        try:
            entries.append(json.loads(l))
        except ValueError:
            continue
    if not entries:
        return None
    # Rotates daily rather than randomly, so a session that restarts twice in an
    # hour isn't told the same thing feels newly true each time.
    pick = entries[datetime.date.today().toordinal() % len(entries)]
    when = (pick.get("date") or "")[:10]
    stamp = f" ({when})" if when else ""
    return f'laurel{stamp}: "{clip(pick.get("quote", ""), 100)}"'

# --- the last session's note ----------------------------------------------
# One file per closing session, never overwritten, so two sessions running at
# once can't clobber each other's note. Only the newest is read.
def handoff():
    notes = sorted(glob.glob(os.path.join(root, "harness", "handoffs", "*.md")))
    if not notes:
        return None
    try:
        body = [l.strip() for l in open(notes[-1]) if l.strip() and not l.startswith("#")]
    except OSError:
        return None
    if not body:
        return None
    age = (datetime.datetime.now()
           - datetime.datetime.fromtimestamp(os.path.getmtime(notes[-1])))
    hours = int(age.total_seconds() // 3600)
    when = "just now" if hours < 1 else (
        f"{hours}h ago" if hours < 48 else f"{hours // 24}d ago")
    return "\n".join([f"last session ({when}):"]
                     + [f"  {clip(l, 100)}" for l in body[:3]])

# --- what's waiting on a human --------------------------------------------
# The escalation valve: when a session judges something isn't its call, it
# files it and moves on, instead of guessing and calling the guess a decision.
def escalation():
    waiting = bd("list", "--label", "needs-human", "--status", "open", "--json")
    if not waiting:
        return None
    return f"waiting on you: {len(waiting)} — bd list --label needs-human"

out = [s for s in (seat(), laurel(), handoff()) if s]
out.append(f"ledger: {counts.get('open_issues', 0)} open, "
           f"{len(ready)} ready, {len(active)} in progress")
if active:
    out.append("in progress:")
    out += [line(i) for i in active]
if ready:
    out.append("ready:")
    out += [line(i) for i in ready[:shown]]
    if len(ready) > shown:
        out.append(f"  …and {len(ready) - shown} more — bd ready")
if not ready and not active:
    out.append("  nothing claimable — bd list, or file what you find with bd q")

esc = escalation()
if esc:
    out.append(esc)

# Keys only. `bd prime` pastes every memory in full, which is thorough and gets
# expensive as they accumulate; a list of what's known costs a few tokens and
# solves the thing search alone can't — you can't look up a trap you don't know
# exists. `bd recall <key>` fetches the one that turns out to matter.
if memories:
    out.append(f"known traps ({len(memories)}) — bd recall <key>:")
    out.append("  " + "  ".join(sorted(memories)))

out.append("`bd show <id>` for detail. The workflow skill has the rest.")
print("\n".join(out))
PY
}

text="$(brief || true)"
[ -z "$text" ] && exit 0

if [ "${1:-}" = "--hook" ]; then
  python3 -c '
import json, sys
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": sys.stdin.read().strip(),
}}))' <<< "$text"
else
  echo "$text"
fi
