#!/usr/bin/env python3
"""Fails when anything here would run opencode on a model other than the pin.

    scripts/opencode-pin.py check          # this checkout
    scripts/opencode-pin.py check <root>   # another tree — the planted tests use it

opencode runs on OPENCODE_MODEL at OPENCODE_VARIANT (scripts/models.py) and
nothing else. This holds every place a model could be chosen to that:

  harness/models.json    every entry names the pin (absent is fine: it applies anyway)
  .opencode/agent{,s}/   every `model:` line is the pin; generated ones must have one
  ~/.config/opencode/agent{,s}/, ~/.opencode/agent{,s}/   same — a machine-wide
                         agent can still name another, so user dirs fail too
  opencode.json          pins the session model; no agent or mode names another
  scripts/               no opencode -m built from anything but OPENCODE_MODEL_ARG
  skills and docs        no `opencode ... -m <id>` example naming another model

The prose rule came first and failed: a session with no terminal hand-wrote a
roster of paid models and nothing checked it (bloomerang-mcp, 2026-11-03).
Reported, never fixed: `scripts/models.py ensure` and
`scripts/opencode-agents.py` rewrite what they own; anything else is a person's
edit and gets a person's attention.
"""

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from models import (OPENCODE_MODEL, OPENCODE_MODEL_ARG, OPENCODE_VARIANT,
                    model_is_pinned, pin_problem)

GENERATED_BY = "scripts/opencode-agents.py"
CONFIGS = ("opencode.json", "opencode.jsonc",
           ".opencode/opencode.json", ".opencode/opencode.jsonc")
# Config subtrees that hold agent definitions — where a `model` key picks what
# runs. Provider blocks are skipped: their `models` maps declare what exists.
AGENT_KEYS = ("agent", "agents", "mode")
DOC_GLOBS = ("AGENTS.md", "AGENTS.local.md", "CLAUDE.md", "README.md",
             ".claude/HARNESS.md", ".claude/skills/**/*.md",
             ".agents/skills/**/*.md", "harness/*.md")
DOC_MODEL_FLAG = re.compile(r"\bopencode\b[^\n]*?\s(?:-m|--model)[ =]+([^\s`'\"]+)")
SHELL_MODEL_FLAG = re.compile(r"\bopencode\b.*\s(?:-m|--model|--variant)\b")


def strip_jsonc(text):
    """JSONC to JSON: // and /* */ comments and trailing commas removed, with
    string contents left alone — a URL's // is not a comment."""
    out, i, n = [], 0, len(text)
    while i < n:
        char = text[i]
        if char == '"':
            end = i + 1
            while end < n and text[end] != '"':
                end += 2 if text[end] == "\\" else 1
            out.append(text[i:end + 1])
            i = end + 1
        elif text.startswith("//", i):
            i = text.find("\n", i)
            i = n if i < 0 else i
        elif text.startswith("/*", i):
            i = text.find("*/", i + 2)
            i = n if i < 0 else i + 2
        else:
            out.append(char)
            i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def read_jsonc(path):
    """JSON or JSONC — opencode accepts both under either name."""
    return json.loads(strip_jsonc(path.read_text()))


def roster_problems(root):
    roster = root / "harness/models.json"
    if not roster.exists():
        # Absent stays passing: checkouts from before the roster was tracked
        # have no file, and the pin applies without one. `harness update
        # --apply` backfills it; the gate must not fail first.
        return []
    try:
        data = json.loads(roster.read_text())
    except ValueError:
        return [f"{roster.relative_to(root)}: unreadable — run scripts/models.py ensure"]
    if not isinstance(data, dict):
        return [f"{roster.relative_to(root)}: not a JSON object — run scripts/models.py ensure"]
    return [f"{roster.relative_to(root)}: {problem}" for role, entry in sorted(data.items())
            if (problem := pin_problem(role, entry))]


