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
the file. Each distinct pick is probed first with a trivial run: a candidate
that can't run here — a bad id, a hosted model whose region isn't enabled —
fails at prompt time with opencode's own error, and the pick is retried;
picking it again keeps it on trust. Present,
the roster stays silent — including when there is no terminal, where prompting
would hang a hook or a gate.

Roles cover more than reviewers: the librarian audits monthly, and future
implement/summarize roles resolve through this same file.

A role's packet budget is its explicit "context" (tokens), else the limit
opencode's cached models.dev catalog lists for the model, else a heuristic
from the model id — Claude-pattern ids read as 200000, anything else as 8192.
The 8192 is deliberately conservative: a local server's allocation is
unknowable from here (ollama defaults to 4-8k unless OLLAMA_CONTEXT_LENGTH
says otherwise), and refusing early beats handing a reviewer a packet it can
only read part of. A wrong budget is fixed by writing the real one into the
roster; `budget` never prompts, so review.sh can call it from hooks and gates.

A role may also name a "variant" — the provider's reasoning effort (minimal,
low, medium, high, xhigh, max; which exist depends on the model, and
opencode's models.dev cache lists them). It reaches opencode through agent.py
as `-m provider/model#variant`, and through the generated agent files as the
`#variant` suffix on their `model:` line. Absent, the model's own default
applies. The ensure probe doesn't cover it:
it sends a bare -m, so a variant problem surfaces at runtime, not at prompt
time.
"""

import json
import os
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


def opencode_bin():
    """The opencode CLI: $OPENCODE_BIN, then PATH, then the official
    installer's ~/.opencode/bin. The installer puts that directory on PATH
    only in ~/.zshrc, which the non-interactive shells agents run in (the
    Claude Code desktop app, Codex) never source, so PATH alone misses a
    working install. Falls back to the bare name, so a missing CLI still
    surfaces as FileNotFoundError at the call site."""
    explicit = os.environ.get("OPENCODE_BIN")
    if explicit:
        return explicit
    found = shutil.which("opencode")
    if found:
        return found
    installed = Path.home() / ".opencode/bin/opencode"
    return str(installed) if os.access(installed, os.X_OK) else "opencode"


# Long enough for a cold hosted model to answer two words; short enough that
# a dead candidate fails fast at prompt time rather than hanging the setup.
PROBE_TIMEOUT_SECONDS = 120

PROBE_PROMPT = "Reply with the word ok and nothing else."


def probe_error(stdout, returncode, stderr):
    """The failure line from `opencode run --format json` output — None when
    the run answered. Only the error is read: a probe's reply is discarded."""
    errors, texts = [], []
    for line in stdout.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        if event.get("type") == "error":
            error = event.get("error", {})
            if isinstance(error, dict):
                data = error.get("data", {})
                message = data.get("message") if isinstance(data, dict) else None
                message = (message or error.get("message")
                           or error.get("name") or str(error))
                errors.append(message)
            else:
                errors.append(str(error))
        elif event.get("type") == "text":
            part = event.get("part", {})
            text = part.get("text", "") if isinstance(part, dict) else ""
            if isinstance(text, str) and text.strip():
                texts.append(text)
    if errors:
        return errors[0]
    if returncode == 0 and texts:
        return None
    lines = (stderr or stdout).strip().splitlines()[-3:]
    detail = "with no reply" if returncode == 0 else f"exited {returncode}"
    suffix = " — " + " / ".join(t.strip() for t in lines if t.strip()) if lines else ""
    return f"opencode run {detail}{suffix}"


def probe_model(model):
    """None when a trivial run on the model answers, else the failure line.

    A dead-on-arrival candidate is caught here at prompt time, not mid-review.
    Bare -m by design: the probe certifies the model answers, nothing more.
    Variants ride on -m as model#variant at runtime, so a variant problem can't
    surface here, and the probe doesn't pretend otherwise. opencode missing is
    a backstop only — `ensure` skips probing entirely then, and says so once,
    rather than failing every pick."""
    try:
        out = subprocess.run([opencode_bin(), "run", "--standalone", "--format", "json",
                              "-m", model, "--", PROBE_PROMPT],
                             capture_output=True, text=True,
                             stdin=subprocess.DEVNULL, cwd=ROOT,
                             timeout=PROBE_TIMEOUT_SECONDS)
    except FileNotFoundError:
        return "opencode is not on PATH — cannot probe; pick again to keep on trust"
    except OSError as exc:
        return f"opencode can't be run ({exc}) — cannot probe; pick again to keep on trust"
    except subprocess.TimeoutExpired:
        return (f"no reply in {PROBE_TIMEOUT_SECONDS}s — the model may be slow "
                f"rather than dead; picking it again keeps it anyway")
    return probe_error(out.stdout, out.returncode, out.stderr)


