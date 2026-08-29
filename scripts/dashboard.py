#!/usr/bin/env python3
"""The harness dashboard: what the development system is doing, as a live picture.

    scripts/dashboard.py            # serve at localhost:7391 (or the next free port)
    scripts/dashboard.py up         # serve only if nothing is (what the Stop hook runs)
    scripts/dashboard.py snapshot   # just write dashboard/state.json
    scripts/dashboard.py shot [png] # photograph it, for the design review pass
    scripts/dashboard.py --port N   # serve somewhere else

State is rebuilt from bd and git behind a few seconds of cache, so the page is
live — claim a bead in one terminal and the diagram moves — without the polling
outrunning the generation. The snapshot form exists for the Stop hook, which
leaves a readable file behind even when nothing is serving.
"""

import http.server
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

ROOT = Path(__file__).resolve().parent.parent
# The first checkout to start gets 7391; a second one running this same harness
# steps to the next free port rather than colliding. See free_port().
PORT = 7391

# Rough but honest: ~4 characters per token is close enough to compare a 200-line
# always-loaded file against a 6000-character session hook, which is the only
# question this number is asked to answer.
def tokens(text):
    return round(len(text) / 4)


def run(*args, **kw):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=25, cwd=ROOT, **kw)
        return r.stdout.strip()
    except Exception:
        return ""


def run_unstripped(*args, **kw):
    """Like `run`, but for output whose first character is meaningful — porcelain
    status uses a leading space to mean "empty column", and `.strip()` eats it,
    shifting every field after it by one."""
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=25, cwd=ROOT, **kw)
        return r.stdout
    except Exception:
        return ""


def bd_json(*args):
    out = run("bd", *args, "--json")
    try:
        return json.loads(out) if out else []
    except json.JSONDecodeError:
        return []


