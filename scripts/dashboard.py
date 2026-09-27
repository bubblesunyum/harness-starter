#!/usr/bin/env python3
"""The harness dashboard: what the development system is doing, as a live picture.

    scripts/dashboard.py            # start it in the background if nothing is serving
    scripts/dashboard.py up          # the same thing, spelled the way the hooks call it
    scripts/dashboard.py serve      # stay in the foreground instead (ctrl-c to stop)
    scripts/dashboard.py snapshot   # just write dashboard/state.json
    scripts/dashboard.py shot [png] # photograph it, for the design review pass
    scripts/dashboard.py --port N   # serve somewhere else

Backgrounding is the default because of who runs this: a hook at the end of a
turn, or an agent that has other work to get to. A foreground server there is a
terminal nobody gets back. `serve` is the one that blocks, and it is also what
the background form re-runs as its own detached child.

State is rebuilt from bd and git by a thread of its own, and a request is only
ever handed the snapshot that thread last finished — so the page is live (claim a
bead in one terminal and the diagram moves) and every poll after the first is
answered at once, however long bd takes. Only the first waits, for the first
build. Building state on the request instead is what made the server fall behind
its own polling. The snapshot form exists for the Stop hook, which leaves
a readable file behind even when nothing is serving.
"""

import http.server
import json
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
import tomllib
from pathlib import Path
import urllib.request
from urllib.parse import parse_qs, unquote, urlparse

ROOT = Path(__file__).resolve().parent.parent


def _bd_prefix():
    """The ledger's bead prefix, asked of the ledger itself at runtime — the
    installer used to bake it into this file, which made every copy differ and
    un-updatable. The ledger is the one source of truth for it."""
    try:
        r = subprocess.run(["bd", "config", "get", "issue_prefix"],
                           capture_output=True, text=True, timeout=10, cwd=ROOT)
        got = (r.stdout or "").strip()
        if r.returncode == 0 and re.fullmatch(r"[a-z0-9]{1,10}", got):
            return got
    except Exception:
        pass
    # No ledger to ask, or an answer with nothing usable in it: derive from the
    # directory name the same way `harness add` does, so the worst case still
    # validates this project's own beads.
    short = re.sub(r"[^a-z0-9]", "", ROOT.name.lower()).lstrip("0123456789")[:3]
    return short or "bd"


_prefix = None


def prefix():
    global _prefix
    if _prefix is None:
        _prefix = _bd_prefix()
    return _prefix


