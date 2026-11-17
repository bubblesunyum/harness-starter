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
#   scripts/harness brief          # the brief, as text
#   scripts/harness brief --hook   # wrapped as Claude Code SessionStart JSON
#   scripts/harness brief --hook --prepend <file> [--append <file>]
#                           # contract first, brief, skill note last — one JSON
set -euo pipefail

# --prepend/--append exist for `scripts/harness session`, which prints the shared
# contract before the brief (and a fresh-link skill note after) as one
# SessionStart object. The JSON wrapper stays here so its python-missing
# fallback has a single home; without these flags the script behaves exactly
# as before.
hook=0
prepend=""
append=""
while [ $# -gt 0 ]; do
  case "$1" in
    --hook) hook=1; shift ;;
    --prepend)
      if [ -z "${2:-}" ]; then
        echo "brief.sh: --prepend needs a file" >&2
        exit 2
      fi
      prepend="$2"; shift 2 ;;
    --append)
      if [ -z "${2:-}" ]; then
        echo "brief.sh: --append needs a file" >&2
        exit 2
      fi
      append="$2"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

ROOT="${HARNESS_PROJECT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# Where this script was loaded from: the shared checkout, whose scripts/ holds
# the copy a project file shadows. Same as ROOT when run as an installed copy.
HARNESS="${HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

. "$HARNESS/scripts/lib/paths.sh"
. "$HARNESS/scripts/lib/journal.sh"

# Budget: the brief is capped so it can't quietly grow into another `bd prime`.
# A long ready list is a planning problem, not a reason to print more. The one
# deliberate exception is the seat's identity below it — ~120 tokens, once per
# session, for the file whose header promises exactly that.
READY_SHOWN=4

# --- Consolidation cadence: brief.sh is a contract file, never installed
# into a project, so per-project tuning lives in the five numbers below,
# never in the logic that reads them — a Tune here block, not FILL THIS IN,
# because only seeds may carry a fill-in block. The librarian pass is due when (>= NOTES handoff
# notes newer than the marker AND the marker is HOURS old) OR any pressure
# signal: more known traps than MAX_TRAPS, LESSONS lessons on one target, or
# FINDINGS findings in one category. The brief prints one line when due and
# nothing otherwise; it never runs the pass. The calling session runs the
# librarian and resets the marker by writing the current UTC time into
# harness/.last-consolidation. A missing or empty marker means no pass has
# run yet, so cadence has nothing to measure from — pressure still applies,
# and a fresh install stays silent because it carries no pressure, not
# because the marker is missing.
# ── Tune here: thresholds, this block only.
CONSOLIDATION_NOTES=5
CONSOLIDATION_HOURS=24
CONSOLIDATION_MAX_TRAPS=8
CONSOLIDATION_LESSONS=3
CONSOLIDATION_FINDINGS=3

# The seat's name off the **Name:** line, on stdout: leading whitespace and
# wrapping asterisks stripped, cut at the first em-dash (a descriptor after
# it is not the name). The python seat() below parses the same way, so a seat
# never reads named in one place and unnamed in the other.
seat_name() {
  sed -n 's/^[[:space:]]*\*\*Name:\*\*[[:space:]]*//p' "$ROOT/harness/seat.md" 2>/dev/null \
    | head -1 | sed -e 's/^[*[:space:]]*//' -e 's/—.*//' -e 's/[*[:space:]]*$//'
}

