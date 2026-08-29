#!/usr/bin/env python3
"""Regenerates .opencode/agent/*.md from .claude/agents/*.md.

    scripts/opencode-agents.py          # write them
    scripts/opencode-agents.py check    # exit 1 if any is stale, write nothing

One prompt, two frontmatter dialects. The prompt body is the expensive part and
there is exactly one copy of it, in .claude/agents/; this translates the header
around it into the shape opencode accepts and writes the result beside it.

**Not a symlink, and that is the whole point.** opencode reads a symlinked
.claude/agents/ file happily and then mis-parses every field in it: Claude's
`model: haiku` becomes provider "haiku" with an empty model id, the comma-string
`tools:` resolves to invalid, and `mode: all` puts each reviewer in the primary
agent picker. It looks installed and fails at spawn, which is the worst place to
find out.

Run after editing any .claude/agents/*.md. The gate checks it, so a forgotten
run fails loudly rather than leaving opencode with last week's reviewer.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLAUDE_AGENTS = ROOT / ".claude/agents"
OPENCODE_AGENTS = ROOT / ".opencode/agent"

# Claude's `tools:` is an allowlist; opencode has no allowlist, only per-tool
# permissions. Only the tools that write or reach outside the repo are
# translated: those are the ones an omission actually costs something. The read
# family (read, grep, glob, list) is left alone — every agent here is granted
# Read, and denying an opencode key with no Claude counterpart would be
# inventing policy rather than translating it.
GUARDED = {
    "edit": ("Edit", "Write", "NotebookEdit"),
    "bash": ("Bash",),
    "webfetch": ("WebFetch",),
    "websearch": ("WebSearch",),
    "task": ("Task", "Agent"),
}

GENERATED_BY = "scripts/opencode-agents.py"


def frontmatter(text):
    """(fields, body) for a markdown file with a --- delimited header. Values
    are taken raw: every field this cares about is a single line."""
    match = re.match(r"^---\n(.*?)\n---\n(.*)$", text, re.S)
    if not match:
        return {}, text
    fields = dict(re.findall(r"^([A-Za-z_]+):[ \t]*(.*)$", match.group(1), re.M))
    return fields, match.group(2)


def translate(source):
    """The opencode agent file for one .claude/agents/*.md, as text."""
    fields, body = frontmatter(source.read_text())
    granted = {t.strip() for t in fields.get("tools", "").split(",") if t.strip()}

    header = ["---"]
    if "description" in fields:
        header.append(f"description: {fields['description']}")
    # Always subagent. `mode: all` — the value a naive translation of Claude's
    # frontmatter produces — puts every reviewer in opencode's primary agent
    # picker, beside build and plan, where nobody meant to put them.
    header.append("mode: subagent")
    # No `model:`. Claude's tier names (haiku, sonnet) are aliases opencode does
    # not have: it wants a provider-qualified id, and which provider a given
    # install has authenticated is not knowable from here. Omitted, the agent
    # inherits the session's model and always resolves. A real tier→model roster
    # is its own piece of work.
    denied = [key for key, claude_tools in sorted(GUARDED.items())
              if not granted.intersection(claude_tools)]
    if denied:
        header.append("permission:")
        header += [f"  {key}: deny" for key in denied]
    header.append("---")

    return ("\n".join(header) + "\n\n"
            + f"<!-- Generated from {source.relative_to(ROOT)} by {GENERATED_BY}.\n"
            + "     Edit that file, not this one, and re-run the script. -->\n\n"
            + body.lstrip("\n"))


def generated():
    """(destination, wanted text) for every agent."""
    return [(OPENCODE_AGENTS / source.name, translate(source))
            for source in sorted(CLAUDE_AGENTS.glob("*.md"))]


def orphans(wanted):
    """Files under .opencode/agent/ this script wrote and no longer would —
    left behind, a renamed agent haunts opencode under both names."""
    if not OPENCODE_AGENTS.is_dir():
        return []
    keep = {path for path, _ in wanted}
    return [path for path in sorted(OPENCODE_AGENTS.glob("*.md"))
            if path not in keep and GENERATED_BY in path.read_text()]


def write():
    wanted = generated()
    OPENCODE_AGENTS.mkdir(parents=True, exist_ok=True)
    for path, text in wanted:
        path.write_text(text)
    for path in orphans(wanted):
        path.unlink()
        # Named, not counted: a reviewer that vanished because its source was
        # renamed is exactly the deletion someone needs to see happen.
        print(f"  removed {path.relative_to(ROOT)} — its source is gone")
    print(f"  wrote {len(wanted)} opencode agents → "
          f"{OPENCODE_AGENTS.relative_to(ROOT)}/")


def check():
    """Reports rather than fixes: a gate that silently regenerated would pass
    every time and never tell anyone the two had drifted."""
    wanted = generated()
    stale = [path for path, text in wanted
             if not path.exists() or path.read_text() != text]
    for path in stale:
        print(f"  AGENT {path.relative_to(ROOT)} does not match "
              f"{CLAUDE_AGENTS.relative_to(ROOT)}/{path.name}")
    for path in orphans(wanted):
        stale.append(path)
        print(f"  AGENT {path.relative_to(ROOT)} has no source any more")
    if stale:
        print(f"        run {GENERATED_BY}")
        return 1
    print(f"  ok    {len(wanted)} opencode agents match their sources")
    return 0


if __name__ == "__main__":
    if not CLAUDE_AGENTS.is_dir():
        print(f"✗ no {CLAUDE_AGENTS.relative_to(ROOT)}/ — nothing to translate.",
              file=sys.stderr)
        sys.exit(1)
    sys.exit(check() if sys.argv[1:2] == ["check"] else (write() or 0))
