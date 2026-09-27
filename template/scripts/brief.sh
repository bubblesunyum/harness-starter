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
# A long ready list is a planning problem, not a reason to print more. The one
# deliberate exception is the seat's identity below it — ~120 tokens, once per
# session, for the file whose header promises exactly that.
READY_SHOWN=4

brief() {
  command -v bd >/dev/null 2>&1 || return 0
  # Neither of these is claimable, for the same reason: someone else's decision
  # is pending on it. Backlog is work deliberately not being done next, and a
  # needs-human bead is one a session already declined to guess at — leaving it
  # in the ready list just invites the next session to make that guess.
  # A mktemp file, not a fixed /tmp path: the value is consumed once, by the
  # python below, in this same invocation, so it needs no per-project prefix —
  # and a fixed name would collide between two checkouts of one project.
  ready_json="$(mktemp -t harness-ready)" || return 0
  trap 'rm -f "$ready_json"' RETURN
  bd ready --exclude-label backlog --exclude-label needs-human --json \
    2>/dev/null > "$ready_json" || return 0

  python3 - "$READY_SHOWN" "$ROOT" "$ready_json" <<'PY'
import json, os, re, subprocess, sys, glob, datetime

shown = int(sys.argv[1])
root = sys.argv[2]
try:
    ready = json.load(open(sys.argv[3]))
except (OSError, ValueError):
    ready = []
if not isinstance(ready, list):
    ready = []

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
#
# The rest of the identity — role, pronouns, and the paragraphs the installer
# asked for — is carried on the line below the seat. seat.md's header calls
# itself the part a session is told about itself at wake-up, and for a while
# nothing read past the Name line, which made edits there a belief without an
# effect. The paragraphs cost ~120 tokens once per session, against a brief of
# ~100; that is the header's claim being true rather than the brief growing.
def seat_text():
    # Exception, not OSError: one bad byte in a user-edited file must cost the
    # seat line, not the whole brief.
    try:
        return open(os.path.join(root, "harness", "seat.md"),
                    errors="replace").read()
    except Exception:
        return ""

def field(text, key):
    for l in text.splitlines():
        s = l.lstrip()
        if s.startswith("**%s:**" % key):
            return s.split(":", 1)[1].strip("* ").strip()
    return ""

def seat():
    text = seat_text()
    if not text:
        return None
    # Loud when the format moved rather than the name being blank: a blank Name
    # is the file saying it isn't finished, but a missing Name line means this
    # parser no longer reads the file and every brief would say "unnamed" with
    # nothing failing.
    if not any(l.lstrip().startswith("**Name:**") for l in text.splitlines()):
        return "seat: (unparseable harness/seat.md — expected a **Name:** line)"
    name = field(text, "Name").split("—")[0].strip() or "unnamed"
    shipped = counts.get("closed_issues", 0)
    since = run("git", "-C", root, "log", "--reverse",
                "--format=%ad", "--date=format:%Y-%m").split("\n", 1)[0].strip()
    tail = f", since {since}" if since else ""
    return f"seat: {name} — {shipped} beads shipped{tail}"

def identity():
    # Only what comes after the Name/Role/Pronouns block: the header
    # paragraphs above it explain the file, they are not the identity, and the
    # closing line is procedure, not who the seat is.
    text = seat_text()
    if not text:
        return None
    body = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    lines = body.splitlines()
    meta = ("**Name:**", "**Role:**", "**Pronouns:**")
    idx = max((i for i, l in enumerate(lines)
               if l.lstrip().startswith(meta)), default=-1)
    paras, cur = [], []
    for l in lines[idx + 1:] + [""]:
        s = l.strip()
        if not s or s.startswith("#"):
            if cur:
                paras.append(" ".join(cur))
                cur = []
            continue
        cur.append(s)
    # At paragraph level, so the wrapped closing sentence goes as one: it is
    # procedure ("write things down"), not identity, and seat.md says so.
    paras = [p for p in paras
             if not p.startswith("You are not the first session")]
    role = field(text, "Role")
    pronouns = field(text, "Pronouns")
    prose = clip(" ".join(paras), 400)
    bits = " ".join(b for b in (
        role, ("(%s)" % pronouns) if pronouns else "", prose) if b)
    return ("identity: %s" % bits) if bits else None

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

# --- whether the beads are reaching git ------------------------------------
# The ledger rides its own ref (refs/dolt/data), which moves only when
# something runs `bd dolt push` — a normal `git push` carries none of it. This
# is one line when the beads need a push and silence otherwise. Local only, no
# fetch and no push: the brief may not take outward-facing actions, and a
# SessionStart hook that pushed would do it every session.
def ledger_push():
    out = run("bash", os.path.join(root, "scripts", "ledger-push.sh"),
              "--check")
    return out.strip() or None

out = [s for s in (seat(), identity(), laurel(), handoff()) if s]
out.append(f"ledger: {counts.get('open_issues', 0)} open, "
           f"{len(ready)} ready, {len(active)} in progress")
push = ledger_push()
if push:
    out.extend(push.splitlines())
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