# Loud when the setup is broken. brief() below goes quiet when a prerequisite
# is missing — no bd, no python3, no usable ledger — which reads as a healthy
# session with nothing to do. These checks are shell only, so they still print
# when bd and python3 are both gone, and they run first so the problem is the
# first thing a session sees. One line per problem, each with the fix; silence
# here means the setup is fine. Never fails: a diagnostic that errors out is
# the silence it exists to replace.
preflight() {
  command -v bd >/dev/null 2>&1 || \
    echo "bd: not found — the ledger, the brief, and the commit hook need it; see https://github.com/steveyegge/beads"
  python3 -c 'pass' >/dev/null 2>&1 || \
    echo "python3: not found — the brief needs it for the ledger summary; install Python 3"
  # Keyed on `bd list` actually answering, not on `.beads` existing: the
  # directory can be there with no database behind it, and bd can answer from
  # a parent checkout — either way only a failing query proves it is broken.
  if command -v bd >/dev/null 2>&1 && ! bd list --json --all >/dev/null 2>&1; then
    if [ ! -d "$ROOT/.beads/embeddeddolt" ]; then
      echo "ledger: no database (.beads/embeddeddolt missing) — run 'bd init' to create it"
    else
      echo "ledger: 'bd list' fails here — run it and check the error"
    fi
  fi
  # The seat's name, read the same way the python below does (a **Name:** line).
  # Owned here rather than there so an unnamed seat still prints when bd or
  # python3 is missing and the summary never runs; seat() below stays silent
  # on these so the line appears once.
  if [ ! -f "$ROOT/harness/seat.md" ]; then
    echo "seat: no harness/seat.md — re-run the installer to restore it"
  elif ! grep -q '^[[:space:]]*\*\*Name:\*\*' "$ROOT/harness/seat.md" 2>/dev/null; then
    echo "seat: harness/seat.md has no **Name:** line — the brief reads the seat from that line"
  elif [ -z "$(seat_name)" ]; then
    echo "seat: unnamed — set **Name:** in harness/seat.md"
  fi
  if [ -f "$ROOT/scripts/verify.steps.sh" ] && \
     grep -q '^step "build" false' "$ROOT/scripts/verify.steps.sh" 2>/dev/null; then
    echo "gate: scripts/verify.steps.sh is still the placeholder — replace 'step \"build\" false' with real commands"
  fi
  [ -f "$ROOT/harness/models.json" ] || \
    echo "models: no harness/models.json — run scripts/harness models ensure to write it"
}

# One consolidation-due line on stdout, or nothing. Takes the brief text as $1
# (to read the known-traps count without another bd spawn). Never runs the
# pass, never fails: every fallible read is guarded, because a diagnostic that
# errors out is the silence this script exists to replace. Callers append the
# line to the brief text; at most one line ever comes back.
say_due() { # say_due REASON — the one user-facing instruction, in one place
  printf 'consolidation due: %s — run the librarian, then reset harness/.last-consolidation\n' "$1"
}
consolidation_due() {
  local marker age_min notes traps_n hits lesson_hit finding_hit date_line marker_text
  marker="$ROOT/harness/.last-consolidation"
  # Cadence needs a marker to measure from; a missing or empty one means no
  # pass has run yet, so there is no "since" to count. Pressure below still
  # runs — a fresh install stays silent because it has no pressure, not
  # because the marker is missing.
  if [ -f "$marker" ] && [ -s "$marker" ]; then
    notes=0
    if [ -d "$ROOT/harness/handoffs" ]; then
      notes="$(find "$ROOT/harness/handoffs" -maxdepth 1 -type f -name "*.md" ! -name ".live-*" -newer "$marker" 2>/dev/null | wc -l | tr -d ' ')" || notes=0
    fi
    case "$notes" in ''|*[!0-9]*) notes=0;; esac
    age_min=$((CONSOLIDATION_HOURS * 60))
    if [ "$notes" -ge "$CONSOLIDATION_NOTES" ] 2>/dev/null && \
       [ -n "$(find "$marker" -mmin +"$age_min" 2>/dev/null)" ]; then
      date_line="$(tail -n 1 "$marker" 2>/dev/null)"
      case "$date_line" in "") date_line="the last pass";; esac
      say_due "$notes handoffs since $date_line"
      return 0
    fi
  fi
  traps_n="$(printf '%s' "${1:-}" | sed -n 's/^known traps (\([0-9][0-9]*\)).*/\1/p')" || traps_n=""
  case "$traps_n" in ''|*[!0-9]*) traps_n=0;; esac
  if [ "$traps_n" -gt "$CONSOLIDATION_MAX_TRAPS" ] 2>/dev/null; then
    say_due "$traps_n known traps over budget $CONSOLIDATION_MAX_TRAPS"
    return 0
  fi
  lesson_hit=""; finding_hit=""
  if [ -f "$ROOT/harness/learning.jsonl" ] && command -v python3 >/dev/null 2>&1; then
    marker_text=""
    if [ -f "$marker" ] && [ -s "$marker" ]; then
      marker_text="$(tail -n 1 "$marker" 2>/dev/null)" || marker_text=""
    fi
    hits="$(python3 - "$ROOT/harness/learning.jsonl" "$CONSOLIDATION_LESSONS" "$CONSOLIDATION_FINDINGS" "${marker_text:-}" 2>/dev/null <<'PYEOF'