def git_state():
    dirty = [l for l in run("git", "status", "--porcelain").splitlines() if l.strip()]
    log = run("git", "log", "-1", "--format=%h\x1f%s\x1f%cr")
    sha, subject, when = (log.split("\x1f") + ["", "", ""])[:3]
    since = time.strftime("%Y-%m-%dT00:00:00")
    today = run("git", "log", "--since", since, "--oneline")

    # Landed locally but not shared yet. A bead named in one of these commits is
    # done in the working copy and invisible to anywhere else, which is its own
    # state worth seeing.
    upstream = run("git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
    unpushed, mentioned = [], {}
    if upstream:
        raw = run("git", "log", f"{upstream}..HEAD", "--format=%h\x1f%s\x1f%b\x1f%ct\x1e")
        for entry in [e for e in raw.split("\x1e") if e.strip()]:
            parts = entry.strip().split("\x1f")
            unpushed.append({"sha": parts[0], "subject": parts[1] if len(parts) > 1 else "",
                             "at": float(parts[3]) if len(parts) > 3 and parts[3] else 0})
            # A bead can be spread over several commits; the lane shows the
            # bead once and says how many carry it.
            for bead in set(re.findall(r"\bhar-[a-z0-9]+(?:\.\d+)?\b", entry)):
                seen = mentioned.setdefault(bead, {"commits": 0, "at": 0, "list": []})
                seen["commits"] += 1
                seen["at"] = max(seen["at"], unpushed[-1]["at"])
                seen["list"].append({"sha": unpushed[-1]["sha"],
                                     "subject": unpushed[-1]["subject"]})

    return {
        "branch": run("git", "rev-parse", "--abbrev-ref", "HEAD"),
        "upstream": upstream,
        "dirty": len(dirty),
        "commits_today": len([l for l in today.splitlines() if l.strip()]),
        "last": {"sha": sha, "subject": subject, "when": when},
        "unpushed": unpushed,
        "unpushed_beads": sorted(mentioned),
        # Per bead: how many unpushed commits carry it, and when the most
        # recent one landed, so the board can say whether the gate has run since.
        "bead_commits": mentioned,
    }


def worktree_state():
    """Every path git status has an opinion about, one row each — a file with
    both a staged and an unstaged edit is still one row, staged winning, since
    that's the version a commit right now would actually take. `-z` sides steps
    quoting: paths never need unescaping, and a rename's line carries its old
    path as a second NUL-terminated field, kept here since undoing a rename
    means restoring THAT path, not the new one."""
    out = run_unstripped("git", "status", "--porcelain=v1", "-z")
    if not out:
        return []
    parts = out.split("\x00")
    entries = []
    i = 0
    while i < len(parts):
        entry = parts[i]
        i += 1
        if not entry:
            continue
        xy, path = entry[:2], entry[3:]
        old_path = None
        if xy[0] in ("R", "C"):
            old_path = parts[i]
            i += 1
        untracked = xy == "??"
        staged = xy[0] not in (" ", "?")
        entries.append({
            "path": path,
            "staged": staged,
            "untracked": untracked,
            "status": xy[0] if staged else xy[1],
            "old_path": old_path,
        })
    # Staged first, then unstaged — within each, alphabetical.
    entries.sort(key=lambda e: (0 if e["staged"] else 1, e["path"]))
    return entries


def worktree_paths():
    return {e["path"] for e in worktree_state()}


def is_probably_text(path):
    try:
        with open(ROOT / path, "rb") as f:
            return b"\x00" not in f.read(8000)
    except OSError:
        return False


def diff_new_file(path):
    # -a, but only for files that pass their own NUL-byte sniff: git's binary
    # check on a /dev/null comparison has nothing on the "old" side to sniff
    # and misfires, calling every untracked file binary. A file that's
    # actually binary keeps getting reported as one.
    args = ["git", "diff", "--no-color", "--no-index"]
    if is_probably_text(path):
        args.append("-a")
    return run(*args, "--", "/dev/null", path)


def untracked_diff(path):
    """The diff for a path git status calls untracked. Usually one file, diffed
    whole against nothing — but git collapses an entirely-new directory that
    has no tracked sibling into a single `?? dir/` row, and diffing a directory
    against /dev/null just errors, so that case is unrolled into one diff per
    file inside instead (skipping anything .gitignore already excludes)."""
    if not (ROOT / path).is_dir():
        return diff_new_file(path)
    listed = run("git", "ls-files", "--others", "--exclude-standard", "-z", "--", path)
    return "\n".join(diff_new_file(p) for p in listed.split("\x00") if p)


def diff_for(path):
    """The unified diff for one row, exactly as its checkbox would commit it:
    the staged version if it has one, otherwise the working-tree edit, otherwise
    (untracked) the whole file diffed against nothing."""
    entries = {e["path"]: e for e in worktree_state()}
    e = entries.get(path)
    if not e:
        return None
    if e["untracked"]:
        text = untracked_diff(path)
    elif e["staged"]:
        text = run("git", "diff", "--cached", "--no-color", "--", path)
    else:
        text = run("git", "diff", "--no-color", "--", path)
    return {"path": path, "staged": e["staged"], "diff": text}


def revert_file(path):
    """Put one row back to HEAD, in the index and the working tree both — the
    row doesn't distinguish staged from unstaged damage, so undoing it doesn't
    either. A file that only exists because it's new has no HEAD to restore to,
    so it's unstaged and then removed rather than "restored". A rename is the
    same case twice over: the new name has no HEAD to restore to either, and
    HEAD's content lives under the old name this row's own path doesn't name."""
    entries = {e["path"]: e for e in worktree_state()}
    e = entries.get(path)
    if not e:
        return False
    if e["untracked"]:
        run("git", "clean", "-f", "--", path)
    elif e["old_path"]:
        run("git", "restore", "--staged", "--worktree", "--source=HEAD", "--", e["old_path"])
        run("git", "restore", "--staged", "--", path)
        run("git", "clean", "-f", "--", path)
    elif e["status"] == "A":
        run("git", "restore", "--staged", "--", path)
        run("git", "clean", "-f", "--", path)
    else:
        run("git", "restore", "--staged", "--worktree", "--source=HEAD", "--", path)
    return True


def ledger_state():
    # Neither is claimable: backlog is work deliberately not being done next,
    # and a needs-human bead is one a session already declined to guess at.
    # Both stay out of ready for the same reason they stay out of the brief.
    ready = bd_json("ready", "--exclude-label", "backlog",
                    "--exclude-label", "needs-human")
    ready_ids = {i["id"] for i in ready}
    issues = []
    counts = {"open": 0, "ready": len(ready), "in_progress": 0, "closed": 0, "blocked": 0}

    def blockers(issue, parent):
        """The ids this issue waits on. Belonging to an epic is not being blocked
        by it — the parent arrives in `dependencies` alongside real blockers, and
        drawn as one kind of edge it turns the graph into a hairball where every
        child looks stuck."""
        out = []
        for d in issue.get("dependencies") or []:
            got = d.get("depends_on_id") or d.get("id") or "" if isinstance(d, dict) else d
            if got and got != parent:
                out.append(got)
        return out

    # One call, not four. `bd list --all` returns closed alongside everything
    # else and carries labels, description, design and notes inline — which is
    # also what retired the separate `--label review` query. Each bd invocation
    # spins up an embedded Dolt engine, and that cost is what once made the
    # server fall behind its own polling.
    # --limit 0, because bd's default is 50 and the board silently losing beads
    # past that would look like work disappearing rather than a truncated query.
    for i in bd_json("list", "--all", "--limit", "0"):
        status = i.get("status", "open")
        counts[status] = counts.get(status, 0) + 1
        parent = i.get("parent") or ""
        labels = i.get("labels") or []
        issues.append({
            "id": i["id"],
            "title": i["title"],
            "status": status,
            "ready": i["id"] in ready_ids,
            # Being under review is a stage work passes through, and beads carry
            # it as a label — `bd label add <id> review` puts a card in that
            # lane, removing it takes it out. Nothing else in bd models a
            # review, and inventing a status would mean teaching every other
            # command about it.
            "in_review": "review" in labels,
            "backlog": "backlog" in labels,
            "labels": labels,
            "priority": i.get("priority", 2),
            "type": i.get("issue_type", "task"),
            "parent": parent,
            "updated_at": i.get("updated_at", ""),
            "created_at": i.get("created_at", ""),
            "deps": blockers(i, parent),
            # The detail pane reads these; capped because the page re-fetches
            # the whole state every few seconds and a long design note would be
            # paid for on every poll.
            "description": (i.get("description") or "")[:1200],
            "design": (i.get("design") or "")[:1200],
            "notes": (i.get("notes") or "")[:1200],
            "close_reason": (i.get("close_reason") or "")[:600],
            "owner": i.get("owner") or "",
        })
    # A bead with children stands for them on the board: six cards that are all
    # one piece of work read as six pieces of work. The children travel with the
    # parent instead, and the detail pane is where they're legible.
    by_id = {i["id"]: i for i in issues}
    for i in issues:
        i["children"] = []
    for i in issues:
        parent = by_id.get(i["parent"])
        if parent:
            parent["children"].append(i["id"])

    # Yegge's Beadle watches for work that's simply stuck or dropped. With one
    # person there's no agent to nudge, so the number just has to be visible.
    stale = len(bd_json("stale", "--days", "14"))
    return {"counts": counts, "issues": issues, "stale": stale}


# ── FILL THIS IN ──────────────────────────────────────────────────────────
# Your build tool's success/failure line, if it prints one — e.g. xcodebuild's
# "** BUILD SUCCEEDED **" wants r"\*\* (?:BUILD|TEST) (SUCCEEDED|FAILED) \*\*".
# Leave it as r"(?!)" — a pattern that matches nothing — if yours prints no
# verdict; the error-line fallback below is what runs then.
# ──────────────────────────────────────────────────────────────────────────
VERDICT = r"(?!)"


def verify_state():
    """Read the last gate run off its logs rather than running it — the dashboard
    reports on the system, it doesn't drive it."""
    logs = Path("/tmp/har-verify")
    if not logs.is_dir():
        return {"status": "never run", "when": "", "tests": "", "steps": [],
                "unverified": 0, "took": "", "at": 0}

    steps, newest = [], 0
    for log in sorted(logs.glob("*.log")):
        text = log.read_text(errors="ignore")
        # A build tool's own verdict wins where it prints one. Counting
        # "error:" lines does not work on its own: a passing test run logs
        # dozens from the app's output, and reading those as failures marks a
        # green suite red. Add your toolchain's verdict line to VERDICT.
        verdict = re.findall(VERDICT, text)
        if verdict:
            ok = verdict[-1].upper() in ("SUCCEEDED", "PASSED", "OK")
        else:
            ok = bool(text.strip()) and not re.search(r"\berror:", text)
        steps.append({"name": log.stem.replace("-", " "), "ok": ok})
        newest = max(newest, log.stat().st_mtime)

    tests = ""
    unit = logs / "unit-tests.log"
    if unit.exists():
        m = re.findall(r"Executed (\d+) tests?, with (\d+) failures?", unit.read_text(errors="ignore"))
        if m:
            tests = f"{m[-1][0]} tests, {m[-1][1]} failing"

    status = "passed" if steps and all(s["ok"] for s in steps) else ("failed" if steps else "never run")
    ago = ""
    if newest:
        mins = int((time.time() - newest) / 60)
        ago = "just now" if mins < 1 else (f"{mins}m ago" if mins < 90 else f"{mins // 60}h ago")

    # What's landed since the gate last ran. Yegge watches commit rate against
    # build time because that gap is where unproven code accumulates; the same
    # gap on one machine is just "how much of this has nobody checked".
    # Named, not just counted: a commit can land after the gate without naming
    # any bead, so the number here and the cards in the commit lane measure
    # different things. Listing them is what stops that reading as a bug.
    unverified = []
    if newest:
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(newest))
        log = run("git", "log", "--since", stamp, "--format=%h\x1f%s")
        for line in log.splitlines():
            if line.strip():
                sha, _, subject = line.partition("\x1f")
                unverified.append({"sha": sha, "subject": subject})

    took = ""
    marker = logs / "elapsed"
    if marker.exists() and abs(marker.stat().st_mtime - newest) < 120:
        secs = marker.read_text(errors="ignore").strip()
        if secs.isdigit():
            took = f"{int(secs)}s" if int(secs) < 90 else f"{int(secs) // 60}m {int(secs) % 60}s"

    return {"status": status, "when": ago, "tests": tests, "steps": steps,
            "unverified": unverified, "took": took, "at": newest}


