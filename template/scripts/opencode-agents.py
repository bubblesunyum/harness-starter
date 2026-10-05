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

sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    from models import load_roster as load_roster_from_models, variant_for
except ImportError:
    def load_roster_from_models():
        return {}

    def variant_for(role):
        return ""

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


def translate(source, roster=None):
    """The opencode agent file for one .claude/agents/*.md, as text.

    The roster is baked in: a role with a roster entry gets a
    `model: provider/model#variant` line (bare model when no variant), so a
    native opencode spawn runs the role's effort rather than inheriting the
    session's. A role with no roster entry gets no model line and inherits —
    which is also what a fresh clone without harness/models.json generates,
    and why check fails there with guidance instead of silently passing.
    Claude's tier names (haiku, sonnet) are aliases opencode does not resolve
    anyway — and codex-support.py likewise never translates a model line."""
    fields, body = frontmatter(source.read_text())
    granted = {t.strip() for t in fields.get("tools", "").split(",") if t.strip()}

    header = ["---"]
    if "description" in fields:
        header.append(f"description: {fields['description']}")
    model_line = roster_model(source.stem, roster or {})
    if model_line:
        header.append(f"model: {model_line}")
    # Always subagent. `mode: all` — the value a naive translation of Claude's
    # frontmatter produces — puts every reviewer in opencode's primary agent
    # picker, beside build and plan, where nobody meant to put them.
    header.append("mode: subagent")
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


def load_roster():
    """role → `model` or `model#variant`, read through models.py — one parser,
    not two. Anything models.py finds unusable reads as empty, and the callers
    turn that into guidance rather than a traceback."""
    try:
        models = load_roster_from_models()
    except Exception:
        return {}
    if not isinstance(models, dict):
        return {}
    out = {}
    for role, model in models.items():
        if not isinstance(model, str) or not model:
            continue
        try:
            variant = variant_for(role)
        except Exception:
            variant = ""
        out[role] = f"{model}#{variant}" if variant else model
    return out


def roster_model(role, roster):
    """The `model:` line value for a role, or empty when the roster names none."""
    value = roster.get(role, "")
    return value if isinstance(value, str) and value else ""


def missing_roles(roster):
    """Agent stems the roster names nothing for — they inherit the session model."""
    return sorted(s.stem for s in CLAUDE_AGENTS.glob("*.md")
                  if not roster_model(s.stem, roster))


def files_with_baked_models():
    """Generated files currently carrying `model:` lines — the committed bake."""
    if not OPENCODE_AGENTS.is_dir():
        return []
    found = []
    for path in sorted(OPENCODE_AGENTS.glob("*.md")):
        try:
            text = path.read_text()
        except OSError:
            continue
        if GENERATED_BY in text and re.search(r"^model:\s*\S", text, re.M):
            found.append(path)
    return found


def bake_without_roster(roster):
    """Whether the tree carries a bake the empty roster cannot verify."""
    return not roster and bool(files_with_baked_models())


def no_roster_guidance(verb):
    return ("  no usable harness/models.json — run scripts/models.py ensure, "
            f"then {verb}")


def generated(roster=None):
    """(destination, wanted text) for every agent."""
    roster = load_roster() if roster is None else roster
    return [(OPENCODE_AGENTS / source.name, translate(source, roster))
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
    roster = load_roster()
    if bake_without_roster(roster):
        # A transient roster misread must never clobber the bake with
        # model-free output — that shipped once, and the gate stayed green
        # about it until a human noticed.
        print("  harness/models.json is missing or unreadable, but the generated "
              "agents carry baked models — refusing to overwrite them model-free.",
              file=sys.stderr)
        print("  " + no_roster_guidance("re-run"), file=sys.stderr)
        return 1
    for role in missing_roles(roster):
        print(f"  ! no roster entry for {role} — it inherits the session model",
              file=sys.stderr)
    wanted = generated(roster)
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
    roster = load_roster()
    if bake_without_roster(roster):
        print("  " + no_roster_guidance("scripts/opencode-agents.py"))
        return 1
    wanted = generated(roster)
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
