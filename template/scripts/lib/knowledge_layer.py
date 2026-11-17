# Shared python for the knowledge lanes: one always-loaded list and one copy
# of the git-walking helpers, so the static lane, the behavioural trigger and
# the eval runner cannot drift apart. Imported by path from the lane heredocs,
# never installed and never imported by project code.
"""One list and one set of git helpers for the knowledge lanes."""

import glob
import json
import os
import re
import subprocess

# The always-loaded layer, one list: the trigger set and the overlay set are
# the same files. AGENTS.local.md is always-loaded text (AGENTS.md instructs
# reading it), so it triggers like the other two.
KNOWLEDGE_FILES = ("CLAUDE.md", "AGENTS.md", "AGENTS.local.md")

# Static-only: keyed, cheap and revertible knowledge the behavioural runner
# never overlays but the cost and duplicate checks still read.
KNOWLEDGE_EXTRA_EXACT = ("harness/learning.jsonl", "harness/laurels.jsonl")
KNOWLEDGE_PREFIXES = (".claude/skills/", ".claude/agents/")


def iter_layer_paths():
    # Every always-loaded doc path, both trees: the starter keeps its copy
    # under template/, so both sides of each doc are the same layer.
    for base in ("", "template/"):
        for doc in KNOWLEDGE_FILES:
            yield base + doc


def iter_skill_paths():
    # Every skill doc, both trees, at any depth: nested suits count, because
    # the trigger lanes already match them there. Filtered through the scope
    # helper, so the corpus and the scope rule cannot drift apart.
    for base in ("", "template/"):
        for path in sorted(glob.glob(base + ".claude/skills/**/SKILL.md",
                                     recursive=True)):
            if is_skill_or_agent_doc(strip_template_prefix(path)):
                yield path


def strip_template_prefix(path):
    # The starter keeps the product under template/: a diff there is the same
    # knowledge change, seen through the other tree. Reference projects have
    # no template/ directory, so the stripped form never matches there.
    if path.startswith("template/"):
        return path[len("template/"):]
    return path


def git_status_rows():
    # git status rows as (code, path), both sides of a rename, or None when
    # git itself fails. NUL-separated, so quoting, spaces and newlines in
    # names survive the trip — renames arrive as new-then-old, each its own
    # row under the same code. -uall lists untracked files individually
    # instead of collapsing them to their directory: a new skill file must
    # appear as its own row or the per-file trigger and duplicate checks
    # never see it. errors=replace: unreadable bytes count as 0, loudly —
    # never a traceback.
    out = subprocess.run(["git", "status", "--porcelain", "-z", "-uall"],
                         capture_output=True, text=True, errors="replace")
    if out.returncode != 0:
        return None
    rows = []
    fields = out.stdout.split("\0")
    idx = 0
    while idx < len(fields):
        field = fields[idx]
        idx += 1
        if not field or len(field) < 4:
            continue
        code = field[:2]
        path = field[3:]
        if not path:
            continue
        rows.append((code, path))
        if "R" in code:
            if idx < len(fields) and fields[idx]:
                rows.append((code, fields[idx]))
                idx += 1
    return rows


def has_commits():
    return subprocess.run(["git", "rev-parse", "HEAD"],
                          capture_output=True).returncode == 0


def is_knowledge_static(path):
    cand = strip_template_prefix(path)
    if cand in KNOWLEDGE_FILES + KNOWLEDGE_EXTRA_EXACT:
        return True
    for prefix in KNOWLEDGE_PREFIXES:
        if cand.startswith(prefix):
            return True
    return False