def frontmatter(text):
    m = re.match(r"^---\n(.*?)\n---\n(.*)$", text, re.S)
    if not m:
        return {}, text
    meta = {}
    for line in m.group(1).splitlines():
        if ":" in line and not line.startswith(" "):
            k, v = line.split(":", 1)
            meta[k.strip()] = v.strip()
    return meta, m.group(2)


def catalog():
    """Skills and agents, with what each costs when idle versus when used. This
    is the whole argument for progressive disclosure, made visible."""
    skills, agents = [], []
    for f in sorted((ROOT / ".claude/skills").glob("*/SKILL.md")):
        meta, body = frontmatter(f.read_text(errors="ignore"))
        skills.append({
            "name": meta.get("name", f.parent.name),
            "description": meta.get("description", ""),
            "idle": tokens(meta.get("description", "")),
            "loaded": tokens(body),
        })
    for f in sorted((ROOT / ".claude/agents").glob("*.md")):
        meta, body = frontmatter(f.read_text(errors="ignore"))
        agents.append({
            "name": meta.get("name", f.stem),
            "model": meta.get("model", "inherit"),
            "description": meta.get("description", ""),
            "loaded": tokens(body),
        })
    return skills, agents


# Claude Code keeps auto-memory outside the repo, under a directory named for
# the project path with the separators flattened. Derived rather than written
# down so it follows the checkout instead of pinning one machine's home.
MEMORY_DIR = Path.home() / ".claude/projects" / str(ROOT).replace("/", "-") / "memory"

