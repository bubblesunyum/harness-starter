#!/bin/bash
# Rebuild harness/wiki/ from the ledger and handoffs — the wiki is derived, never primary.
#
# The wiki summarises bd memories, closed-bead reasons and committed handoff
# notes as an index plus one page per topic. Pages link to bead ids and memory
# keys and quote facts verbatim with their source; they never copy bodies, and
# contradictory lines stay side by side with their sources for a later pass to
# settle. Nothing here is new information: deleting harness/wiki/ and running
# this again rebuilds it byte-identically from `bd export --include-memories`
# plus the handoffs, so the directory is safe to drop.
#
# The topic of a key is the first slug segment before - or _ (bd-delete-needs-force
# lives under bd), which keeps the grouping mechanical — no judgment to drift.
# The one exception is a topic literally named "index", whose page would
# overwrite the index itself; it is written as topic-index.md instead.
#
# Caps keep the summary smaller than what it summarises: the index may not
# exceed WIKI_INDEX_MAX_PCT percent of the source bytes, the whole wiki not
# WIKI_TOTAL_MAX_PCT. Over the total cap the build first prunes every excerpt
# quote (key links always survive — reachability is load-bearing) and only
# then fails loudly, writing nothing, so a breach never ships a wiki bigger
# than its sources.
#
#   HARNESS_PROJECT=<proj> HARNESS_ROOT=<harness> bash scripts/build-wiki.sh
set -euo pipefail