import datetime, json, sys
path, lesson_n, finding_n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
marker_text = sys.argv[4] if len(sys.argv) > 4 else ""
def parse_utc(s):
    try:
        return datetime.datetime.strptime(s.strip(), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()
    except (ValueError, AttributeError, TypeError, OverflowError):
        return None
since = parse_utc(marker_text) if marker_text.strip() else None
lessons, findings = {}, {}
try:
    for line in open(path, errors="replace"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if not isinstance(e, dict):
            continue
        ts = e.get("ts")
        row_epoch = parse_utc(ts) if isinstance(ts, str) and ts.strip() else None
        if since is not None and not (row_epoch is not None and row_epoch >= since):
            continue
        if e.get("kind") == "lesson" and isinstance(e.get("target"), str) and e.get("target"):
            lessons[e["target"]] = lessons.get(e["target"], 0) + 1
        elif e.get("kind") == "finding" and isinstance(e.get("category"), str) and e.get("category"):
            findings[e["category"]] = findings.get(e["category"], 0) + 1
except OSError:
    pass
for target, n in lessons.items():
    if n >= lesson_n:
        print("lesson:%s" % target)
        break
for cat, n in findings.items():
    if n >= finding_n:
        print("finding:%s" % cat)
        break
PYEOF
)" || hits=""
    lesson_hit="$(printf '%s' "$hits" | sed -n 's/^lesson://p' | head -1)" || lesson_hit=""
    finding_hit="$(printf '%s' "$hits" | sed -n 's/^finding://p' | head -1)" || finding_hit=""
  fi
  if [ -n "$lesson_hit" ]; then
    say_due "$CONSOLIDATION_LESSONS lessons on $lesson_hit"
    return 0
  fi
  if [ -n "$finding_hit" ]; then
    say_due "$CONSOLIDATION_FINDINGS findings in $finding_hit"
    return 0
  fi
  return 0
}