# The harness as it actually runs, in the order a session meets it: what wakes
# an agent, where its work lives, what it can reach for, what has to pass before
# anything lands, and what keeps the whole thing honest afterwards.
#
# `origin` is the load-bearing column. Claude Code supplies the slots — hooks,
# skills, subagents, auto-memory — and everything marked "harness" is what got
# built into them. Reading down that column is how you tell which half of the
# system is yours to change.
#
# Paths are globbed against disk, so a piece that's deleted stops being drawn
# rather than lingering in a diagram that lies, and a skill added tomorrow
# appears without anyone editing this table.
HARNESS = [
    ("wake", "what an agent knows before its first tool call", [
        (".claude/settings.json", "claude", "SessionStart and Stop hooks"),
        ("scripts/brief.sh", "harness", "the session brief, in place of bd prime"),
        ("harness/seat.md", "harness", "the role a session occupies"),
        ("harness/laurels.jsonl", "harness", "praise, replayed one at a time"),
        # Only the newest: the brief reads one, and a lane of every note this
        # project ever wrote would bury the pieces that actually run.
        ("harness/handoffs/*.md", "harness", "the last session's closing note", 1),
        ("CLAUDE.md", "claude", "project instructions, always loaded"),
        (str(MEMORY_DIR / "MEMORY.md"), "claude", "auto-memory index, loaded every session"),
    ]),
    # Split from wake on purpose, and not only because twenty cards would swamp
    # that stage: the index is what loads at wake, and these are what the index
    # lets a session go and find later. Drawing them together would say the whole
    # store is paid for every session, which is the cost this design avoids.
    ("remember", "one fact per file, fetched when it turns out to matter", [
        (str(MEMORY_DIR / "*.md"), "claude", "a memory: what was true when it was written"),
    ]),
    ("ledger", "where work is found and left", [
        (".beads/issues.jsonl", "harness", "the issue graph, exported for git"),
        (".claude/skills/beads/SKILL.md", "harness", "the bd surface, on demand"),
        (".claude/skills/workflow/SKILL.md", "harness", "how work moves through the system"),
    ]),
    ("reach", "capabilities that cost nothing until invoked", [
        (".claude/skills/*/SKILL.md", "claude", "a skill: description idle, body loaded"),
    ]),
    ("prove", "the gate a change passes before it counts", [
        ("scripts/verify.sh", "harness", "build, tests, and a smoke check, one exit code"),
        # Add your own here: the script that drives the app, the one that
        # packages it. Paths are globbed, so a row for a file that doesn't
        # exist simply isn't drawn.
    ]),
    ("review", "agents that didn't write the code reading it", [
        ("scripts/review.sh", "harness", "bundles the diff into one packet"),
        (".claude/agents/*.md", "claude", "a subagent: own context, cheap model"),
    ]),
    ("tend", "keeping the knowledge layer true and small", [
        ("scripts/context.py", "harness", "stale-doc and context-budget guard"),
        (".claude/context.lock", "harness", "hashes of what each doc describes"),
    ]),
]


def resolve(pattern, newest=0):
    """The files one HARNESS pattern stands for, oldest first. `newest` keeps
    only the last few — a lane of every handoff note ever written would bury
    the pieces that actually run."""
    parts = Path(pattern).parts
    wild = next((n for n, p in enumerate(parts) if "*" in p), None)
    if wild is None:
        path = Path(pattern) if Path(pattern).is_absolute() else ROOT / pattern
        return [path] if path.is_file() else []
    anchor = Path(*parts[:wild]) if Path(pattern).is_absolute() else ROOT / Path(*parts[:wild])
    found = sorted(p for p in anchor.glob(str(Path(*parts[wild:]))) if p.is_file())
    return found[-newest:] if newest else found