def short_label(path, home):
    """~/... when the path is under home, else the full path."""
    if home is not None:
        try:
            return f"~/{path.relative_to(home)}"
        except ValueError:
            pass
    return str(path)


def user_agent_files():
    """(files, problems) for the user-level agent files opencode reads
    outside the repo. Missing dirs are clean, not errors — a machine without
    them has nothing extra to check. Unreadable dirs are problems, like
    unreadable files: silently skipping them would pass a tree that was never
    checked. HOME-based, never check-root-relative, so planted repo tests
    still pass."""
    try:
        home = Path.home()
    except Exception as exc:
        return [], [f"~: cannot locate a home directory ({exc}) — "
                    f"user agent dirs unchecked"]
    candidates = (home / ".config/opencode/agent",
                  home / ".config/opencode/agents",
                  home / ".opencode/agent",
                  home / ".opencode/agents")
    files, problems = [], []
    for directory in candidates:
        try:
            if not directory.is_dir():
                continue
        except OSError as exc:
            problems.append(f"{short_label(directory, home)}: "
                            f"unreadable ({exc})")
            continue
        try:
            files.extend(directory.glob("*.md"))
        except OSError as exc:
            problems.append(f"{short_label(directory, home)}: "
                            f"unreadable ({exc})")
    return sorted(set(files)), problems


def agent_text_problems(label, text):
    """Problems for one agent file's content. Shared by repo and user-level
    files, so both hold the same pin."""
    match = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    header = match.group(1) if match else ""
    models = re.findall(r"^model:[ \t]*(.*?)[ \t]*$", header, re.M)
    variants = re.findall(r"^variant:[ \t]*(.*?)[ \t]*$", header, re.M)
    variant = variants[0] if variants else None
    problems = []
    if not models:
        if GENERATED_BY in text:
            problems.append(f"{label}: no model line — it would inherit the "
                            f"session model; run {GENERATED_BY}")
        elif variants:
            problems.append(f"{label}: sets a variant without the pinned model")
        return problems
    for model in models:
        if not model_is_pinned(model, variant):
            problems.append(f"{label}: model {model!r} — must be {OPENCODE_MODEL_ARG}")
    return problems


def agent_file_problems(root):
    problems = []
    # opencode reads agent definitions from both spellings of the directory.
    paths = sorted({*(root / ".opencode/agent").glob("*.md"),
                    *(root / ".opencode/agents").glob("*.md")})
    seen = set(paths)
    for path in paths:
        try:
            text = path.read_text()
        except (OSError, UnicodeDecodeError) as exc:
            problems.append(f"{path.relative_to(root)}: unreadable ({exc})")
            continue
        problems += agent_text_problems(path.relative_to(root), text)
    try:
        home = Path.home()
    except Exception:
        home = None
    user_files, user_problems = user_agent_files()
    problems += user_problems
    for path in user_files:
        if path in seen:
            continue
        label = short_label(path, home)
        try:
            text = path.read_text()
        except (OSError, UnicodeDecodeError) as exc:
            problems.append(f"{label}: unreadable ({exc})")
            continue
        problems += agent_text_problems(label, text)
    return problems


def config_agent_problems(rel, tree):
    problems = []
    for group in AGENT_KEYS:
        agents = tree.get(group)
        if not isinstance(agents, dict):
            continue
        for name, settings in sorted(agents.items()):
            if not isinstance(settings, dict):
                continue
            if "model" in settings:
                if not model_is_pinned(settings["model"], settings.get("variant")):
                    problems.append(f"{rel}: {group}.{name} runs on "
                                    f"{settings['model']!r} variant "
                                    f"{settings.get('variant')!r} — must be "
                                    f"{OPENCODE_MODEL} at {OPENCODE_VARIANT}")
            elif "variant" in settings and settings["variant"] != OPENCODE_VARIANT:
                problems.append(f"{rel}: {group}.{name} sets variant "
                                f"{settings['variant']!r} — must be {OPENCODE_VARIANT}")
    return problems