brief() {
  command -v bd >/dev/null 2>&1 || return 0
  command -v python3 >/dev/null 2>&1 || return 0
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

  python3 - "$READY_SHOWN" "$ROOT" "$ready_json" "$HARNESS" <<'PY'
import json, os, re, socket, subprocess, sys, glob, datetime

shown = int(sys.argv[1])
root = sys.argv[2]
# The shared checkout, for sibling scripts the project does not shadow.
harness = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else root

sys.path.insert(0, os.path.join(harness, "scripts"))
sys.path.insert(0, os.path.join(root, "scripts"))
from harness_paths import resolve
_, _, harness_script = resolve(root, harness)
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
# Counts come from one full `bd list`, not `bd stats --json`: stats (like `bd
# config` and `bd info`) auto-imports a stale .beads/issues.jsonl when the
# ledger looks stale to it, resurrecting deleted beads — and the brief runs
# inside the gate, before the ledger-export check that exists to catch that
# drift (har-67c). `bd list` never imports. Each bd call spins up an embedded
# Dolt engine (~half a second), so the one query's rows are counted locally
# and lists are only fetched when the titles get printed.
counts = {}
# --limit 0, because bd's default is 50 and silently losing beads past that
# would look like work disappearing rather than a truncated query.
all_issues = bd("list", "--json", "--all", "--limit", "0")
if isinstance(all_issues, list):
    for issue in all_issues:
        if isinstance(issue, dict):
            key = "%s_issues" % (issue.get("status") or "open")
            counts[key] = counts.get(key, 0) + 1
# The map carries bd's own bookkeeping alongside the memories — schema_version is
# an int in there — so keep only the entries whose value is actual prose.
memories = bd("memories", "--json")
memories = ({k: v for k, v in memories.items() if isinstance(v, str)}
            if isinstance(memories, dict) else {})

# Backlog and needs-human travel down the parent chain (the same inheritance
# scripts/dashboard.py derives with), but `bd ready` only ever checked own
# labels — so a child of shelved work is listed ready here until filtered.
# Parents come from the one `bd list` payload already fetched above: the
# parent column, plus parent-child edges, which is where an epic link lives
# when the column is empty.
def _parent_ids(i):
    out = set()
    if not isinstance(i, dict):
        return out
    if i.get("parent"):
        out.add(i["parent"])
    for d in i.get("dependencies") or []:
        if isinstance(d, dict) and d.get("type") == "parent-child":
            t = d.get("depends_on_id") or d.get("id")
            if t:
                out.add(t)
    return out

def _grow_down(parents, seeds):
    shelved = set(seeds)
    grown = True
    while grown:
        grown = False
        for bead, bead_parents in parents.items():
            if bead not in shelved and bead_parents & shelved:
                shelved.add(bead)
                grown = True
    return shelved
by_id = {i["id"]: i for i in all_issues
         if isinstance(i, dict) and i.get("id")}
parents = {bid: _parent_ids(i) for bid, i in by_id.items()}
shelved = _grow_down(parents, {bid for bid, i in by_id.items()
                                 if {"backlog", "needs-human"} & set(i.get("labels") or [])})
ready = [i for i in ready
         if isinstance(i, dict) and i.get("id") not in shelved]

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
    # The same rule the shell seat_name() above parses by: wrapping
    # asterisks and whitespace stripped together, so a tab-indented or
    # star-wrapped value reads the same in both.
    for l in text.splitlines():
        s = l.lstrip()
        if s.startswith("**%s:**" % key):
            return s.split(":", 1)[1].strip(" \t\r\n\f\v*")
    return ""

def seat():
    text = seat_text()
    if not text:
        return None
    # Blank, missing, or unparseable Name is preflight's line, not this one:
    # the shell above reports it with the fix even when bd or python3 is
    # missing and this summary never runs — so this stays silent on those to
    # keep the diagnosis to one line.
    if not any(l.lstrip().startswith("**Name:**") for l in text.splitlines()):
        return None
    name = field(text, "Name").split("—")[0].strip()
    if not name:
        return None
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
    out = run("bash", harness_script("ledger-push.sh"),
              "--check")
    return out.strip() or None

# --- the one board ------------------------------------------------------
# There is exactly one dashboard, run from the harness-starter checkout. A
# project running by reference (HARNESS outside ROOT) names its URL here when
# that board is live, so a session working in the project can still find it.
# Copy installs and the starter itself stay silent: harness == root there.
# Liveness is read off the board's /tmp claim file (see dashboard.py
# claim_file: the port rides in the filename, the root and pid in the JSON),
# never by importing dashboard.py. Nothing here may raise: an uncaught
# exception prints no brief at all.
def board_line():
    try:
        if harness == root or harness.startswith(root + os.sep):
            return None
        checkout = os.path.dirname(harness)
        # Bounded: each stale claim costs up to the 0.5s probe below, and /tmp
        # accumulates them. The cap applies to THIS checkout's claims only —
        # other checkouts' files are cheap to skip and must not crowd it out.
        mine = []
        for path in sorted(glob.glob("/tmp/*-dashboard-*.json")):
            try:
                c = json.load(open(path))
            except (OSError, ValueError):
                continue
            if isinstance(c, dict) and c.get("root") == checkout:
                mine.append(path)
        for path in mine[:20]:
            try:
                port = int(path.rsplit("-", 1)[1].rsplit(".", 1)[0])
            except ValueError:
                continue
            try:
                claim = json.load(open(path))
            except (OSError, ValueError):
                continue
            if not isinstance(claim, dict) or claim.get("root") != checkout:
                continue
            pid = claim.get("pid")
            if isinstance(pid, int):
                try:
                    os.kill(pid, 0)
                except OSError:
                    continue
            try:
                probe = socket.create_connection(("127.0.0.1", port), timeout=0.5)
                probe.close()
            except OSError:
                continue
            return f"board: http://localhost:{port}/ (starter board live)"
    except (OSError, ValueError, socket.error):
        pass
    return None

out = [s for s in (seat(), identity(), laurel(), handoff()) if s]
out.append(f"ledger: {counts.get('open_issues', 0)} open, "
           f"{len(ready)} ready, {len(active)} in progress")
push = ledger_push()
if push:
    out.extend(push.splitlines())
found = board_line()
if found:
    out.append(found)
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

text="$( { preflight; brief; } || true)"
# One --prepend/--append file grafted onto the brief text: before it for the
# contract, after it for the skill note. A named file that is missing warns on
# stderr and is skipped — `h session` builds these paths from another
# checkout's layout, and silence there would read as a step that never ran.
graft() {
  local side="$1"
  local file="$2"
  local part
  if [ ! -f "$file" ]; then
    printf 'brief.sh: %s not found — skipped\n' "$file" >&2
    return 0
  fi
  if ! part="$(cat "$file" 2>/dev/null)"; then
    # Unreadable (or vanished in the TOCTOU window) like missing, but loud:
    # a failing cat under set -e would kill the hook with no JSON at all.
    printf 'brief.sh: %s unreadable — skipped\n' "$file" >&2
    return 0
  fi
  if [ -z "$text" ]; then
    text="$part"
  elif [ "$side" = "before" ]; then
    text="$part
$text"
  else
    text="$text
$part"
  fi
}
# The contract goes first, the skill note last; either file missing means
# that half is skipped rather than the whole brief failing.
if [ -n "$prepend" ]; then graft before "$prepend"; fi
if [ -n "$append" ]; then graft after "$append"; fi
# Another session's unclosed journal, in at most one line: the check lives in
# the journal lib so probes exercise the same path the brief prints. Silent
# is the common case, which is what keeps the brief in budget.
orphan_line="$(journal_orphan)"
if [ -n "$orphan_line" ]; then
  text="$text
$orphan_line"
fi
# At most one consolidation-due line, appended after the orphan line so the
# brief stays in budget: silence is the common case, one line the most.
due_line="$(consolidation_due "$text")"
if [ -n "$due_line" ]; then
  text="$text
$due_line"
fi
[ -z "$text" ] && exit 0

if [ "$hook" -eq 1 ]; then
  # python3 builds the wrapper; without it the hook fails loud rather than
  # emitting half-escaped JSON. The sed fallback this replaced covered only
  # backslash, quote and newline, so a tab or carriage return in the brief —
  # a seat paragraph, a CRLF-edited file — printed invalid JSON, which reads
  # as a hook that never ran. Silence is what this script exists to replace.
  if command -v python3 >/dev/null 2>&1 && python3 -c '
import json, sys
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": sys.stdin.read().strip(),
}}))' <<< "$text"; then
    :
  else
    echo "brief.sh: python3 is needed for --hook JSON output" >&2
    exit 1
  fi
else
  echo "$text"
fi
