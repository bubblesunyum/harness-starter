#!/usr/bin/env python3
"""Guards the knowledge layer: is it still true, and is it still small.

    scripts/context.py            # report both
    scripts/context.py check      # exit 1 if a doc is stale or the budget is blown
    scripts/context.py bless      # re-record hashes after updating a doc
    scripts/context.py digest     # everything the librarian pass needs to read
    scripts/context.py spend      # what recent sessions actually cost, per session

Two failures this catches, both of which shipped before it existed:

A doc goes stale because something *else* changed — the skill describing
verify.sh stops being true when verify.sh grows a step, and the stale file never
appears in the diff, so no diff-scoped review can see it. A doc declares what it
describes with a `tracks:` comment, and the hashes live in .claude/context.lock.

And the always-loaded context only ever grows. Nothing argued against a longer
CLAUDE.md at the moment it was being written, which is the only moment the
argument is cheap.
"""

import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / ".claude/context.lock"

DOCS = [ROOT / "CLAUDE.md", ROOT / "AGENTS.md", ROOT / ".claude/HARNESS.md",
        *sorted((ROOT / ".claude/skills").glob("*/SKILL.md"))]

# The memory index loads every session too, but it lives outside the repo, under
# a directory named for this checkout's path. Absent on another machine, which
# is why it's counted only when it's there rather than assumed.
MEMORY_INDEX = (Path.home() / ".claude/projects"
                / str(ROOT).replace("/", "-") / "memory/MEMORY.md")

# Claude Code's own session transcripts, beside that memory directory. They
# record what each turn actually cost, which is the only place the *whole*
# session floor is visible: the docs below are a measurable 4k, and a real
# session opens at ~54k. The other 50k is Claude Code's system prompt, its tool
# schemas and whatever MCP connectors the app has enabled — none of it in this
# repo, none of it countable by reading files, and all of it re-sent every turn.
TRANSCRIPTS = MEMORY_INDEX.parent.parent


# Every settings file whose SessionStart hooks fire in a session here — Claude
# Code merges all three. `bd setup claude --global` writes to the first, so a
# check that read only the project file would vouch for a clean session while
# the hook ran from the user's home directory.
SETTINGS = [Path.home() / ".claude/settings.json",
            ROOT / ".claude/settings.json",
            ROOT / ".claude/settings.local.json"]

# What the harness installs. Anything else there is always-loaded context nobody
# is counting — and generators put it there: `bd setup claude` writes a
# `bd prime` hook (~1900 tokens) beside the brief that exists to replace it,
# every time it runs. Matched by name rather than executed; a checker that ran
# whatever it found configured would be a worse idea than the drift it catches.
OWN_HOOKS = ("scripts/brief.sh", "scripts/dashboard.py")


def foreign_hooks():
    """(settings file, command) for every SessionStart hook the harness didn't
    install. A file that won't parse is reported rather than skipped: this check
    exists to fail loud, and failing open on a broken settings file is the one
    outcome it can't afford."""
    found = []
    for path in SETTINGS:
        if not path.exists():
            continue
        try:
            settings = json.loads(path.read_text())
        except (OSError, ValueError) as broken:
            found.append((path, f"unreadable: {broken}"))
            continue
        for entry in settings.get("hooks", {}).get("SessionStart", []):
            for hook in entry.get("hooks", []):
                command = hook.get("command", "").strip()
                if not any(own in command for own in OWN_HOOKS):
                    found.append((path, command or "(entry with no command)"))
    return found


def stray_beads_blocks():
    """bd writes its managed guidance into every agent-instructions file it
    finds, so a plain install ends up with the same text three times. One copy
    survives, in AGENTS.md, because that is the file every agent reads."""
    strays = []
    for doc in (ROOT / "CLAUDE.md", ROOT / "AGENTS.md"):
        if not doc.exists():
            continue
        blocks = doc.read_text().count("<!-- BEGIN BEADS")
        allowed = 1 if doc.name == "AGENTS.md" else 0
        if blocks > allowed:
            strays.append((doc, blocks))
    return strays


def where(path):
    """Settings files live both inside the checkout and in the user's home."""
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path).replace(str(Path.home()), "~", 1)


def tokens(text):
    return round(len(text) / 4)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()[:16] if path.exists() else ""


def tracked_by(doc):
    """The sources a doc claims to describe, declared inside the doc itself so
    the mapping can't drift away from the thing it maps."""
    m = re.search(r"<!--\s*tracks:(.*?)-->", doc.read_text(), re.S)
    return [ROOT / p for p in m.group(1).split()] if m else []