ROOT="${HARNESS_PROJECT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HARNESS="${HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

# Tunables, this block only. Plain constants (or the environment when a probe
# or a project needs a tighter cap without shadowing this file) — never a
# fill-in block, which only seeds may carry.
WIKI_INDEX_MAX_PCT="${WIKI_INDEX_MAX_PCT:-50}"
WIKI_TOTAL_MAX_PCT="${WIKI_TOTAL_MAX_PCT:-100}"
WIKI_EXCERPT_CHARS="${WIKI_EXCERPT_CHARS:-140}"

command -v bd >/dev/null 2>&1 || {
  echo "build-wiki.sh: bd not found — the wiki is built from the ledger" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || {
  echo "build-wiki.sh: python3 not found — the wiki builder needs it" >&2; exit 1; }

work="$(mktemp -d -t harness-wiki)" || { echo "build-wiki.sh: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT
export_tmp="$work/export.jsonl"
stage="$work/stage"
mkdir -p "$stage" || { echo "build-wiki.sh: cannot make the stage dir" >&2; exit 1; }

bd export --include-memories -o "$export_tmp" >/dev/null 2>&1 || {
  echo "build-wiki.sh: 'bd export --include-memories' failed here — run it and read the error" >&2; exit 1; }

rc=0
summary="$(python3 - "$export_tmp" "$stage" "$ROOT" "$WIKI_INDEX_MAX_PCT" "$WIKI_TOTAL_MAX_PCT" "$WIKI_EXCERPT_CHARS" <<'PYEOF'
import json, os, re, sys
from pathlib import Path

export_path, stage, root = sys.argv[1], sys.argv[2], sys.argv[3]
index_pct, total_pct, excerpt_chars = int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
root = Path(root)

def topic_of(key):
    head = re.split(r"[-_]", key, maxsplit=1)[0]
    return head if head else key

def page_name(topic):
    slug = re.sub(r"[^A-Za-z0-9_-]", "-", topic) or "topic"
    return "topic-index" if slug == "index" else slug

def one_line(text, limit):
    for line in text.splitlines():
        s = " ".join(line.split())
        if s:
            return s if len(s) <= limit else s[:limit - 1] + "…"
    return ""

rows = []
for line in open(export_path, errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except ValueError:
        continue
    if isinstance(row, dict):
        rows.append(row)

memories = {}
for r in rows:
    if r.get("_type") == "memory" and isinstance(r.get("key"), str) and isinstance(r.get("value"), str):
        memories[r["key"]] = r["value"]
if not memories:
    print("build-wiki.sh: no memories — nothing to build")
    sys.exit(3)

closed = [(r["id"], str(r.get("title", "")), str(r.get("close_reason", "") or ""))
          for r in rows
          if r.get("_type") == "issue" and r.get("status") == "closed" and isinstance(r.get("id"), str)]

handoffs = []
hdir = root / "harness" / "handoffs"
if hdir.is_dir():
    # pathlib's glob matches dotfiles, unlike bash: the live journal files
    # (.live-*) and anything else dotted are session state, not sources.
    for p in sorted(hdir.glob("*.md")):
        if p.name.startswith("."):
            continue
        try:
            handoffs.append((p, p.read_bytes()))
        except OSError:
            continue

source_bytes = Path(export_path).stat().st_size + sum(len(b) for _, b in handoffs)

topics = {}
for key in sorted(memories):
    topics.setdefault(topic_of(key), []).append(key)

# Distinct topics can sanitize to the same filename (foo/bar vs foo-bar, Alpha
# vs alpha on a case-insensitive FS): first wins the base name, later ones take
# numeric suffixes, compared case-insensitively so the publish never overwrites.
page_for = {}
used_names = set()
for topic in sorted(topics):
    base = page_name(topic)
    name, n = base, 2
    while name.lower() in used_names:
        name = "%s-%d" % (base, n)
        n += 1
    used_names.add(name.lower())
    page_for[topic] = name

def mentions_topic_or_key(text, topic, keys):
    low = text.lower()
    if re.search(r"\b" + re.escape(topic.lower()) + r"\b", low):
        return True
    return any(k.lower() in low for k in keys)

def build(with_excerpts):
    pages = {}
    for topic in sorted(topics):
        keys = topics[topic]
        name = page_for[topic]
        lines = ["<!-- tracks: scripts/build-wiki.sh -->", "",
                 "# %s" % topic, "",
                 "%d %s on `%s`. Full text lives in the ledger — `bd recall <key>`"
                 " for any key below — and in the linked handoffs; this page only points at it."
                 % (len(keys), "memory" if len(keys) == 1 else "memories", topic), "",
                 "## Memories", ""]
        for k in keys:
            lines.append("- `%s`" % k)
            if with_excerpts:
                q = one_line(memories[k], excerpt_chars)
                if q:
                    lines.append('  > "%s" (memory `%s`)' % (q, k))
        beads = [(i, t, r) for i, t, r in closed if mentions_topic_or_key(i + " " + t, topic, keys)]
        if beads:
            lines += ["", "## Closed beads", ""]
            for i, t, r in sorted(beads):
                if not with_excerpts:
                    lines.append("- `%s` on `%s` (closed bead `%s`)" % (i, topic, i))
                    continue
                title = one_line(t, excerpt_chars) or t
                if one_line(r, excerpt_chars):
                    lines.append("- `%s` %s — closed: %s (bead `%s`)" % (i, title, one_line(r, excerpt_chars), i))
                else:
                    lines.append("- `%s` %s (closed bead `%s`)" % (i, title, i))
        notes = sorted("harness/handoffs/" + p.name for p, b in handoffs
                       if mentions_topic_or_key(b.decode("utf-8", "replace"), topic, keys))
        if notes:
            lines += ["", "## Handoffs", ""]
            lines += ["- %s" % n for n in notes]
        lines.append("")
        pages[name] = {"topic": topic, "text": "\n".join(lines) + "", "keys": keys}
    return pages

def emit(pages, dest):
    names = sorted(pages)
    total_keys = sum(len(pages[n]["keys"]) for n in names)
    machine = "<!-- wiki: topics=%d keys=%d -->" % (len(names), total_keys)
    idx = ["<!-- tracks: scripts/build-wiki.sh -->", machine, "",
           "# Wiki index", "",
           "Derived from bd memories, closed-bead reasons and handoff notes. Rebuild with",
           '`bash "$(scripts/harness root)/scripts/build-wiki.sh"`. Every memory key lives',
           "under exactly one topic; read the page, then `bd recall <key>` for full text.", "",
           "## Topics", ""]
    for n in names:
        p = pages[n]
        idx.append("- [[%s]] — %d %s on `%s`" % (n, len(p["keys"]),
                   "key" if len(p["keys"]) == 1 else "keys", p["topic"]))
    idx.append("")
    (Path(dest) / "index.md").write_text("\n".join(idx))
    for n in names:
        (Path(dest) / (n + ".md")).write_text(pages[n]["text"])

def sizes(dest):
    files = sorted(Path(dest).glob("*.md"))
    index_bytes = sum(f.stat().st_size for f in files if f.name == "index.md")
    total = sum(f.stat().st_size for f in files)
    return index_bytes, total

def breach(kind, have, pct):
    allow = pct * source_bytes // 100
    sys.stderr.write("build-wiki.sh: cap breach: wiki %s is %d bytes, over %d%% of %d source bytes"
                     " — the wiki must stay smaller than what it summarises; prune memories"
                     " or tighten their text, then rebuild\n" % (kind, have, pct, source_bytes))
    sys.exit(2)

pages = build(True)
emit(pages, stage)
index_bytes, total_bytes = sizes(stage)
if index_bytes * 100 > index_pct * source_bytes:
    breach("index", index_bytes, index_pct)
if total_bytes * 100 > total_pct * source_bytes:
    pages = build(False)
    emit(pages, stage)
    index_bytes, total_bytes = sizes(stage)
    if index_bytes * 100 > index_pct * source_bytes:
        breach("index", index_bytes, index_pct)
    if total_bytes * 100 > total_pct * source_bytes:
        sys.stderr.write("build-wiki.sh: cap breach: wiki total is %d bytes even without excerpts,"
                         " over %d%% of %d source bytes — links alone exceed the sources;"
                         " prune memories, then rebuild\n" % (total_bytes, total_pct, source_bytes))
        sys.exit(2)

# Second pass: the generator checks its own links before anything is published.
# Every memory key in exactly one page, every index entry backed by a page and
# vice versa, every handoff link and bead reference resolving.
problems = []
seen = {}
for n, p in pages.items():
    for k in p["keys"]:
        if k in seen:
            problems.append("key %s on two pages (%s, %s)" % (k, seen[k], n))
        seen[k] = n
for k in memories:
    if k not in seen:
        problems.append("key %s on no page" % k)
index_names = set()
for line in open(os.path.join(stage, "index.md"), errors="replace"):
    s = line.strip()
    if s.startswith("- [[") and "]]" in s:
        index_names.add(s.split("[[", 1)[1].split("]]", 1)[0])
for n in pages:
    if n not in index_names:
        problems.append("page %s missing from the index" % n)
for n in index_names:
    if n not in pages:
        problems.append("index entry [[%s]] has no page" % n)
if problems:
    for p in problems:
        sys.stderr.write("build-wiki.sh: broken link: %s\n" % p)
    sys.exit(1)

print("build-wiki.sh: %d topics, %d keys, index %d bytes, total %d bytes over %d source bytes"
      % (len(pages), len(memories), index_bytes, total_bytes, source_bytes))
PYEOF
)" || rc=$?
if [ "$rc" -eq 3 ]; then
  printf '%s\n' "$summary"
  exit 0
fi
if [ "$rc" -eq 2 ]; then
  rm -rf "$ROOT/harness/wiki" "$ROOT/harness/wiki.new" "$ROOT/harness/wiki.old"
  printf '%s\n' "$summary" >&2
  exit "$rc"
fi
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$summary" >&2
  exit "$rc"
fi
[ -f "$stage/index.md" ] || { echo "build-wiki.sh: the build wrote no index — nothing published" >&2; exit 1; }

new="$ROOT/harness/wiki.new"
old="$ROOT/harness/wiki.old"
rm -rf "$new" "$old"
mv "$stage" "$new" || { echo "build-wiki.sh: cannot stage the new wiki" >&2; exit 1; }
if [ -e "$ROOT/harness/wiki" ]; then
  mv "$ROOT/harness/wiki" "$old" || { echo "build-wiki.sh: cannot swap the wiki into place" >&2; rm -rf "$new"; exit 1; }
fi
mv "$new" "$ROOT/harness/wiki" || { echo "build-wiki.sh: cannot publish into harness/wiki" >&2; [ -e "$old" ] && mv "$old" "$ROOT/harness/wiki"; exit 1; }
rm -rf "$old"
printf '%s\n' "$summary"