def bead_re():
    return re.compile(rf"^{re.escape(prefix())}-[a-z0-9]+(?:\.\d+)?$")
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
    # One `git log` for both the last commit and today's count: the newest entry
    # is the first line, and the rest are what "today" means. Two invocations
    # here cost as much as the whole rest of the build, and the refresher pays
    # them on every cycle.
    since = time.strftime("%Y-%m-%dT00:00:00")
    today = run("git", "log", "--since", since, "--format=%h\x1f%s\x1f%cr")
    lines = [l for l in today.splitlines() if l.strip()]
    if lines:
        sha, subject, when = (lines[0].split("\x1f") + ["", "", ""])[:3]
    else:
        # Nothing today, so the last commit is older than the window and needs
        # its own read.
        log = run("git", "log", "-1", "--format=%h\x1f%s\x1f%cr")
        sha, subject, when = (log.split("\x1f") + ["", "", ""])[:3]

    # Landed locally but not shared yet. A bead named in one of these commits is
    # done in the working copy and invisible to anywhere else, which is its own
    # state worth seeing.
    upstream = run("git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
    branch = run("git", "rev-parse", "--abbrev-ref", "HEAD")
    unpushed, mentioned = [], {}
    if upstream:
        raw = run("git", "log", f"{upstream}..HEAD", "--format=%h\x1f%s\x1f%b\x1f%ct\x1e")
        for entry in [e for e in raw.split("\x1e") if e.strip()]:
            parts = entry.strip().split("\x1f")
            unpushed.append({"sha": parts[0], "subject": parts[1] if len(parts) > 1 else "",
                             "at": float(parts[3]) if len(parts) > 3 and parts[3] else 0})
            # A bead can be spread over several commits; the lane shows the
            # bead once and says how many carry it.
            for bead in set(re.findall(rf"\b{re.escape(prefix())}-[a-z0-9]+(?:\.\d+)?\b", entry)):
                seen = mentioned.setdefault(bead, {"commits": 0, "at": 0, "list": []})
                seen["commits"] += 1
                seen["at"] = max(seen["at"], unpushed[-1]["at"])
                seen["list"].append({"sha": unpushed[-1]["sha"],
                                     "subject": unpushed[-1]["subject"]})

    return {
        "branch": branch,
        "upstream": upstream,
        "dirty": len(dirty),
        "commits_today": len(lines),
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
    # It is a count over a fortnight and cannot change between two builds a few
    # seconds apart, so it does not deserve a `bd` spawn on every one.
    #
    # The quick-add row suggests labels while typing. The page could derive them
    # from the issues it already has, but a ledger whose labels all sit on
    # closed beads would then suggest nothing — so the full set rides along.
    # Computed before the closed-bead trim below, which is what would hide them.
    all_labels = sorted({l for i in issues for l in (i.get("labels") or [])})
    return {"counts": counts, "issues": issues, "stale": cached_stale(),
            "all_labels": all_labels}


# How long a stale count is reused before another `bd stale` is spawned.
STALE_TTL = 300.0
_stale = {"n": 0, "at": 0.0}


def cached_stale():
    if time.time() - _stale["at"] > STALE_TTL:
        _stale["n"] = len(bd_json("stale", "--days", "14"))
        _stale["at"] = time.time()
    return _stale["n"]


# ── FILL THIS IN ──────────────────────────────────────────────────────────
# Your build tool's success/failure line, if it prints one — e.g. xcodebuild's
# "** BUILD SUCCEEDED **" wants r"\*\* (?:BUILD|TEST) (SUCCEEDED|FAILED) \*\*".
# Leave it as r"(?!)" — a pattern that matches nothing — if yours prints no
# verdict; the error-line fallback below is what runs then.
# ──────────────────────────────────────────────────────────────────────────
VERDICT = r"(?!)"


def ago_for(at):
    """How long ago, in the board's words. Empty for something that never ran."""
    if not at:
        return ""
    mins = int((time.time() - at) / 60)
    return "just now" if mins < 1 else (f"{mins}m ago" if mins < 90 else f"{mins // 60}h ago")


# Reading the gate's logs is the expensive half of `verify_state` — tens of
# thousands of lines — and they change only when the gate runs, which is not
# every few seconds. Keyed on what every log's mtime and size add up to, so a
# finished run invalidates it and a quiet minute costs no reads at all.
#
# Only what is *derived from the logs* may live here. `unverified` is a live
# `git log` against the working copy and goes out of date the moment a commit
# lands, with the logs untouched — caching it alongside these froze the one
# number on the board whose whole job is to notice work the gate hasn't seen.
_verify = {"key": None, "read": None}


def log_ok(text):
    """The text fallback for a step with no status file beside its log. A build
    tool's own verdict wins where it prints one. Counting "error:" lines does
    not work on its own: a passing test run logs dozens from the app's output,
    and reading those as failures marks a green suite red. Add your toolchain's
    verdict line to VERDICT. Empty still fails: a step that never ran must not
    read green."""
    verdict = re.findall(VERDICT, text)
    if verdict:
        return verdict[-1].upper() in ("SUCCEEDED", "PASSED", "OK")
    return bool(text.strip()) and not re.search(r"\berror:", text)


def read_logs(logs):
    """What the gate's own logs say: its steps, when they were written, the test
    line, and the verdict over all of them."""
    steps, newest = [], 0
    # A "*.log.status" sibling never matches "*.log", so no filtering needed.
    for log in sorted(logs.glob("*.log")):
        text = log.read_text(errors="ignore")
        # The gate records each step's exit status beside its log, which is
        # ground truth — a passing step usually logs nothing, and no text
        # pattern can tell that apart from a step that never ran.
        status_file = log.with_name(log.name + ".status")
        if status_file.is_file():
            try:
                ok = int(status_file.read_text(errors="ignore").strip()) == 0
            except ValueError:
                ok = log_ok(text)
        else:
            ok = log_ok(text)
        steps.append({"name": log.stem.replace("-", " "), "ok": ok})
        newest = max(newest, log.stat().st_mtime)

    tests = ""
    unit = logs / "unit-tests.log"
    if unit.exists():
        m = re.findall(r"Executed (\d+) tests?, with (\d+) failures?", unit.read_text(errors="ignore"))
        if m:
            tests = f"{m[-1][0]} tests, {m[-1][1]} failing"

    status = "passed" if steps and all(s["ok"] for s in steps) else ("failed" if steps else "never run")
    return steps, newest, tests, status


def verify_state():
    """Read the last gate run off its logs rather than running it — the dashboard
    reports on the system, it doesn't drive it."""
    logs = Path(f"/tmp/{prefix()}-verify")
    if not logs.is_dir():
        return {"status": "never run", "when": "", "tests": "", "steps": [],
                "unverified": 0, "took": "", "at": 0}

    key = tuple(sorted((f.name, f.stat().st_mtime, f.stat().st_size)
                       for f in list(logs.glob("*.log")) + list(logs.glob("*.log.status"))))
    if _verify["key"] == key:
        steps, newest, tests, status = _verify["read"]
    else:
        steps, newest, tests, status = read_logs(logs)
        _verify["key"], _verify["read"] = key, (steps, newest, tests, status)

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

    return {"status": status, "when": ago_for(newest), "tests": tests, "steps": steps,
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


# Parsed skill and agent files, keyed by path and invalidated on mtime. These
# change when someone edits a skill, which is not something that happens between
# two builds seconds apart — and re-reading and re-tokenising every one of them
# on every cycle was pure disk traffic.
_catalog = {}


def parsed(f):
    """`frontmatter` for a file, re-reading only when it has actually changed."""
    try:
        stamp = f.stat().st_mtime
    except OSError:
        return {}, ""
    hit = _catalog.get(f)
    if hit and hit[0] == stamp:
        return hit[1]
    got = frontmatter(f.read_text(errors="ignore"))
    _catalog[f] = (stamp, got)
    return got


def catalog():
    """Skills and agents, with what each costs when idle versus when used. This
    is the whole argument for progressive disclosure, made visible."""
    skills, agents = [], []
    for f in sorted((ROOT / ".claude/skills").glob("*/SKILL.md")):
        meta, body = parsed(f)
        skills.append({
            "name": meta.get("name", f.parent.name),
            "description": meta.get("description", ""),
            "idle": tokens(meta.get("description", "")),
            "loaded": tokens(body),
        })
    for f in sorted((ROOT / ".claude/agents").glob("*.md")):
        meta, body = parsed(f)
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
        (".claude/agents/*.md", "claude", "a subagent: own context, its own model"),
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


# The budget runs brief.sh, which runs bd, and that is 1.7s of a 3s state build
# — over half of it — for a number that moves when a doc is edited, not between
# two polls a few seconds apart. On its own slower clock it stops dominating the
# refresh it rides on. Only the refresher thread builds state, so no lock.
_budget = {"at": 0.0, "data": None}
BUDGET_TTL = 60.0


def cached_budget(skills, agents):
    if _budget["data"] is None or time.time() - _budget["at"] > BUDGET_TTL:
        _budget["data"] = budget(skills, agents)
        _budget["at"] = time.time()
    return _budget["data"]


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
        "project": project_name(),
        "git": git,
        "ledger": ledger,
        "worktree": worktree_state(),
        "verify": verify,
        "runs": runs_state(),
        "skills": skills,
        "agents": agents,
        "harness": stages,
        "budget": cached_budget(skills, agents),
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


# The board's own writes: filing a bead and dragging one between lanes. Like
# the run table and the work-tree actions, these run fixed `bd` invocations —
# nothing in a request reaches a shell, and the id, lane and labels are
# validated before they get near one. Bead ids are checked against bead_re(),
# the ledger's own prefix resolved at runtime.
# The lanes a card can be dropped on. Kept in step with DROP_LANES and the
# backlog strip's data-drop in dashboard/index.html by hand — the page can't
# read this table, so a lane added here needs adding there too.
MOVE_LANES = ("ready", "blocked", "in_progress", "review", "done", "backlog")
LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")


def bd_run(*args):
    """A `bd` write, with its verdict kept. Reads use bd_json and run(), which
    swallow failures into empty output; a write has to say whether it landed."""
    try:
        r = subprocess.run(["bd", *args], capture_output=True, text=True,
                           timeout=25, cwd=ROOT)
        return r.returncode, (r.stdout or "").strip(), (r.stderr or "").strip()
    except Exception as e:
        return 1, "", str(e)[:200]


def create_bead(payload):
    # read_json returns whatever the body parsed as — a list or a number is a
    # 400-shaped problem, not an AttributeError that drops the connection.
    if not isinstance(payload, dict):
        return {"ok": False, "error": "bad request"}
    title = payload.get("title")
    title = title.strip() if isinstance(title, str) else ""
    if not title:
        return {"ok": False, "error": "title is empty"}
    if len(title) > 300:
        return {"ok": False, "error": "title is too long (300 characters)"}
    description = payload.get("description")
    description = description.strip() if isinstance(description, str) else ""
    # Rejected rather than sliced: a silent trim files something the reader
    # didn't write, and the composer can't tell it happened.
    if len(description) > 5000:
        return {"ok": False, "error": "description is too long (5000 characters)"}
    try:
        priority = int(payload.get("priority", 2))
    except (TypeError, ValueError):
        return {"ok": False, "error": "priority must be 0–4"}
    if priority not in (0, 1, 2, 3, 4):
        return {"ok": False, "error": "priority must be 0–4"}
    labels = payload.get("labels") or []
    if isinstance(labels, str):
        labels = [s.strip() for s in labels.split(",")]
    if not isinstance(labels, (list, tuple)):
        return {"ok": False, "error": "labels must be an array"}
    if len([l for l in labels if str(l).strip()]) > 10:
        return {"ok": False, "error": "at most 10 labels"}
    clean = []
    for label in labels[:10]:
        label = str(label).strip()
        if not label:
            continue
        if not LABEL_RE.match(label) or len(label) > 40:
            return {"ok": False, "error": f"bad label: {label}"}
        if label not in clean:
            clean.append(label)
    args = ["create", "--title", title, "--priority", str(priority), "--json"]
    if description:
        args += ["--description", description]
    if clean:
        args += ["--labels", ",".join(clean)]
    code, out, err = bd_run(*args)
    if code != 0:
        return {"ok": False, "error": (err or out or "bd create failed")[:300]}
    try:
        created = json.loads(out) if out else {}
    except json.JSONDecodeError:
        created = {}
    return {"ok": True, "id": created.get("id", "")}


def move_bead(payload):
    if not isinstance(payload, dict):
        return {"ok": False, "error": "bad request"}
    bead = payload.get("id")
    bead = bead.strip() if isinstance(bead, str) else ""
    lane = payload.get("lane")
    lane = lane.strip() if isinstance(lane, str) else ""
    if not bead_re().match(bead):
        return {"ok": False, "error": "not a bead id"}
    if lane not in MOVE_LANES:
        return {"ok": False, "error": "not a bead lane"}
    # A drag lands a bead in a lane, whatever it was before. Reopening
    # something already open says so and exits 0, so there is no need to ask
    # what it is first — every target but done starts from open.
    if lane == "done":
        code, out, err = bd_run("close", bead)
        if code != 0:
            return {"ok": False, "error": f"close failed: {(err or out or 'bd close failed')}"[:300]}
        return {"ok": True}
    if lane == "review":
        action, cleanup = ("label", "add", bead, "review"), ("backlog",)
    elif lane == "backlog":
        action, cleanup = ("label", "add", bead, "backlog"), ()
    else:
        status = {"ready": "open", "blocked": "blocked",
                  "in_progress": "in_progress"}[lane]
        action = ("update", bead, "--status", status)
        # Review outranks every open lane on the board: a bead that keeps the
        # label lands in review, not where it was dropped. Backlog keeps it
        # off the board altogether, for the same reason.
        cleanup = ("review", "backlog")
    bd_run("reopen", bead)
    code, out, err = bd_run(*action)
    if code != 0:
        return {"ok": False, "error": (err or out or "bd failed")[:300]}
    stuck = [label for label in cleanup if bd_run("label", "remove", bead, label)[0] != 0]
    if stuck:
        return {"ok": False,
                "error": f"moved, but {', '.join(stuck)} still attached — drop it again"}
    return {"ok": True}


# The loops a human still triggers by hand. They live in dashboard.toml beside
# this file — project-owned, installed once, never touched by `harness update`
# — so adding a button is a TOML edit, not a code edit, and this file stays
# byte-identical everywhere. The table is still a fixed list, never anything
# the page names: the only commands this server will ever run are the ones
# written there. It is also the only place a run button is described: label,
# the label while it's going, and where on the page it belongs. The page draws
# slots from the state and names no task of its own.
#
#   where = "header"       the strip at the top right
#           "gate"         inside the gate popover, next to the word it proves
#           "lane:<key>"   in a board lane's header, e.g. lane:staging
#
# A missing dashboard.toml serves these defaults; a broken one keeps serving
# the last good table and says so on stderr. Either way the page never waits.
DEFAULT_TASKS = {
    "verify": {
        "command": ["scripts/verify.sh"],
        "label": "run",
        "busy": "running…",
        "where": "gate",
    },
    # The only one that leaves this machine. It stays a plain `git push` with no
    # arguments so it can only ever do what the branch is already tracking.
    "push": {
        "command": ["git", "push"],
        "label": "push",
        "busy": "pushing…",
        "where": "lane:staging",
    },
}

_TASK_NAME = re.compile(r"^[A-Za-z0-9_-]{1,40}$")
_TASK_WHERE = {"header", "gate"} | {
    f"lane:{k}" for k in
    ("ready", "blocked", "in_progress", "review", "done", "backlog", "staging", "worktree")}

_toml = {"mtime": (0.0, 0), "reported": (0.0, 0), "tasks": None, "name": None}
_toml_lock = threading.Lock()


def _check_tasks(doc):
    """dashboard.toml, validated. Returns (tasks, name); raises ValueError with
    the reason when the file parses but doesn't say something runnable."""
    if not isinstance(doc, dict):
        raise ValueError("dashboard.toml holds no table")
    project = doc.get("project", {})
    if not isinstance(project, dict):
        raise ValueError("[project] is not a table")
    name = project.get("name")
    if name is not None:
        if not isinstance(name, str) or not name.strip() or len(name) > 80:
            raise ValueError("[project].name must be 1–80 characters")
        name = name.strip()
    entries = doc.get("task", [])
    if not isinstance(entries, list):
        raise ValueError("[[task]] must be a list")
    tasks = {}
    for e in entries:
        if not isinstance(e, dict):
            raise ValueError("a [[task]] entry is not a table")
        tname = e.get("name")
        if not isinstance(tname, str) or not _TASK_NAME.match(tname):
            raise ValueError(f"bad task name: {tname!r}")
        if tname in tasks:
            raise ValueError(f"duplicate task: {tname}")
        cmd = e.get("command")
        if (not isinstance(cmd, list) or not cmd
                or any(not isinstance(c, str) or not c or len(c) > 200 for c in cmd)):
            raise ValueError(f"task {tname} needs a non-empty command list")
        for key in ("label", "busy"):
            if not isinstance(e.get(key), str) or not e[key] or len(e[key]) > 40:
                raise ValueError(f"task {tname} needs a short {key}")
        if e.get("where") not in _TASK_WHERE:
            raise ValueError(f"task {tname} has an unknown where: {e.get('where')!r}")
        tasks[tname] = {"command": list(cmd), "label": e["label"],
                        "busy": e["busy"], "where": e["where"]}
    return tasks, name


def _refresh_toml():
    """Re-read dashboard.toml when it changed. Missing file: the defaults,
    silently. Broken file: keep serving the last good table and complain once
    per change, not once per snapshot build — the stamp only advances past a
    file that parsed, so a torn read retries instead of sticking."""
    global _toml
    try:
        st = (ROOT / "dashboard.toml").stat()
        stamp = (st.st_mtime, st.st_size)
    except OSError:
        stamp = (0.0, 0)
    with _toml_lock:
        if stamp == _toml["mtime"]:
            return
        if stamp == (0.0, 0):
            _toml = {"mtime": stamp, "reported": stamp, "tasks": dict(DEFAULT_TASKS), "name": None}
            return
        try:
            with open(ROOT / "dashboard.toml", "rb") as f:
                tasks, name = _check_tasks(tomllib.load(f))
        except (OSError, tomllib.TOMLDecodeError, ValueError) as e:
            if stamp != _toml["reported"]:
                # Guarded: a detached server can outlive its stderr, and a
                # logging print that raises would take the refresher thread —
                # and every future snapshot — down with it.
                try:
                    print(f"dashboard: {e} — keeping last good table", file=sys.stderr)
                except OSError:
                    pass
                _toml["reported"] = stamp
            if _toml["tasks"] is None:
                _toml["tasks"] = dict(DEFAULT_TASKS)
            return
        _toml = {"mtime": stamp, "reported": stamp, "tasks": tasks, "name": name}


def tasks():
    _refresh_toml()
    return _toml["tasks"]


def project_name():
    """Display name for the title. The TOML's, or the directory's."""
    _refresh_toml()
    return _toml["name"] or ROOT.name

_runs = {}


def start_task(name):
    """Run one of the dashboard.toml tasks in the background and keep its last result. A second
    press while it's still going is ignored rather than queued — these install
    and relaunch the app, and two at once fight over the same process."""
    if name not in tasks():
        return {"error": "unknown task"}
    if _runs.get(name, {}).get("state") == "running":
        return _runs[name]

    _runs[name] = {"state": "running", "output": "", "at": time.time()}

    def work():
        try:
            r = subprocess.run(tasks()[name]["command"], capture_output=True, text=True,
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
        touch()

    threading.Thread(target=work, daemon=True).start()
    return _runs[name]


def runs_state():
    """Every task's last result, plus the label and placement the page draws it
    with. Presentation travels with the state so that the TOML table above
    stays the one description of a run button."""
    out = {}
    for name, task in tasks().items():
        r = _runs.get(name, {"state": "idle", "output": "", "at": 0})
        ago = ""
        if r["at"]:
            mins = int((time.time() - r["at"]) / 60)
            ago = "just now" if mins < 1 else f"{mins}m ago"
        out[name] = {**r, "ago": ago, "label": task["label"],
                     "busy": task["busy"], "where": task["where"]}
    return out


# Building the state shells out to bd several times and takes two or three
# seconds — longer than the page's poll interval. Generating it on the request
# meant the cache expired between polls, so roughly every other request paid the
# whole build while holding the lock; responses arriving slower than the poll
# cadence backed up until the browser dropped the connection, and the page,
# seeing a failed fetch, stopped repainting. Retuning the TTL only moves that
# collision around. So a thread owns the build and requests only ever read the
# snapshot it last finished: a poll never waits on bd, however slow bd is.
_snapshot = {"data": None}
_built = threading.Event()
_wake = threading.Event()

# How long the refresher rests between builds while someone is watching, not how
# long a build takes — a build is a second or two here and will be longer on a
# big ledger, so the real cycle is that plus this. Nothing downstream depends on
# the number: the page shows when the snapshot it is drawing was generated, so a
# slow machine reads as an honest timestamp rather than a board that lies about
# being current. 5s rather than something tighter because the ledger does not
# change faster than that and every build is three `bd` spawns.
REFRESH = 5.0
# What it rests instead once nobody has polled in a while. A build is not free —
# three `bd` invocations, each opening the embedded Dolt engine cold, plus git —
# and paying it every few seconds for an empty room is what made `bd` the top
# entry in Activity Monitor's Energy tab with no session open.
IDLE_REFRESH = 60.0
# No poll in this long means no browser is attached. Comfortably longer than the
# page's own poll interval, so a viewer never trips it.
IDLE_AFTER = 30.0
# Long enough to cover a cold bd on a big ledger. Past it, something is wrong in
# a way that silence would hide.
FIRST_BUILD_TIMEOUT = 60.0
# No poll in this long means the session that started this server is gone.
# Serving a board nobody has looked at for an hour is what left three of these
# running across three projects. 0 disables the exit.
EXIT_AFTER = float(os.environ.get("DASHBOARD_EXIT_AFTER", 3600))

# When the page last asked for state. Seeded to launch so the first build still
# happens promptly for the browser `up` is about to open.
#
# `monotonic`, not `time()`: a laptop that sleeps for two hours with the board
# open wakes with a wall-clock gap longer than EXIT_AFTER, and the refresher —
# which resumes a moment before the page's own timer does — would read that as
# an abandoned dashboard and exit in the second before the user's next poll
# arrived. `monotonic` does not tick across system sleep, so a suspend reads as
# what it is: no time passed for anybody.
_last_poll = {"at": time.monotonic()}

# The port this process serves, once it has bound one. Every exit that isn't
# ctrl-c happens away from the `serve` block's `finally`, and a claim file left
# behind after the process is gone makes the next `up` report a dashboard that
# isn't there.
_bound_port = {"port": None}


def shutdown(reason, code=0):
    """Leave, releasing the port claim on the way out."""
    port = _bound_port["port"]
    if port is not None:
        claim_file(port).unlink(missing_ok=True)
    print(f"! {reason}", flush=True)
    os._exit(code)


def watched():
    """Whether a browser has polled recently enough to be worth building for."""
    return time.monotonic() - _last_poll["at"] < IDLE_AFTER


def refresher():
    """Rebuild the state forever, resting longer once nobody is watching."""
    while True:
        try:
            data = state()
            # One assignment, so a reader gets the previous dict or this one and
            # never a half-filled one. Nothing here mutates a published snapshot.
            _snapshot["data"] = data
            _built.set()
        except Exception as e:
            # A build that throws leaves the last good snapshot up rather than
            # blanking the board. Said out loud, because a dashboard quietly
            # serving a frozen picture is the failure this file is arranged
            # against.
            print(f"! state build failed: {e}", flush=True)
        idle = time.monotonic() - _last_poll["at"]
        if EXIT_AFTER and idle > EXIT_AFTER:
            since = f"{idle / 60:.0f}m" if idle >= 60 else f"{idle:.0f}s"
            shutdown(f"nobody polled in {since} — exiting")
        # An unwatched board costs a build a minute instead of one every few
        # seconds. The next poll wakes the thread through `touch()`, so the
        # first thing a returning viewer sees is at most one build old.
        _wake.wait(REFRESH if watched() else IDLE_REFRESH)
        _wake.clear()


def touch():
    """Something changed the world the page describes; rebuild without waiting."""
    _wake.set()


def cached_state():
    """The snapshot the refresher last finished. Waits only for the first one."""
    if not _built.wait(FIRST_BUILD_TIMEOUT):
        raise RuntimeError(
            f"no state built in {FIRST_BUILD_TIMEOUT:.0f}s — is `bd` answering in {ROOT}?")
    return _snapshot["data"]


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(ROOT / "dashboard"), **kw)

    def do_POST(self):
        # The page can only ask for a task by name; the command behind that name
        # lives in dashboard.toml and nothing in the request reaches a shell.
        if self.path.startswith("/run/"):
            body = json.dumps(start_task(self.path[len("/run/"):].split("?")[0])).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            # A run changes what the page should show, so don't make it wait out
            # the cache before it finds out.
            touch()
            return
        # The board's own writes. The id and lane are validated inside, the
        # same way a work-tree path is checked against git status below.
        if self.path.startswith("/beads/"):
            action = self.path[len("/beads/"):].split("?")[0]
            data = read_json(self)
            if action == "create":
                result = create_bead(data)
            elif action == "move":
                result = move_bead(data)
            else:
                return self.send_error(404)
            self.send_json(result)
            touch()
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
            touch()
            return
        self.send_error(404)

    def do_GET(self):
        if self.path.startswith("/state.json"):
            # A poll is the only evidence anyone is watching. Recording it before
            # the wake means the refresher re-reads a fresh `_last_poll`, so the
            # build it starts is already on the watched cadence.
            was_idle = not watched()
            _last_poll["at"] = time.monotonic()
            if was_idle:
                touch()
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
    return Path(f"/tmp/{prefix()}-dashboard-{port}.json")


def holder(port):
    """The checkout serving this port, or None if it's free or unclaimed."""
    if not is_serving(port):
        return None
    try:
        return json.loads(claim_file(port).read_text()).get("root")
    except Exception:
        return "unknown"


def held_pid(port):
    """The pid serving this checkout's port, or None. Only ever this checkout's
    own — signalling another project's dashboard is not `down`'s business."""
    try:
        claim = json.loads(claim_file(port).read_text())
    except Exception:
        return None
    if claim.get("root") != str(ROOT):
        return None
    pid = claim.get("pid")
    return pid if isinstance(pid, int) else None


def stop_serving():
    """Stop this checkout's dashboard, if it has one. Idempotent: a session that
    ends with no server running is the normal case, not an error."""
    for port in range(PORT, PORT + 20):
        pid = held_pid(port)
        if pid is None or not is_serving(port):
            continue
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            # Already gone, and the claim file outlived it. Clear the stale
            # claim so the next `up` does not read the port as taken.
            claim_file(port).unlink(missing_ok=True)
            continue
        return f"stopped the dashboard on {port}"
    return "no dashboard running"


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


# Portside (the menubar app for this machine's servers) gives every listener a
# stable one-word name and answers it at <alias>.local, so the board has a name
# worth saying out loud instead of a port worth forgetting. Read-only, and best
# effort: the map is a cache the app republishes every few seconds, so a
# dashboard that just started has no entry yet, and that is not an error.
PORTSIDE_ALIASES = Path.home() / ".portside/aliases.json"


def portside_alias(port):
    """This dashboard's Portside name, or None.

    Matched on the launch directory as well as the port. The map is only as
    fresh as the last scan, and a port this checkout just took may still be
    recorded against whatever held it before — naming the board after someone
    else's server is worse than not naming it.
    """
    try:
        aliases = json.loads(PORTSIDE_ALIASES.read_text())
    except (OSError, ValueError):
        # ValueError rather than JSONDecodeError: this file belongs to another
        # program, and the read can land mid-write. Bad UTF-8 raises
        # UnicodeDecodeError — a ValueError, not an OSError — and a nicety that
        # takes the Stop hook down every turn is not a nicety.
        return None
    if not isinstance(aliases, dict):
        return None
    for alias, server in aliases.items():
        if not isinstance(server, dict):
            continue
        if str(server.get("port")) == str(port) and server.get("directory") == str(ROOT):
            return alias
    return None


def announce(url, note):
    """Hand the link over. Printed rather than opened, because the only thing
    that can open Claude Code's browser pane is the agent reading this line —
    hook output is context, so the instruction travels with the URL."""
    print(f"harness dashboard → {url}   ({note})")
    alias = portside_alias(urlparse(url).port)
    if alias:
        print(f"portside calls it {alias} → http://{alias}.local")
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
    # Warmed on real time first. Chrome's virtual clock stops while a request is
    # outstanding, so against a server that hasn't built its first snapshot the
    # page's own poll spends the whole budget waiting — and the capture comes
    # back with a header, no board, and nothing to say it was photographed too
    # early. The design reviewer reads that as a blank page, which is worse than
    # no capture at all.
    try:
        with urllib.request.urlopen(f"http://localhost:{port}/state.json",
                                    timeout=FIRST_BUILD_TIMEOUT + 5) as r:
            r.read()
    except Exception as e:
        return (f"the dashboard on {port} gave no state in "
                f"{FIRST_BUILD_TIMEOUT + 5:.0f}s, so there is nothing to photograph: {e}")
    # A budget rather than a sleep: the page paints once its first poll lands,
    # and virtual time runs it forward without waiting in real seconds.
    subprocess.run([CHROME, "--headless", "--disable-gpu", "--hide-scrollbars",
                    f"--window-size={width},{height}", f"--screenshot={path}",
                    "--virtual-time-budget=2500", f"http://localhost:{port}/"],
                   capture_output=True)
    return path if Path(path).exists() else "chrome wrote nothing"


COMMANDS = ("up", "down", "serve", "snapshot", "shot")


def main():
    args = sys.argv[1:]
    # Bare flags are arguments to the default command, not a command. Anything
    # else that isn't in the table is a typo, and a typo that silently starts a
    # server is one nobody notices until they look for the thing they asked for.
    command = args[0] if args and not args[0].startswith("-") else "up"
    if command not in COMMANDS:
        raise SystemExit(f"{Path(__file__).name}: no such command: {command}\n"
                         f"  try: {', '.join(COMMANDS)}")

    if command == "snapshot":
        print(write_snapshot())
        return

    # What the SessionEnd hook calls. A dashboard exists to be looked at during
    # a session; one left running afterwards polls `bd` forever for an empty
    # room, and across a few projects that was the whole of this machine's
    # idle CPU. The server also times itself out (EXIT_AFTER) — this is the
    # tidy path, that is the backstop.
    if command == "down":
        print(stop_serving())
        return

    explicit_port = "--port" in args
    port = int(args[args.index("--port") + 1]) if explicit_port else free_port(PORT)

    # Named so `scripts/review.sh` picks it up with the app's own captures.
    if command == "shot":
        target = args[1] if len(args) > 1 else f"/tmp/{prefix()}-dashboard.png"
        print(shot(target, port))
        return

    # The default, and what both hooks call: leave a dashboard running at the
    # end of every turn, so the link handed to the user always resolves.
    # Detached and in a session of its own, or it dies with the hook that
    # started it.
    if command == "up":
        if holder(port) is not None:
            note = "already serving"
        else:
            log = open(f"/tmp/{prefix()}-dash.log", "a")
            # --port, or the child re-runs free_port() from scratch and can
            # pick a different one than the port just printed — two siblings
            # starting at once then both claim to have started on 7391, one
            # child dies binding it, and its parent has already handed over the
            # link. The process that binds must be told which port was chosen.
            # `serve`, explicitly: the child is the process that blocks, and
            # a child that inherited the backgrounding default would fork
            # again and again, each one handing off and exiting.
            subprocess.Popen([sys.executable, str(Path(__file__).resolve()),
                              "serve", "--port", str(port)],
                             cwd=ROOT, stdout=log, stderr=log,
                             stdin=subprocess.DEVNULL, start_new_session=True)
            # Watched rather than assumed. The child was pinned to this port
            # and has no second candidate, so a sibling that won the race
            # leaves it dead — and publishing the port would then persist a
            # link to nothing until some later `up` overwrites it.
            note = "started" if wait_until_serving(port) else ""
        if not note:
            print(f"! nothing came up on {port} — see " + f"/tmp/{prefix()}-dash.log")
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
        _bound_port["port"] = port
        claim_file(port).write_text(json.dumps({"root": str(ROOT), "pid": os.getpid()}))
        # `down` sends SIGTERM, whose default disposition kills the process
        # outright — past the `finally` below, leaving the claim file behind.
        signal.signal(signal.SIGTERM, lambda *_: shutdown("stopped"))
        write_launch_config(port)
        announce(url, "ctrl-c to stop")
        # Started before the first request, so the opening poll usually finds a
        # snapshot already waiting rather than paying for the build itself.
        threading.Thread(target=refresher, daemon=True).start()
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            print("\nstopped")
        finally:
            claim_file(port).unlink(missing_ok=True)


if __name__ == "__main__":
    main()