def load_lock():
    try:
        return json.loads(LOCK.read_text())
    except Exception:
        return {}


def staleness():
    """Docs whose sources moved without them. A doc is only checked once it has
    been blessed — a new doc isn't stale, it's just new."""
    lock, stale, unblessed = load_lock(), [], []
    for doc in DOCS:
        sources = tracked_by(doc)
        if not sources:
            continue
        recorded = lock.get(str(doc.relative_to(ROOT)))
        if recorded is None:
            unblessed.append(doc)
            continue
        moved = [s for s in sources
                 if recorded.get(str(s.relative_to(ROOT))) not in (sha(s), None)]
        if moved and recorded.get("doc") == sha(doc):
            stale.append((doc, moved))
    return stale, unblessed


def turn_costs(transcript):
    """Every turn's full input size, in order. A resumed session replays its
    history with no usage recorded, so zero-cost turns are dropped rather than
    counted as a free session floor."""
    costs = []
    for line in transcript.read_text(errors="replace").splitlines():
        try:
            usage = (json.loads(line).get("message") or {}).get("usage")
        except ValueError:
            continue
        if usage:
            total = (usage.get("input_tokens", 0)
                     + usage.get("cache_creation_input_tokens", 0)
                     + usage.get("cache_read_input_tokens", 0))
            if total:
                costs.append(total)
    return costs


def sessions(limit=12):
    """Recent transcripts, newest last. Bounded because the floor drifts with
    Claude Code releases and connector changes, and a year-old session says
    nothing about what the next one will cost."""
    if not TRANSCRIPTS.is_dir():
        return []
    found = sorted(TRANSCRIPTS.glob("*.jsonl"), key=lambda p: p.stat().st_mtime)
    return [(p, turn_costs(p)) for p in found[-limit:]]