def harness():
    """The system diagram's nodes, read off disk.

    Bodies are deliberately absent: this rides the 2.5s poll, and the files
    behind it run to tens of thousands of characters. The page asks for one
    body when a node is opened, which is the only time anyone reads it."""
    stages, index = [], {}
    for name, blurb, members in HARNESS:
        nodes = []
        for pattern, origin, role, *cap in members:
            for path in resolve(pattern, cap[0] if cap else 0):
                rel = str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path)
                # A broad glob is written after the entries that call specific
                # files out by name, so the stage that names a piece keeps it and
                # the catch-all picks up whatever is left.
                if rel in index:
                    continue
                meta, body = frontmatter(path.read_text(errors="ignore"))
                nodes.append({
                    "id": rel,
                    # A skill's directory names it; SKILL.md three times over doesn't.
                    "name": meta.get("name") or (path.parent.name if path.name == "SKILL.md"
                                                 else path.name),
                    "path": rel,
                    "origin": origin,
                    # A file that describes itself wins over the table's guess.
                    # Not split on the first period: half these descriptions
                    # open with "CLAUDE.md" or "scripts/x.sh" and would be cut
                    # to one word.
                    "role": meta.get("description", "").strip('"').strip() or role,
                    "tokens": tokens(body),
                })
                index[rel] = path
        stages.append({"name": name, "blurb": blurb, "nodes": nodes})
    return stages, index


def budget(skills, agents):
    claude_md = (ROOT / "CLAUDE.md")
    brief = run("bash", str(ROOT / "scripts/brief.sh"))
    always = [
        {"name": "CLAUDE.md", "tokens": tokens(claude_md.read_text(errors="ignore")) if claude_md.exists() else 0},
        {"name": "session brief", "tokens": tokens(brief)},
        {"name": "skill descriptions", "tokens": sum(s["idle"] for s in skills)},
    ]
    on_demand = ([{"name": s["name"], "tokens": s["loaded"]} for s in skills]
                 + [{"name": a["name"], "tokens": a["loaded"]} for a in agents])
    return {
        "always": always,
        "always_total": sum(a["tokens"] for a in always),
        "on_demand": sorted(on_demand, key=lambda x: -x["tokens"]),
        # What the stock beads SessionStart hook printed, every session, before
        # it was replaced. The saving is per session and compounds.
        "brief_tokens": tokens(brief),
        "prime_tokens": 1569,
    }


# Which file each node id stands for. Kept beside the state rather than in it,
# because the page never sends a path — it sends an id this table already knows,
# so nothing in a request can name a file the diagram doesn't draw.
_harness_files = {}


def state():
    skills, agents = catalog()
    git, verify, ledger = git_state(), verify_state(), ledger_state()
    # Swapped whole, not cleared and refilled: a sheet opening mid-rebuild would
    # otherwise look up an id against an empty table and get a 404.
    global _harness_files
    stages, _harness_files = harness()

    # A bead waiting to be pushed carries the commits that hold it, so the board
    # can say how many and the sheet can list them.
    for issue in ledger["issues"]:
        carried = git["bead_commits"].get(issue["id"])
        if carried:
            issue["commit_count"] = carried["commits"]
            issue["commits"] = carried["list"]

    # Closed work is history, not the board, so it's sent oldest-hidden: the
    # frontend's load-more only reveals a page at a time, but the full list
    # rides along so paging back reaches the beginning rather than hitting a
    # wall the server never sent past. Sorted by when they were last touched,
    # because bd returns closed issues in no particular order: taking a slice
    # off the end kept the six oldest and dropped whatever had just been
    # finished, so a bead would leave staging on a push and never arrive in
    # done.
    by_id = {i["id"]: i for i in ledger["issues"]}
    live = [i for i in ledger["issues"] if i["status"] != "closed"]
    closed = sorted((i for i in ledger["issues"] if i["status"] == "closed"),
                    key=lambda i: i["updated_at"], reverse=True)

    # Only a bead with no parent gets a card, so those are what `done` shows.
    # Children are rolled into a parent that isn't on the board, and staged
    # beads are already showing in staging — surfacing them again in done
    # before a push moves them across would double them up.
    staged = [i for i in closed if "commit_count" in i]
    staged_ids = {i["id"] for i in staged}
    roots = [i for i in closed
             if i["parent"] not in by_id and i["id"] not in staged_ids]
    keep = {i["id"] for i in live + staged + roots}

    # Then close the family over what survived, in both directions. A kept child
    # without its parent turns back into a top-level card — the board hides a
    # child precisely by finding its parent in the payload — and a kept parent
    # needs its children for the detail pane to name them.
    while True:
        grow = {i["parent"] for i in ledger["issues"]
                if i["id"] in keep and i["parent"] in by_id and i["parent"] not in keep}
        grow |= {i["id"] for i in closed if i["parent"] in keep and i["id"] not in keep}
        if not grow:
            break
        keep |= grow

    ledger["issues"] = live + [i for i in closed if i["id"] in keep]

    return {
        "generated": time.strftime("%H:%M:%S"),
        "project": ROOT.name,
        "git": git,
        "ledger": ledger,
        "worktree": worktree_state(),
        "verify": verify,
        "runs": runs_state(),
        "skills": skills,
        "agents": agents,
        "harness": stages,
        "budget": budget(skills, agents),
    }


# The work-tree row actions. Each takes the path straight off a request body,
# but only after the handler has checked it against `worktree_paths()` — a
# path this request invented, rather than one git status already named, never
# reaches any of these.
def read_json(handler):
    length = int(handler.headers.get("Content-Length", 0) or 0)
    raw = handler.rfile.read(length) if length else b""
    try:
        return json.loads(raw) if raw else {}
    except json.JSONDecodeError:
        return {}


def stage_file(path):
    run("git", "add", "--", path)