def read_worktree(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def read_base(path):
    # One HEAD blob as text, or None when absent. errors=replace: an
    # undecodable blob counts as 0 downstream, loudly — never a traceback.
    shown = subprocess.run(["git", "show", "HEAD:" + path],
                           capture_output=True, text=True, errors="replace")
    if shown.returncode != 0:
        return None
    return shown.stdout


def read_base_follow(path):
    # The HEAD-side content of a path that may pass through a symlink: a
    # committed file link, a file under a linked directory, or a plain
    # file. Linked content resolves to the target repo HEAD (the worktree
    # file and the link text are different objects — counting link text as
    # the base undercounts by the whole file); plain paths read straight
    # from HEAD. None when neither yields text.
    try:
        real = os.path.realpath(path)
        here = os.path.abspath(path)
    except OSError:
        return read_base(path)
    if real == here:
        return read_base(path)
    # Linked: target HEAD or nothing. Falling back to the link text here
    # would count a path string as file content; falling back to live
    # bytes would make the base depend on untracked state.
    return read_link_target(path)


def read_link_target(path):    # The content behind a symlinked path — a file link or a file under a
    # linked directory, which is how reference installs carry shared skills —
    # read at its target repo HEAD when the target lives in a git repo,
    # else absent. A target outside any repo has no HEAD to read, and live
    # bytes would make the base depend on untracked state — so it reads as
    # absent, never as worktree bytes. Never raises: any failure reads as
    # absent, and the caller treats absence conservatively.
    try:
        real = os.path.realpath(path)
    except OSError:
        return None
    try:
        here = os.path.abspath(path)
    except OSError:
        return None
    if real == here:
        return None
    target_dir = os.path.dirname(real)
    top_out = subprocess.run(
        ["git", "-C", target_dir or ".",
         "rev-parse", "--show-toplevel"],
        capture_output=True, text=True, errors="replace")
    if top_out.returncode != 0:
        return None
    top = top_out.stdout.strip()
    try:
        rel = os.path.relpath(real, top)
    except ValueError:
        return None
    if not rel or rel == "." or rel.startswith(".."):
        return None
    shown = subprocess.run(
        ["git", "-C", top, "show", "HEAD:" + rel],
        capture_output=True, text=True, errors="replace")
    if shown.returncode == 0:
        return shown.stdout
    return None


def head_tree():
    # The one ls-tree walk both HEAD-side readers share: the blob list wants
    # the paths, the duplicate baseline wants the modes too, to resolve
    # committed symlinks through their targets. NUL-separated so odd names
    # survive the trip. errors=replace: unreadable names count as 0, loudly.
    out = subprocess.run(["git", "ls-tree", "-r", "-z", "HEAD"],
                         capture_output=True, text=True, errors="replace")
    if out.returncode != 0:
        return None
    rows = []
    for entry in out.stdout.split("\0"):
        if not entry or "\t" not in entry:
            continue
        meta, path = entry.split("\t", 1)
        bits = meta.split()
        if len(bits) < 3 or not path:
            continue
        rows.append((bits[0], bits[1], path))
    return rows


def iter_agent_paths():
    # Every agent doc, both trees, one level: the layer ships no nested
    # agents. Filtered through the scope helper like the skill walk, so the
    # corpus and the scope rule cannot drift apart.
    for base in ("", "template/"):
        for path in sorted(glob.glob(base + ".claude/agents/*.md")):
            if is_skill_or_agent_doc(strip_template_prefix(path)):
                yield path


def tokens_of(text):
    return len(text) // 4


def seen_add(seen, display):
    # One real-path dedup for every corpus scan: symlinked trees read the same
    # bytes twice, so one real file counts once, under whichever name the scan
    # found first. True on first sighting, False when already seen.
    try:
        real = os.path.realpath(display)
    except OSError:
        real = display
    if real in seen:
        return False
    seen.add(real)
    return True


def skill_description(text):
    # The description field of the --- frontmatter block, or None. Anchored
    # to the block: body prose mentioning description: never counts.
    # split on \n only, so exotic boundaries stay inside the line.
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return None
    for line in lines[1:]:
        if line.strip() == "---":
            break
        found = re.match(r"^description:\s*(.*)$", line)
        if found:
            return found.group(1)
    return None


def cost_now():
    # (parts, total): the always-loaded cost of the worktree, realpath-deduped.
    parts = []
    seen = set()
    for doc in iter_layer_paths():
        text = read_worktree(doc)
        if text and seen_add(seen, doc):
            parts.append((doc, tokens_of(text)))
    for skill in iter_skill_paths():
        text = read_worktree(skill)
        if not text:
            continue
        found = skill_description(text)
        if found and seen_add(seen, skill + " description"):
            parts.append((skill + " description", tokens_of(found)))
    return parts, sum(count for _, count in parts)


def cost_base(parts):
    # The HEAD-side cost over the same layer: every covered path from its HEAD
    # blob, plus HEAD-only layer blobs (deleted since) from theirs. Deletions
    # credit their HEAD tokens and renames net out by content, because both
    # sides count content rather than names.
    base = 0
    seen_src = set()
    for display, _ in parts:
        src = display[:-12] if display.endswith(" description") else display
        if src in seen_src:
            continue
        seen_src.add(src)
        # Link-aware: a committed symlink counts its target HEAD content,
        # not the link text — cost_now follows the link, so the base must
        # too or every linked skill reads as pure growth.
        text = read_base_follow(src)
        if text is None:
            continue
        if display.endswith(" description"):
            found = skill_description(text)
            base += tokens_of(found) if found else 0
        else:
            base += tokens_of(text)
    rows = head_tree()
    if rows is None:
        return base
    for _, _, blob in rows:
        if blob in seen_src:
            continue
        cand = strip_template_prefix(blob)
        if cand in KNOWLEDGE_FILES:
            text = read_base_follow(blob)
            if text is not None:
                seen_src.add(blob)
                base += tokens_of(text)
        elif is_skill_or_agent_doc(cand) and cand.endswith("/SKILL.md"):
            text = read_base_follow(blob)
            if text is not None:
                seen_src.add(blob)
                found = skill_description(text)
                if found:
                    base += tokens_of(found)
    return base


def learning_vals(lines):
    # Every text/note value in jsonl lines, skipping blanks, comments and
    # broken rows. Shared by both corpus scans so the two read memories the
    # same way.
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        for key in ("text", "note"):
            val = row.get(key)
            if isinstance(val, str) and val.strip():
                yield val


def find_introduced_duplicates(texts, base_entries, changed_keys):
    # Sentences duplicated now that were not duplicated at HEAD, limited to
    # the diff: a duplicate wholly inside unchanged files is the librarians
    # to merge on its cadence, and a settled duplicate the diff never added
    # stays silent even when the diff touches one of its files. A repeat
    # inside one changed file counts too — pasting a paragraph twice in the
    # same new skill is the same bug wearing one filename.
    def carriers_of(entries):
        carriers = {}
        for name, text in entries:
            for sent in sentences(text):
                carriers.setdefault(sent, {})
                carriers[sent][name] = carriers[sent].get(name, 0) + 1
        return carriers

    def duplicated(carriers, sent):
        names = carriers.get(sent)
        if not names:
            return False
        return len(names) >= 2 or max(names.values()) >= 2

    def touches_changed(names):
        # A carrier counts as changed when it is a changed path or lives
        # under one: git status collapses an untracked dir (or dir symlink)
        # to a single row, so the nested file inside never matches by name.
        # The rstrip guards "a/b" against prefix-matching "a/bc".
        for name in names:
            cand = strip_template_prefix(name)
            for key in changed_keys:
                if cand == key or cand.startswith(key.rstrip("/") + "/"):
                    return True
        return False

    now = carriers_of(texts)
    base = carriers_of(base_entries)
    duplicates = []
    for sent in sorted(now):
        names = now[sent]
        if len(names) < 2 and max(names.values()) < 2:
            continue
        if duplicated(base, sent):
            continue
        if touches_changed(names):
            duplicates.append((sent, sorted(names)))
    return duplicates


def duplicate_texts():
    # (texts, note): every knowledge-layer text with its display name, one
    # real file once. The note is empty unless memories were unreadable.
    texts = []
    seen = set()
    for doc in iter_layer_paths():
        text = read_worktree(doc)
        if text and seen_add(seen, doc):
            texts.append((doc, text))
    for skill in iter_skill_paths():
        text = read_worktree(skill)
        if text and seen_add(seen, skill):
            texts.append((skill, text))
    for agent in iter_agent_paths():
        text = read_worktree(agent)
        if text and seen_add(seen, agent):
            texts.append((agent, text))
    for base in ("", "template/"):
        try:
            with open(base + "harness/learning.jsonl",
                      encoding="utf-8", errors="replace") as handle:
                for val in learning_vals(handle):
                    texts.append((base + "harness/learning.jsonl", val))
        except OSError:
            pass
    memo_note = ""
    try:
        mem_out = subprocess.run(["bd", "memories", "--json"],
                                 capture_output=True, text=True,
                                 errors="replace", timeout=30)
        mem = json.loads(mem_out.stdout or "{}")
        if isinstance(mem, dict):
            for key in sorted(mem):
                if isinstance(mem[key], str) and mem[key].strip():
                    texts.append(("memory:" + str(key), mem[key]))
    except Exception:
        memo_note = "  knowledge static: memories unreadable — files only\n"
    return texts, memo_note


def is_skill_or_agent_doc(cand):
    # True when a stripped path is an in-scope skill or agent doc. Skills nest
    # to any depth under .claude/skills/ — the trigger lanes already match
    # them there, so the checkers see them too — while agent docs stay one
    # level, which is all the layer ships.
    if cand.startswith(".claude/skills/") and cand.endswith("/SKILL.md"):
        rest = cand[len(".claude/skills/"):-len("/SKILL.md")]
        return bool(rest)
    if cand.startswith(".claude/agents/") and cand.endswith(".md"):
        rest = cand[len(".claude/agents/"):-len(".md")]
        return bool(rest) and "/" not in rest
    return False


def duplicate_base_texts():
    # (texts, note): the HEAD-side corpus for the sentence-level duplicate
    # check — the same in-scope files duplicate_texts scans, read at HEAD. A
    # missing blob (added or deleted since) reads as absent, never an error;
    # the note stays empty unless the blob listing itself failed, leaving the
    # base to the worktree files read at HEAD.
    texts = []
    for doc in iter_layer_paths():
        text = read_base(doc)
        if text:
            texts.append((doc, text))
    for base in ("", "template/"):
        text = read_base(base + "harness/learning.jsonl")
        if not text:
            continue
        for val in learning_vals(text.split("\n")):
            texts.append((base + "harness/learning.jsonl", val))
    rows = head_tree()
    if rows is None:
        # Wrapped: the note names the fallback when the listing fails.
        return texts, ("  knowledge static: HEAD listing failed"
                       " — base is worktree files at HEAD only\n")
    seen = set()
    seen_real = set()
    for display, _ in texts:
        seen.add(display)
        seen_add(seen_real, display)
    for mode, kind, blob in rows:
        if kind != "blob" or blob in seen:
            continue
        if not is_skill_or_agent_doc(strip_template_prefix(blob)):
            continue
        seen.add(blob)
        if not seen_add(seen_real, blob):
            continue
        if mode.startswith("12"):
            text = read_link_target(blob)
        else:
            text = read_base(blob)
        if text:
            texts.append((blob, text))
    # Skills and agents that never reach HEAD — the starter ignores root
    # links, reference installs keep them (file links and files under
    # linked directories alike) — still carry settled sentences. Only
    # linked paths read through to their target HEAD here: a link shares
    # bytes with its target, so judging link text would blind the base to
    # every shared file. A regular untracked file has no HEAD version and
    # reads as absent — treating its live bytes as base would mark its own
    # sentences already duplicated and silence the lane. Deduped by real
    # path: an untracked link into a tracked file adds nothing its target
    # has not already said.
    for path in iter_skill_paths():
        if path in seen or not is_skill_or_agent_doc(strip_template_prefix(path)):
            continue
        seen.add(path)
        if not seen_add(seen_real, path):
            continue
        text = read_link_target(path)
        if text:
            texts.append((path, text))
    for path in iter_agent_paths():
        if path in seen or not is_skill_or_agent_doc(strip_template_prefix(path)):
            continue
        seen.add(path)
        if not seen_add(seen_real, path):
            continue
        text = read_link_target(path)
        if text:
            texts.append((path, text))
    return texts, ""


def sentences(text):
    found = []
    for seg in re.split(r"[.!?;\n]+", text):
        norm = re.sub(r"[^a-z0-9 ]", " ", seg.lower())
        norm = re.sub(r"\s+", " ", norm).strip()
        if len(norm.split()) >= 8 and len(norm) >= 40:
            found.append(norm)
    return found