def detect():
    """(candidates, backends): model ids offerable for roster roles,
    and a one-line account of where they came from."""
    seen, backends = [], []
    opencode = [l.strip() for l in run(opencode_bin(), "models").splitlines()
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


def catalog_entry(model):
    """The models.dev catalog entry for `model` (provider/name), or None when
    opencode's cache has no such entry. opencode 2 dropped `models --verbose`;
    this cache is what's left to ask."""
    provider, _, name = model.partition("/")
    if not name:
        return None
    cache = (Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
             / "opencode/models.json")
    try:
        entry = json.loads(cache.read_text())[provider]["models"][name]
    except (OSError, ValueError, KeyError, TypeError):
        return None
    return entry if isinstance(entry, dict) else None


def is_free_tier(model):
    """Whether `model` looks like a free-tier id. Free-tier models refuse every
    custom agent (all reviewers, the librarian) — but the ensure probe runs
    without --agent, which is exactly what they refuse, so the probe can't
    catch them and the roster has to avoid them by name."""
    return "free" in model.lower()


def catalog_context(model):
    """The context limit opencode's cached models.dev catalog lists for `model`,
    or None when the cache has no entry. Keeps review.sh's packet budget honest
    for hosted models whose limits dwarf the local-server fallback below —
    without it every non-Claude id reads as 8192."""
    entry = catalog_entry(model)
    if entry is None:
        return None
    limit = entry.get("limit", {})
    context = limit.get("context") if isinstance(limit, dict) else None
    if isinstance(context, bool) or not isinstance(context, int):
        return None
    return context if context > 0 else None


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
    cached = catalog_context(model)
    if cached:
        return cached
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


def prompt_choice(role, hint, candidates, default):
    """A model id for the role from the terminal, or "" to leave it unset.
    One branch for the first pick and every re-pick: the prompt names both
    the situation and the empty escape, so neither call site rewords it."""
    if candidates:
        choice = ask(role, hint, candidates, default)
        return choice, choice
    try:
        choice = input(f"\n{role} ({hint}) — no backends detected, type a "
                       f"model id (empty leaves it unset): ").strip()
    except EOFError:
        choice = ""
    return choice, default


def probe_choice(role, hint, choice, candidates, default, probed, failed):
    """A model id for the role that either probed clean or was re-picked after
    a failed probe — or "" when the role is left unset. Returns the choice and
    the default, which chains like `ensure`'s: a re-pick becomes the next
    role's default."""
    while choice and choice not in probed:
        if choice in failed:
            # Failed once and explicitly re-picked: theirs, on trust — and
            # trusted for the roles below that inherit it.
            print(f"  keeping {choice} despite the failed probe — on trust.")
            probed.add(choice)
            break
        error = probe_model(choice)
        if error is None:
            probed.add(choice)
            break
        failed.add(choice)
        print(f"  ! probe of {choice} failed: {error}")
        print("    pick another model, or the same one to keep it anyway.")
        choice, default = prompt_choice(role, hint, candidates, default)
    return choice, default


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
    can_probe = shutil.which(opencode_bin()) is not None
    if not can_probe:
        print("no opencode on PATH — writing choices without probing them.")
    probed = set()  # models already seen answering
    failed = set()   # models already failed; picking one again keeps it
    roster, default = {}, None
    for role, hint in ROLES.items():
        if candidates:
            if default is None:
                # Free-tier ids refuse every custom agent (all reviewers, the
                # librarian), so defaulting to one writes a roster that fails
                # at review time. Default to paid; free stays pickable by number.
                default = next((c for c in candidates if not is_free_tier(c)),
                               candidates[0])
        choice, default = prompt_choice(role, hint, candidates, default)
        if not choice:
            print("left unset; re-run with --again to fill it in.")
            continue
        kept = previous.get(role)
        if can_probe:
            choice, default = probe_choice(role, hint, choice, candidates,
                                           default, probed, failed)
        if not choice:
            print("left unset; re-run with --again to fill it in.")
            continue
        if is_free_tier(choice) and role != "implement":
            # The probe can't catch this: it runs without --agent, which is
            # exactly what free-tier ids refuse.
            print(f"  ! {choice} looks free-tier, and free-tier models refuse "
                  f"every custom agent — {role} will fail at review time.")
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