def unstage_file(path):
    run("git", "restore", "--staged", "--", path)


def reveal_file(path):
    subprocess.Popen(["open", "-R", str(ROOT / path)])


def open_in_vscode(path):
    # The `code` CLI shim is an opt-in VS Code install step nobody here has
    # taken, but the .app is always there — `open -a` launches it the same way
    # Spotlight would, no shim required.
    try:
        subprocess.Popen(["code", "-g", str(ROOT / path)])
    except FileNotFoundError:
        subprocess.Popen(["open", "-a", "Visual Studio Code", str(ROOT / path)])


def commit(message, amend):
    args = ["git", "commit"]
    if amend:
        args.append("--amend")
    if message.strip():
        args += ["-m", message]
    elif amend:
        args.append("--no-edit")
    else:
        return {"ok": False, "error": "commit message is empty"}
    r = subprocess.run(args, capture_output=True, text=True, cwd=ROOT, timeout=25)
    return {"ok": r.returncode == 0, "error": "" if r.returncode == 0 else (r.stderr or r.stdout).strip()[:300]}


# The loops a human still triggers by hand. Kept as a fixed table rather than
# anything the page can name, so the only commands this server will ever run are
# the ones written here.
#
# ── FILL THIS IN ──────────────────────────────────────────────────────────
# Add the ones that put the app in front of you — installing it, launching it
# on a device — and give each a matching entry in TASKS in dashboard/index.html,
# which is what draws the buttons. Both lists start empty of them on purpose: a
# button for a script that doesn't exist is worse than no button.
TASKS = {
    "verify": ["scripts/verify.sh"],
    # The only one that leaves this machine. It stays a plain `git push` with no
    # arguments so it can only ever do what the branch is already tracking.
    "push": ["git", "push"],
}
_runs = {}


def start_task(name):
    """Run one of TASKS in the background and keep its last result. A second
    press while it's still going is ignored rather than queued — these install
    and relaunch the app, and two at once fight over the same process."""
    if name not in TASKS:
        return {"error": "unknown task"}
    if _runs.get(name, {}).get("state") == "running":
        return _runs[name]

    _runs[name] = {"state": "running", "output": "", "at": time.time()}

    def work():
        try:
            r = subprocess.run(TASKS[name], capture_output=True, text=True,
                               cwd=ROOT, timeout=900)
            tail = (r.stdout + r.stderr).strip().splitlines()
            _runs[name] = {
                "state": "ok" if r.returncode == 0 else "failed",
                # The page shows a line or two, not a build log.
                "output": " · ".join(tail[-2:])[:200] if tail else "",
                "at": time.time(),
            }
        except subprocess.TimeoutExpired:
            _runs[name] = {"state": "failed", "output": "timed out", "at": time.time()}
        except Exception as e:
            _runs[name] = {"state": "failed", "output": str(e)[:200], "at": time.time()}
        # Finishing changes the world the page is describing — a push moves the
        # tracking ref, so the beads named in those commits stop being unpushed
        # and fall back to done. Drop the cache so the next poll sees it rather
        # than showing work that has already left the machine.
        _cache["at"] = 0

    threading.Thread(target=work, daemon=True).start()
    return _runs[name]


def runs_state():
    out = {}
    for name in TASKS:
        r = _runs.get(name, {"state": "idle", "output": "", "at": 0})
        ago = ""
        if r["at"]:
            mins = int((time.time() - r["at"]) / 60)
            ago = "just now" if mins < 1 else f"{mins}m ago"
        out[name] = {**r, "ago": ago}
    return out


# Building the state shells out to bd several times and takes a second or two.
# The page polls faster than that, so without a cache each poll piles another
# generation on top of the last, several embedded Dolt engines end up contending
# for the same lock, and the server stops answering entirely — which is exactly
# what it did. One generation at a time, and everyone else gets the last one.
_cache = {"at": 0.0, "data": None}
_lock = threading.Lock()
CACHE_TTL = 4.0


