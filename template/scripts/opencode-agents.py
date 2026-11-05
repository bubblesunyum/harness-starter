#!/usr/bin/env python3
"""Regenerates .opencode/agent/*.md from .claude/agents/*.md, and pins opencode.json.

    scripts/opencode-agents.py          # write agents and pin opencode.json pins
    scripts/opencode-agents.py check    # exit 1 if any agent is stale, write nothing

One prompt, two frontmatter dialects. The prompt body is the expensive part and
there is exactly one copy of it, in .claude/agents/; this translates the header
around it into the shape opencode accepts and writes the result beside it.

The same run merge-writes the model pins in opencode.json and
template/opencode.json from OPENCODE_MODEL and OPENCODE_VARIANT in
scripts/models.py: top-level model, small_model, and every agent/mode entry.
Unknown user keys (permissions, instructions, extra settings) are kept;
only the pin fields are set. A hand edit that names another model is
restored by re-running this script. scripts/opencode-pin.py stays the gate
that holds every file to the pin.

**Not a symlink, and that is the whole point.** opencode reads a symlinked
.claude/agents/ file happily and then mis-parses every field in it: Claude's
`model: haiku` becomes provider "haiku" with an empty model id, the comma-string
`tools:` resolves to invalid, and `mode: all` puts each reviewer in the primary
agent picker. It looks installed and fails at spawn, which is the worst place to
find out.

Every generated agent carries `model: OPENCODE_MODEL#OPENCODE_VARIANT` from
scripts/models.py — the one model opencode runs on. Claude's tier names
(haiku, sonnet) are aliases opencode doesn't resolve, so the source's own
`model:` line is never translated.

Run after editing any .claude/agents/*.md. The gate checks it, so a forgotten
run fails loudly rather than leaving opencode with last week's reviewer.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLAUDE_AGENTS = ROOT / ".claude/agents"
OPENCODE_AGENTS = ROOT / ".opencode/agent"
OPENCODE_JSON = ROOT / "opencode.json"
TEMPLATE_JSON = ROOT / "template/opencode.json"

sys.path.insert(0, str(Path(__file__).resolve().parent))
from models import OPENCODE_MODEL, OPENCODE_MODEL_ARG, OPENCODE_VARIANT, model_is_pinned

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
    header.append(f"model: {OPENCODE_MODEL_ARG}")
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


# Config subtrees that hold agent definitions — the same three the pin check
# holds to the pin. Provider blocks are skipped: their `models` maps declare
# what exists.
PIN_GROUPS = ("agent", "agents", "mode")
# The stock agents a fresh opencode.json carries. Only used when creating a
# missing root file; existing files keep whatever agents they already list.
DEFAULT_AGENTS = ("build", "plan", "general", "explore", "title", "summary",
                  "compaction")


def pin_tree(tree):
    """Set the pin fields in an opencode.json tree, keeping every other key.
    Returns True when something changed. Only pin fields are touched: an
    agent entry with neither a model nor a variant inherits the pinned
    session model and is left alone. An explicit null variant is pinned up —
    the gate reads a present variant that isn't the pin as a problem."""
    changed = False
    if tree.get("model") is None or not model_is_pinned(tree.get("model")):
        tree["model"] = OPENCODE_MODEL_ARG
        changed = True
    small = tree.get("small_model")
    if small is None:
        tree["small_model"] = OPENCODE_MODEL
        changed = True
    elif str(small).partition("#")[0] != OPENCODE_MODEL:
        tree["small_model"] = OPENCODE_MODEL
        changed = True
    for group in PIN_GROUPS:
        agents = tree.get(group)
        if not isinstance(agents, dict):
            continue
        for name, settings in agents.items():
            if not isinstance(settings, dict):
                agents[name] = {"model": OPENCODE_MODEL,
                                "variant": OPENCODE_VARIANT}
                changed = True
            elif "model" in settings:
                if not model_is_pinned(settings.get("model"),
                                       settings.get("variant")):
                    settings["model"] = OPENCODE_MODEL
                    settings["variant"] = OPENCODE_VARIANT
                    changed = True
            elif "variant" in settings and settings["variant"] != OPENCODE_VARIANT:
                settings["variant"] = OPENCODE_VARIANT
                changed = True
    return changed


def fresh_tree():
    """The minimal root opencode.json: pins plus the stock agents. Used only
    when the root file is missing; the template copy is never created here."""
    return {
        "$schema": "https://opencode.ai/config.json",
        "model": OPENCODE_MODEL_ARG,
        "small_model": OPENCODE_MODEL,
        "agent": {name: {"model": OPENCODE_MODEL,
                         "variant": OPENCODE_VARIANT}
                  for name in DEFAULT_AGENTS},
        "instructions": ["AGENTS.md", "CLAUDE.md"],
    }


def pin_file(path):
    """Merge-write the pins into one opencode.json, keeping user keys.
    Returns True when the file was written. Missing template copies are
    skipped (an installed project has no template dir); a missing root file
    is created. Unreadable files are reported, never overwritten."""
    if not path.exists():
        if path != OPENCODE_JSON:
            return False
        path.write_text(json.dumps(fresh_tree(), indent=2) + "\n")
        print(f"  pinned {path.relative_to(ROOT)} — created missing, "
              f"on {OPENCODE_MODEL_ARG}")
        return True
    try:
        tree = json.loads(path.read_text())
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        print(f"  PIN {path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}: "
              f"unreadable ({exc}) — left alone for the pin check",
              file=sys.stderr)
        return False
    if not isinstance(tree, dict):
        print(f"  PIN {path}: not a JSON object — left alone for the pin check",
              file=sys.stderr)
        return False
    if not pin_tree(tree):
        return False
    path.write_text(json.dumps(tree, indent=2) + "\n")
    try:
        rel = path.relative_to(ROOT)
    except ValueError:
        rel = path
    print(f"  pinned {rel} to {OPENCODE_MODEL_ARG}")
    return True


def pin_opencode_jsons():
    """Pin the root and template opencode.json files. Skips whatever is not
    there (installed projects have no template dir)."""
    for path in (OPENCODE_JSON, TEMPLATE_JSON):
        try:
            pin_file(path)
        except OSError as exc:
            print(f"  PIN {path}: cannot write ({exc})", file=sys.stderr)
    return 0


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
          f"{OPENCODE_AGENTS.relative_to(ROOT)}/, pinned to {OPENCODE_MODEL_ARG}")
    return pin_opencode_jsons()


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