def config_problems(root):
    problems = []
    if not (root / "opencode.json").exists():
        return ["opencode.json: missing — nothing pins an opencode session's model"]
    for name in CONFIGS:
        path = root / name
        if not path.exists():
            continue
        try:
            tree = read_jsonc(path)
        except (OSError, ValueError) as exc:
            problems.append(f"{name}: unreadable ({exc})")
            continue
        if not isinstance(tree, dict):
            problems.append(f"{name}: not a JSON object")
            continue
        if name == "opencode.json" and "model" not in tree:
            problems.append(f"{name}: no top-level model — must be {OPENCODE_MODEL_ARG}")
        if "model" in tree and not model_is_pinned(tree["model"]):
            problems.append(f"{name}: model {tree['model']!r} — must be {OPENCODE_MODEL_ARG}")
        small = tree.get("small_model")
        if small is not None and str(small).partition("#")[0] != OPENCODE_MODEL:
            problems.append(f"{name}: small_model {small!r} — must be {OPENCODE_MODEL}")
        problems += config_agent_problems(name, tree)
    return problems


def script_problems(root):
    """opencode model flags in the harness scripts. Python may pass -m only
    with OPENCODE_MODEL_ARG on the same line; shell may not pass one at all,
    since it has no way to read the constant. Tests are skipped: they assert
    on argv, they don't build it."""
    problems = []
    scripts = root / "scripts"
    if not scripts.is_dir():
        return problems
    for path in sorted(scripts.rglob("*")):
        if not path.is_file() or path.name.startswith("test-") or path.name == Path(__file__).name:
            continue
        try:
            text = path.read_text()
        except (OSError, UnicodeDecodeError):
            continue
        rel = path.relative_to(root)
        python = path.suffix == ".py" or text.startswith("#!/usr/bin/env python")
        if python and "opencode" not in text:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            if python:
                if (re.search(r"""["'](?:-m|--model|--variant)["']""", line)
                        and "OPENCODE_MODEL_ARG" not in line):
                    problems.append(f"{rel}:{number}: opencode model flag not from "
                                    f"OPENCODE_MODEL_ARG — {line.strip()}")
            elif SHELL_MODEL_FLAG.search(line) and not line.lstrip().startswith("#"):
                problems.append(f"{rel}:{number}: shell passes opencode a model — "
                                f"leave it to opencode.json's pin: {line.strip()}")
    return problems


def doc_problems(root):
    problems, seen = [], set()
    for pattern in DOC_GLOBS:
        for path in sorted(root.glob(pattern)):
            if path in seen or not path.is_file():
                continue
            seen.add(path)
            for number, line in enumerate(path.read_text().splitlines(), 1):
                for value in DOC_MODEL_FLAG.findall(line):
                    if value != OPENCODE_MODEL_ARG:
                        problems.append(f"{path.relative_to(root)}:{number}: example "
                                        f"runs opencode on {value} — must be "
                                        f"{OPENCODE_MODEL_ARG}")
    return problems


def check(root):
    problems = (roster_problems(root) + agent_file_problems(root)
                + config_problems(root) + script_problems(root) + doc_problems(root))
    for problem in problems:
        print(f"  PIN   {problem}")
    if problems:
        print(f"        opencode runs only on {OPENCODE_MODEL_ARG} — "
              f"scripts/models.py ensure and {GENERATED_BY} rewrite what they own")
        return 1
    print(f"  ok    opencode pinned to {OPENCODE_MODEL_ARG}")
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] != ["check"] or len(args) > 2:
        print("usage: scripts/opencode-pin.py check [root]", file=sys.stderr)
        sys.exit(2)
    root = Path(args[1]).resolve() if len(args) == 2 else Path(__file__).resolve().parent.parent
    if not root.is_dir():
        print(f"opencode-pin.py: {root} is not a directory", file=sys.stderr)
        sys.exit(2)
    sys.exit(check(root))