def cached_state():
    fresh = time.time() - _cache["at"] < CACHE_TTL
    if fresh and _cache["data"] is not None:
        return _cache["data"]
    # A blocked thread re-checks under the lock: by the time it gets in, the
    # thread ahead of it has usually already refreshed.
    with _lock:
        if time.time() - _cache["at"] < CACHE_TTL and _cache["data"] is not None:
            return _cache["data"]
        _cache["data"] = state()
        _cache["at"] = time.time()
        return _cache["data"]


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(ROOT / "dashboard"), **kw)

    def do_POST(self):
        # The page can only ask for a task by name; the command behind that name
        # lives in TASKS and nothing in the request reaches a shell.
        if self.path.startswith("/run/"):
            body = json.dumps(start_task(self.path[len("/run/"):].split("?")[0])).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            # A run changes what the page should show, so don't make it wait out
            # the cache before it finds out.
            _cache["at"] = 0
            return
        if self.path.startswith("/worktree/"):
            action = self.path[len("/worktree/"):].split("?")[0]
            data = read_json(self)
            if action == "commit":
                result = commit(data.get("message", ""), bool(data.get("amend")))
            else:
                path = data.get("path", "")
                if path not in worktree_paths():
                    result = {"ok": False, "error": "not a pending change"}
                elif action == "stage":
                    stage_file(path)
                    result = {"ok": True}
                elif action == "unstage":
                    unstage_file(path)
                    result = {"ok": True}
                elif action == "revert":
                    result = {"ok": revert_file(path)}
                elif action == "reveal":
                    reveal_file(path)
                    result = {"ok": True}
                elif action == "vscode":
                    open_in_vscode(path)
                    result = {"ok": True}
                else:
                    return self.send_error(404)
            self.send_json(result)
            _cache["at"] = 0
            return
        self.send_error(404)

    def do_GET(self):
        if self.path.startswith("/state.json"):
            return self.send_json(cached_state())
        if self.path.startswith("/diff"):
            wanted = unquote(parse_qs(urlparse(self.path).query).get("path", [""])[0])
            result = diff_for(wanted)
            if result is None:
                return self.send_error(404)
            return self.send_json(result)
        # One harness file, read when a node is opened rather than on every poll.
        # The id is looked up in the table the diagram was built from; a path in
        # the request is never joined to anything, so there is nothing to escape.
        if self.path.startswith("/harness/"):
            wanted = unquote(self.path[len("/harness/"):].split("?")[0])
            if not _harness_files:
                cached_state()
            path = _harness_files.get(wanted)
            try:
                body = path.read_text(errors="ignore") if path else None
            except OSError:
                # Deleted between the poll that drew the node and the click that
                # opened it. Missing, not broken.
                body = None
            if body is None:
                return self.send_error(404)
            return self.send_json({"id": wanted, "body": body})
        super().do_GET()

    def send_json(self, payload):
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass  # a polling dashboard would otherwise print a line every two seconds


def is_serving(port):
    with socket.socket() as probe:
        probe.settimeout(0.4)
        return probe.connect_ex(("127.0.0.1", port)) == 0


# Who holds a port, written by the server that binds it. Without this a second
# project running this harness sees 7391 occupied, reports "already serving",
# and hands the user a link to a different project's board — the failure looks
# exactly like success, which is the worst kind.
def claim_file(port):
    return Path(f"/tmp/harness-dashboard-{port}.json")


def holder(port):
    """The checkout serving this port, or None if it's free or unclaimed."""
    if not is_serving(port):
        return None
    try:
        return json.loads(claim_file(port).read_text()).get("root")
    except Exception:
        return "unknown"


def free_port(start):
    """This checkout's port: the one it already holds, else the first free one
    from `start`. Stable across restarts, so the link stays the same all day."""
    for port in range(start, start + 20):
        who = holder(port)
        if who in (None, str(ROOT)):
            return port
    raise SystemExit(f"no free port in {start}–{start + 19}")