def floor():
    """The median opening context across recent sessions: what a session pays
    before it has done anything. Median rather than mean because one resumed or
    aborted session shouldn't move the number the budget is read against."""
    opens = sorted(c[0] for _, c in sessions() if c)
    return (opens[len(opens) // 2], len(opens)) if opens else (0, 0)


def budget():
    brief = subprocess.run(["bash", str(ROOT / "scripts/brief.sh")],
                           capture_output=True, text=True).stdout
    # Both instruction files, because both are always-loaded — CLAUDE.md by
    # Claude Code and AGENTS.md by opencode, and CLAUDE.md imports AGENTS.md so
    # Claude Code pays for both too. Counting only CLAUDE.md would let a session
    # move text into AGENTS.md and watch the number fall while nothing changed.
    parts = [(doc.name, tokens(doc.read_text()))
             for doc in (ROOT / "CLAUDE.md", ROOT / "AGENTS.md") if doc.exists()]
    parts.append(("session brief", tokens(brief)))
    if MEMORY_INDEX.exists():
        parts.append(("MEMORY.md", tokens(MEMORY_INDEX.read_text())))
    descriptions = 0
    for skill in sorted((ROOT / ".claude/skills").glob("*/SKILL.md")):
        found = re.search(r"^description:\s*(.*)$", skill.read_text(), re.M)
        descriptions += tokens(found.group(1)) if found else 0
    parts.append(("skill descriptions", descriptions))
    return parts, sum(n for _, n in parts)


def bless():
    lock = load_lock()
    for doc in DOCS:
        sources = tracked_by(doc)
        if not sources:
            continue
        lock[str(doc.relative_to(ROOT))] = {
            "doc": sha(doc),
            **{str(s.relative_to(ROOT)): sha(s) for s in sources},
        }
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    LOCK.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")
    print(f"blessed {len(lock)} docs → {LOCK.relative_to(ROOT)}")


def _bd_prefix():
    """The ledger's bead prefix, asked of the ledger itself at runtime — it used
    to be baked into this file at install time, which made every copy differ."""
    try:
        r = subprocess.run(["bd", "config", "get", "issue_prefix"],
                           capture_output=True, text=True, timeout=10, cwd=ROOT)
        got = (r.stdout or "").strip()
        if r.returncode == 0 and re.fullmatch(r"[a-z0-9]{1,10}", got):
            return got
    except Exception:
        pass
    short = re.sub(r"[^a-z0-9]", "", ROOT.name.lower()).lstrip("0123456789")[:3]
    return short or "bd"


def digest():
    """Everything the librarian reads, in one place, so it doesn't spend its
    context rediscovering the shape of the knowledge layer."""
    out = ["# Knowledge digest\n"]
    parts, total = budget()
    out.append(f"## Always loaded: {total} tokens\n")
    out += [f"- {name}: {n}" for name, n in parts]

    out.append("\n## Skills\n")
    for skill in sorted((ROOT / ".claude/skills").glob("*/SKILL.md")):
        text = skill.read_text()
        found = re.search(r"^description:\s*(.*)$", text, re.M)
        out.append(f"\n### {skill.parent.name} ({tokens(text)} tokens loaded)")
        out.append(f"_{found.group(1) if found else ''}_\n")
        out.append(text.split("---", 2)[-1].strip())

    memories = subprocess.run(["bd", "memories", "--json"],
                              capture_output=True, text=True, cwd=ROOT).stdout
    try:
        entries = {k: v for k, v in json.loads(memories).items() if isinstance(v, str)}
    except Exception:
        entries = {}
    out.append(f"\n## Memories ({len(entries)})\n")
    out += [f"\n### {k}\n{v}" for k, v in sorted(entries.items())]

    packet = Path(f"/tmp/{_bd_prefix()}-knowledge-digest.md")
    packet.write_text("\n".join(out) + "\n")
    print(packet)


def spend():
    """Where a session's tokens went. The floor is fixed and the conversation
    is not, so the two numbers argue for different fixes: a smaller floor, or a
    shorter session. Printed per session because the shape only shows up there
    — the same harness produces a 60k session and a 300k one."""
    print(f"{'session':12}{'turns':>7}{'open':>10}{'peak':>10}{'total in':>12}"
          f"{'floor share':>13}")
    for path, costs in sessions(limit=20):
        if not costs:
            continue
        total = sum(costs)
        print(f"{path.stem[:8]:12}{len(costs):>7}{costs[0]:>10,}{max(costs):>10,}"
              f"{total:>12,}{100 * costs[0] * len(costs) / total:>12.0f}%")
    print("\n  floor share is what the opening context alone costs across the"
          "\n  session — spend above it is conversation, and the fix for each"
          "\n  is different. See .claude/HARNESS.md.")


def report(strict):
    stale, unblessed = staleness()
    parts, total = budget()
    failed = False

    for doc, moved in stale:
        failed = True
        names = ", ".join(str(s.relative_to(ROOT)) for s in moved)
        print(f"  STALE {doc.relative_to(ROOT)}")
        print(f"        {names} changed; the doc did not")
    for path, command in foreign_hooks():
        failed = True
        print(f"  HOOK  unaccounted SessionStart hook: {command}")
        print(f"        in {where(path)} — its hooks run in every session here")
        print("        and the cost line below can't see them; see .claude/HARNESS.md")

    for doc, blocks in stray_beads_blocks():
        failed = True
        print(f"  BEADS {doc.relative_to(ROOT)} carries {blocks} bd managed block(s)")
        print("        one copy, in AGENTS.md — see .claude/HARNESS.md")

    # Informational, never a failure: the gate runs before the ledger is pushed
    # by design (verify, commit, then push), so an ahead ledger here is the
    # normal state rather than a broken one. What it must not be is silent.
    try:
        push = subprocess.run(["bash", str(ROOT / "scripts/ledger-push.sh"),
                               "--check"],
                              capture_output=True, text=True,
                              timeout=30).stdout.strip()
    except Exception:
        push = ""
    for line in push.splitlines():
        print(f"  {line}")

    for doc in unblessed:
        print(f"  new   {doc.relative_to(ROOT)} — run 'scripts/context.py bless'")

    # Reported, never enforced. A threshold here only ever measured how long it
    # had been since someone argued with the layer, and the librarian does that
    # better — so this is a trend line for it to read, not a gate to pass.
    print(f"  cost  {total} tokens every session"
          + " (" + ", ".join(f"{name} {n}" for name, n in parts) + ")")
    measured, seen = floor()
    if measured:
        print(f"  floor {measured:,} tokens before a session does anything"
              f" — {total} of it this repo, {measured - total:,} Claude Code's own")
        print(f"        (median of {seen} recent sessions; re-sent every turn,"
              " so it sets the slope of the whole session)")
    if not stale:
        print(f"  ok    {len(DOCS)} docs match the sources they describe")

    return 1 if (failed and strict) else 0


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "report"
    if command == "bless":
        bless()
    elif command == "digest":
        digest()
    elif command == "spend":
        spend()
    else:
        sys.exit(report(strict=(command == "check")))
