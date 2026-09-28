#!/usr/bin/env python3
"""Per-role model roster: which model plays which part.

    scripts/models.py ensure          # write harness/models.json if missing
    scripts/models.py ensure --again  # re-prompt even when it exists
    scripts/models.py get <role>      # print one role's model id
    scripts/models.py budget <role>   # print one role's packet budget in tokens

harness/models.json maps roles to models. It is machine-local and gitignored:
it names models this machine happens to have, which no commit should carry.
Missing on first run, `ensure` detects backends (opencode's configured
providers, `ollama list`, `claude` on PATH), prompts once per role, and writes
the file. Present, it stays silent — including when there is no terminal, where
prompting would hang a hook or a gate.

Roles cover more than reviewers: the librarian audits monthly, and future
implement/summarize roles resolve through this same file.

A role's packet budget is its explicit "context" (tokens), else a heuristic
from the model id — Claude-pattern ids read as 200000, anything else as 8192.
The 8192 is deliberately conservative: a local server's allocation is
unknowable from here (ollama defaults to 4-8k unless OLLAMA_CONTEXT_LENGTH
says otherwise), and refusing early beats handing a reviewer a packet it can
only read part of. A wrong budget is fixed by writing the real one into the
roster; `budget` never prompts, so review.sh can call it from hooks and gates.

A role may also name a "variant" — the provider's reasoning effort (minimal,
low, medium, high, xhigh, max; which exist depends on the model, and
`opencode models --verbose` lists them). It reaches opencode as agent.py's
`--variant` — the only path; no generated file carries one. Absent, the
model's own default applies.
"""

import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ROSTER = ROOT / "harness/models.json"

# role: one-line hint shown at prompt time.
ROLES = {
    "reviewer-taste": "cheap reviewer, runs on every change",
    "reviewer-correctness": "reads every packet for defects",
    "reviewer-design": "reads screenshots, not the diff",
    "librarian": "monthly knowledge-layer audit",
    "implement": "already-specced bead work",
    "summarize": "session notes and handoffs",
}


def run(*args, timeout=15):
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return out.stdout if out.returncode == 0 else ""
    except Exception:
        return ""


def detect():
    """(candidates, backends): model ids offerable for roster roles,
    and a one-line account of where they came from."""
    seen, backends = [], []
    opencode = [l.strip() for l in run("opencode", "models").splitlines()
                if "/" in l.strip()]
    if opencode:
        seen += [m for m in opencode if m not in seen]
        backends.append(f"opencode ({len(opencode)} models)")
    # `opencode models` already folds in configured ollama models, but the
    # server may be down or hold ones opencode never saw — ask it directly.
    ollama = run("ollama", "list")
    names = [l.split()[0] for l in ollama.splitlines()[1:]
             if l.split() and l.split()[0] != "NAME"]
    names = [f"ollama/{n}" for n in names if f"ollama/{n}" not in seen]
    if names:
        seen += names
    if shutil.which("ollama"):
        backends.append("ollama")
    if shutil.which("claude"):
        # Noted, not offered: Claude agents keep their frontmatter tiers until
        # a future agent runner learns to resolve them through this file.
        backends.append("claude")
    return seen, backends


def load():
    try:
        data = json.loads(ROSTER.read_text())
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def load_roster():
    """role → model id, tolerant: a missing, corrupt, or misshapen roster
    reads as no models. Shared with scripts/opencode-agents.py — one parser,
    not two."""
    out = {}
    for role, entry in load().items():
        model = entry.get("model") if isinstance(entry, dict) else entry
        if isinstance(model, str) and model:
            out[role] = model
    return out


def roster_state():
    """missing | invalid | empty | ok. `ensure` treats invalid like missing;
    callers that only report use it to say which."""
    if not ROSTER.exists():
        return "missing"
    try:
        data = json.loads(ROSTER.read_text())
    except Exception:
        return "invalid"
    if not isinstance(data, dict):
        return "invalid"
    return "ok" if load_roster() else "empty"


def model_for(role):
    """The configured model id for a role, or empty when there is none."""
    return load_roster().get(role, "")


def variant_for(role):
    """The reasoning variant a role runs at, or empty for the model's default.
    Tolerant like the roster reader: anything but a non-empty string is none."""
    entry = load().get(role)
    variant = entry.get("variant") if isinstance(entry, dict) else None
    return variant.strip() if isinstance(variant, str) and variant.strip() else ""