def wait_until_serving(port, timeout=5.0):
    """True once something answers on `port`. A just-spawned child needs a
    moment to bind, and the alternative to waiting for it is handing over a
    link before anyone knows whether it resolves."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if is_serving(port):
            return True
        time.sleep(0.1)
    return False


def write_snapshot():
    out = ROOT / "dashboard/state.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(state(), indent=2))
    return out


# The dashboard opens in Claude Code's own browser pane and nowhere else. Two
# reasons it is worth enforcing rather than suggesting: the pane is the only
# browser the agent can see into — it can read the page, screenshot it, and
# check its own work — and a system browser puts the board behind whatever
# window the human was already in, where it goes unread. Nothing here shells out
# to `open`; instead the port is published two ways, and both point at the pane.
LAUNCH_NAME = "harness-dashboard"


def write_launch_config(port):
    """Publish the live port as a `.claude/launch.json` entry, so the agent's
    `preview_start` can find the board by name however the port landed.

    An entry with a url and no command attaches to the server already running
    rather than starting a second one. The port moves between checkouts and
    across restarts, so this is rewritten on every bind — a stale entry points
    the pane at someone else's dashboard, which is worse than no entry at all.
    """
    path = ROOT / ".claude/launch.json"
    config = {"version": "0.0.1", "configurations": []}
    if path.exists():
        try:
            existing = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError):
            # Hand-edited into something unreadable: say so and keep serving.
            # A dashboard with no launch entry still works, the agent just has
            # to navigate to the printed URL by hand. Bailing out rather than
            # overwriting, because whatever is in there is someone's, and this
            # runs from a hook at the end of every turn.
            print(f"! {path} is not readable JSON — leaving it alone")
            return
        # Valid JSON of the wrong shape is the same situation, and it has to be
        # checked before `.get`: a top-level list parses fine and then raises
        # AttributeError, out of a hook, on every invocation until a human
        # notices.
        if not isinstance(existing, dict) or not isinstance(
                existing.get("configurations"), list):
            print(f"! {path} is not a launch config — leaving it alone")
            return
        config = existing
    # `isinstance` first, because an entry that isn't an object is someone
    # else's problem to fix and `.get` on it is this hook crashing every turn.
    # Left in place rather than dropped: this function's business is one entry.
    config["configurations"] = [c for c in config["configurations"]
                                if not isinstance(c, dict)
                                or c.get("name") != LAUNCH_NAME]
    config["configurations"].append({
        "name": LAUNCH_NAME,
        "url": f"http://localhost:{port}",
        "port": port,
    })
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(config, indent=2) + "\n")


def announce(url, note):
    """Hand the link over. Printed rather than opened, because the only thing
    that can open Claude Code's browser pane is the agent reading this line —
    hook output is context, so the instruction travels with the URL."""
    print(f"harness dashboard → {url}   ({note})")
    print(f"open it in Claude Code's browser pane — preview_start "
          f"{LAUNCH_NAME}, or navigate to {url}. Not the system browser.")


CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"


def shot(path, port, width=900, height=1400):
    """Write a picture of the running dashboard, for the design review pass.

    The reviewing agent reads screenshots off disk, and a dashboard looked at in
    a browser pane leaves nothing behind — so the change nobody could photograph
    was the change nobody reviewed. Chrome headless renders the same page the
    server is already serving.
    """
    if not Path(CHROME).exists():
        return f"no Chrome at {CHROME} — install it or capture by hand"
    if not is_serving(port):
        return f"nothing serving on {port} — run `dashboard.py up` first"
    # A budget rather than a sleep: the page paints once its first poll lands,
    # and virtual time runs it forward without waiting in real seconds.
    subprocess.run([CHROME, "--headless", "--disable-gpu", "--hide-scrollbars",
                    f"--window-size={width},{height}", f"--screenshot={path}",
                    "--virtual-time-budget=2500", f"http://localhost:{port}/"],
                   capture_output=True)
    return path if Path(path).exists() else "chrome wrote nothing"


def main():
    args = sys.argv[1:]
    if args and args[0] == "snapshot":
        print(write_snapshot())
        return

    explicit_port = "--port" in args
    port = int(args[args.index("--port") + 1]) if explicit_port else free_port(PORT)

    # Named so `scripts/review.sh` picks it up with the app's own captures.
    if args and args[0] == "shot":
        target = args[1] if len(args) > 1 else "/tmp/har-dashboard.png"
        print(shot(target, port))
        return

    # `up` is what the Stop hook calls: leave a dashboard running at the end of
    # every turn, so the link handed to the user always resolves. Detached and
    # in a session of its own, or it dies with the hook that started it.
    if args and args[0] == "up":
        if holder(port) is not None:
            note = "already serving"
        else:
            log = open("/tmp/har-dash.log", "a")
            # --port, or the child re-runs free_port() from scratch and can
            # pick a different one than the port just printed — two siblings
            # starting at once then both claim to have started on 7391, one
            # child dies binding it, and its parent has already handed over the
            # link. The process that binds must be told which port was chosen.
            subprocess.Popen([sys.executable, str(Path(__file__).resolve()),
                              "--port", str(port)],
                             cwd=ROOT, stdout=log, stderr=log,
                             stdin=subprocess.DEVNULL, start_new_session=True)
            # Watched rather than assumed. The child was pinned to this port
            # and has no second candidate, so a sibling that won the race
            # leaves it dead — and publishing the port would then persist a
            # link to nothing until some later `up` overwrites it.
            note = "started" if wait_until_serving(port) else ""
        if not note:
            print(f"! nothing came up on {port} — see " + "/tmp/har-dash.log")
        else:
            # Written here rather than left to the child: the hook output the
            # agent reads is this process's, and a launch entry that lands
            # after it is a `preview_start` that misses by a second.
            write_launch_config(port)
            announce(f"http://localhost:{port}/", note)
        write_snapshot()
        return

    os.chdir(ROOT)
    url = f"http://localhost:{port}/"

    # The bind is the only honest check: anything that asks first and binds
    # second loses the port in the gap between the two, and the hooks make that
    # gap easy to hit — `up` decides a port is free a moment before its own
    # child takes it. So try to take it, and read failure as "someone got here
    # first" rather than asking in advance.
    #
    # An explicitly named port is an instruction, not a starting point: wander
    # off it and the caller who asked for 9000 gets told about 9001. Only the
    # inferred port is allowed to keep looking.
    candidates = [port] if explicit_port else range(port, port + 20)
    srv = None
    for candidate in candidates:
        try:
            srv = http.server.ThreadingHTTPServer(("127.0.0.1", candidate), Handler)
            port = candidate
            break
        except OSError:
            # Ours, or unclaimed and therefore not ours to displace: either way
            # the dashboard the caller wanted is already there.
            if holder(candidate) in (str(ROOT), "unknown"):
                write_launch_config(candidate)
                announce(f"http://localhost:{candidate}/", "already running")
                return
            # Another checkout holds it. Keep looking.
    if srv is None:
        raise SystemExit(f"could not bind {port}" if explicit_port
                         else f"no free port in {port}–{port + 19}")

    url = f"http://localhost:{port}/"
    with srv:
        claim_file(port).write_text(json.dumps({"root": str(ROOT)}))
        write_launch_config(port)
        announce(url, "ctrl-c to stop")
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            print("\nstopped")
        finally:
            claim_file(port).unlink(missing_ok=True)


if __name__ == "__main__":
    main()
