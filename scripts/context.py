#!/usr/bin/env python3
"""Guards the knowledge layer: is it still true, and is it still small.

    scripts/context.py            # report both
    scripts/context.py check      # exit 1 if a doc is stale or the budget is blown
    scripts/context.py bless      # re-record hashes after updating a doc
    scripts/context.py digest     # everything the librarian pass needs to read

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

DOCS = [ROOT / "CLAUDE.md", ROOT / ".claude/HARNESS.md",
        *sorted((ROOT / ".claude/skills").glob("*/SKILL.md"))]

# The memory index loads every session too, but it lives outside the repo, under
# a directory named for this checkout's path. Absent on another machine, which
# is why it's counted only when it's there rather than assumed.
MEMORY_INDEX = (Path.home() / ".claude/projects"
                / str(ROOT).replace("/", "-") / "memory/MEMORY.md")


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


def budget():
    brief = subprocess.run(["bash", str(ROOT / "scripts/brief.sh")],
                           capture_output=True, text=True).stdout
    parts = [("CLAUDE.md", tokens((ROOT / "CLAUDE.md").read_text())),
             ("session brief", tokens(brief))]
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

    packet = Path("/tmp/har-knowledge-digest.md")
    packet.write_text("\n".join(out) + "\n")
    print(packet)


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

    for doc in unblessed:
        print(f"  new   {doc.relative_to(ROOT)} — run 'scripts/context.py bless'")

    # Reported, never enforced. A threshold here only ever measured how long it
    # had been since someone argued with the layer, and the librarian does that
    # better — so this is a trend line for it to read, not a gate to pass.
    print(f"  cost  {total} tokens every session"
          + " (" + ", ".join(f"{name} {n}" for name, n in parts) + ")")
    if not stale:
        print(f"  ok    {len(DOCS)} docs match the sources they describe")

    return 1 if (failed and strict) else 0


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "report"
    if command == "bless":
        bless()
    elif command == "digest":
        digest()
    else:
        sys.exit(report(strict=(command == "check")))