# Fallback packet budgets, in tokens, when the roster names no explicit
# "context" for the role. Heuristic, documented as such in the docstring, and
# always overridable per role — a table here would go stale in exactly the
# direction that hands a reviewer a packet it can't read.
BUDGET_CLAUDE = 200000
BUDGET_DEFAULT = 8192


def budget_for(role):
    """The packet budget in tokens for a role, or 0 when the role has no
    model configured (unknown model, unknown budget — the caller skips
    enforcement rather than guessing). Misshapen explicit values fall through
    to the heuristic, like the tolerant roster reader. Never prompts."""
    data = load()
    entry = data.get(role)
    if isinstance(entry, dict):
        context = entry.get("context")
        # bool subclasses int, so `true` would otherwise read as a 1-token budget.
        if isinstance(context, bool):
            pass
        elif isinstance(context, int) and context > 0:
            return context
        elif isinstance(context, float) and context.is_integer() and context > 0:
            return int(context)
        elif isinstance(context, str) and context.isdigit() and int(context) > 0:
            return int(context)
    model = model_for(role)
    if not model:
        return 0
    lowered = model.lower()
    if any(k in lowered for k in ("claude", "anthropic", "sonnet", "opus")):
        return BUDGET_CLAUDE
    return BUDGET_DEFAULT


def ask(role, hint, candidates, default):
    print(f"\n{role} ({hint}):")
    for i, cand in enumerate(candidates, 1):
        print(f"  {i}) {cand}")
    while True:
        try:
            raw = input(f"  pick [default {default}]: ").strip()
        except EOFError:
            return default
        if not raw:
            return default
        if raw.isdigit() and 1 <= int(raw) <= len(candidates):
            return candidates[int(raw) - 1]
        if raw:
            # A model id from elsewhere, taken on trust — detection only knows
            # the backends on this machine, not every valid id.
            return raw


def ensure(again=False):
    state = roster_state()
    if state == "ok" and not again:
        return 0
    candidates, backends = detect()
    if not sys.stdin.isatty():
        if state == "invalid":
            print("harness/models.json is corrupt — run "
                  "scripts/models.py ensure --again in a terminal to rewrite "
                  "it; continuing without per-role models.", file=sys.stderr)
        else:
            print("no harness/models.json and no terminal — run "
                  "scripts/models.py ensure in a terminal, then re-run; "
                  "continuing without per-role models.", file=sys.stderr)
        return 0
    print("per-role models, stored machine-locally in harness/models.json.")
    if backends:
        print("backends seen: " + ", ".join(backends))
    # What `ensure` doesn't ask about — context, variant — is kept from the
    # entry it replaces: re-picking one model shouldn't reset every role's
    # budget and reasoning effort without a word.
    previous = load() if state in ("ok", "empty") else {}
    roster, default = {}, None
    for role, hint in ROLES.items():
        if candidates:
            if default is None:
                # The cheap reviewer defaults cheap: first free id, else first.
                default = next((c for c in candidates if "free" in c),
                               candidates[0])
            choice = ask(role, hint, candidates, default)
            default = choice
        else:
            try:
                choice = input(f"\n{role} ({hint}) — no backends detected, "
                               f"type a model id: ").strip()
            except EOFError:
                choice = ""
            if not choice:
                print("left unset; re-run with --again to fill it in.")
                continue
        kept = previous.get(role)
        roster[role] = {**(kept if isinstance(kept, dict) else {}), "model": choice}
    ROSTER.parent.mkdir(parents=True, exist_ok=True)
    ROSTER.write_text(json.dumps(roster, indent=2, sort_keys=True) + "\n")
    print(f"\nwrote {len(roster)} roles → {ROSTER.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["get"] and len(args) == 2:
        model = model_for(args[1])
        if model:
            print(model)
        else:
            print(f"no model for '{args[1]}' — run scripts/models.py ensure",
                  file=sys.stderr)
            sys.exit(1)
    elif args[:1] == ["budget"] and len(args) == 2:
        budget = budget_for(args[1])
        if budget:
            print(budget)
        else:
            print(f"no budget for '{args[1]}' — no model configured; "
                  f"run scripts/models.py ensure", file=sys.stderr)
            sys.exit(1)
    elif args[:1] == ["ensure"]:
        sys.exit(ensure(again=(args[1:2] == ["--again"])))
    else:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        print("usage: scripts/models.py ensure [--again] | get <role> | budget <role>",
              file=sys.stderr)
        sys.exit(2)
