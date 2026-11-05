#!/usr/bin/env python3
"""The one model opencode runs on, and the per-role roster that records it.

    scripts/models.py ensure          # write harness/models.json, pinned
    scripts/models.py ensure --again  # rewrite it even when it's already pinned
    scripts/models.py get <role>      # print the model id a role runs on
    scripts/models.py budget <role>   # print one role's packet budget in tokens

**opencode runs on OPENCODE_MODEL at OPENCODE_VARIANT, and nothing else.**
Every role, every path: agent.py's `opencode run -m`, the generated
.opencode/agent/*.md `model:` lines, opencode.json's pin, and the ensure probe
all read the two constants below. No flag, environment variable, or roster
entry changes them. A roster naming anything else is refused, not quietly
overridden — the incident that put this here (bloomerang-mcp, 2026-11-03) was
a hand-written roster of paid models nothing checked, which spawned ~15
sessions and exhausted the provider's limit. scripts/opencode-pin.py is the
gate step that holds every file to this.

harness/models.json is machine-local and gitignored. It no longer chooses
anything: it records the pin per role, plus an optional "context" (tokens)
that overrides the packet budget. `ensure` writes it without prompting — the
Claude Code desktop app and every hook run without a terminal, and a setup
step that needs one is a setup step that gets skipped and hand-written. A
roster carrying a foreign model or variant is rewritten by `ensure`, which
names what it replaced; every other reader refuses it.

A role's packet budget is its explicit "context", else the limit opencode's
cached models.dev catalog lists for the pinned model, else OPENCODE_CONTEXT —
the pin's window as the catalog listed it when the pin was set, so a machine
whose opencode never cached the catalog (or has no opencode at all) doesn't
refuse every ordinary packet. `budget` never prompts, so review.sh can call
it from hooks and gates.
"""

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ROSTER = ROOT / "harness/models.json"

# The policy. The only definition of the model and variant in the harness —
# change it here or nowhere, and the gate re-checks every file against it.
OPENCODE_MODEL = "opencode-go/muse-spark-1.3-contributor"
OPENCODE_VARIANT = "xhigh"
# opencode 2 takes the variant on -m as provider/model#variant.
OPENCODE_MODEL_ARG = f"{OPENCODE_MODEL}#{OPENCODE_VARIANT}"
# The pin's context window in tokens, per models.dev on 2026-11-03 — the
# budget fallback when opencode's catalog cache has no entry. Move it with
# the pin.
OPENCODE_CONTEXT = 1048576

ROLES = (
    "reviewer-taste",
    "reviewer-correctness",
    "reviewer-design",
    "librarian",
    "implement",
    "summarize",
)


class ForeignModel(Exception):
    """A roster entry names a model or variant other than the pin."""


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
# a dead pin fails fast at setup rather than hanging it.
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


def probe_pinned():
    """None when a trivial run on the pinned model answers, else the failure
    line. `ensure` runs it in a terminal only: it costs a provider call, and a
    hook paying that on every fresh clone is how small costs compound."""
    try:
        out = subprocess.run([opencode_bin(), "run", "--standalone", "--format", "json",
                              "-m", OPENCODE_MODEL_ARG, "--", PROBE_PROMPT],
                             capture_output=True, text=True,
                             stdin=subprocess.DEVNULL, cwd=ROOT,
                             timeout=PROBE_TIMEOUT_SECONDS)
    except FileNotFoundError:
        return "opencode is not on PATH — cannot probe"
    except OSError as exc:
        return f"opencode can't be run ({exc}) — cannot probe"
    except subprocess.TimeoutExpired:
        return (f"no reply in {PROBE_TIMEOUT_SECONDS}s — the model may be slow "
                f"rather than dead")
    return probe_error(out.stdout, out.returncode, out.stderr)


def load():
    try:
        data = json.loads(ROSTER.read_text())
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def pin_problem(role, entry):
    """Why a roster entry breaks the pin, or None when it holds it. A missing
    model or variant counts: an entry that doesn't state the pin can't be told
    apart from one somebody meant to change."""
    if not isinstance(entry, dict):
        return (f"harness/models.json gives {role} {entry!r}, not an entry; "
                f"opencode runs only on {OPENCODE_MODEL} at {OPENCODE_VARIANT}")
    model, variant = entry.get("model"), entry.get("variant")
    if model == OPENCODE_MODEL and variant == OPENCODE_VARIANT:
        return None
    return (f"harness/models.json gives {role} model {model!r} variant "
            f"{variant!r}; opencode runs only on {OPENCODE_MODEL} at "
            f"{OPENCODE_VARIANT}")


def model_is_pinned(value, variant=None):
    """Whether a config `model` value (string or {providerID, model, variant})
    plus a sibling `variant`, if any, lands on the pin. Shared by the
    opencode-pin.py gate and the opencode-agents.py merge-writer, so the two
    agree on what counts as pinned."""
    if isinstance(value, dict):
        provider, name = value.get("providerID"), value.get("model")
        model = f"{provider}/{name}" if provider and name else None
        variant = value.get("variant", variant)
    else:
        model, _, suffix = str(value).partition("#")
        variant = suffix or variant
    return model == OPENCODE_MODEL and variant == OPENCODE_VARIANT


def foreign_entries():
    """{role: problem} for every roster entry that breaks the pin."""
    problems = {}
    for role, entry in load().items():
        problem = pin_problem(role, entry)
        if problem:
            problems[role] = problem
    return problems


def roster_state():
    """missing | invalid | foreign | partial | ok. Anything but ok is what
    `ensure` rewrites; callers that only report use it to say which."""
    if not ROSTER.exists():
        return "missing"
    try:
        data = json.loads(ROSTER.read_text())
    except Exception:
        return "invalid"
    if not isinstance(data, dict):
        return "invalid"
    if foreign_entries():
        return "foreign"
    return "ok" if all(role in data for role in ROLES) else "partial"


def require_pinned(role):
    """Raise ForeignModel when the roster gives `role` anything but the pin.
    An absent roster or entry passes — the pin applies without one."""
    entry = load().get(role)
    if entry is not None:
        problem = pin_problem(role, entry)
        if problem:
            raise ForeignModel(problem + " — run scripts/models.py ensure "
                               "to rewrite the roster pinned")


def model_for(role):
    """The model a role runs on: always the pin. Raises ForeignModel rather
    than override a roster that says otherwise, so the drift gets fixed."""
    require_pinned(role)
    return OPENCODE_MODEL


def variant_for(role):
    """The variant a role runs at: always the pin, on the same terms."""
    require_pinned(role)
    return OPENCODE_VARIANT


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


def catalog_context(model):
    """The context limit opencode's cached models.dev catalog lists for `model`,
    or None when the cache has no entry."""
    entry = catalog_entry(model)
    if entry is None:
        return None
    limit = entry.get("limit", {})
    context = limit.get("context") if isinstance(limit, dict) else None
    if isinstance(context, bool) or not isinstance(context, int):
        return None
    return context if context > 0 else None


def explicit_context(entry):
    """A roster entry's "context" as a positive int, or None. Misshapen values
    fall through to the catalog, like every other tolerant read here."""
    if not isinstance(entry, dict):
        return None
    context = entry.get("context")
    # bool subclasses int, so `true` would otherwise read as a 1-token budget.
    if isinstance(context, bool):
        return None
    if isinstance(context, int) and context > 0:
        return context
    if isinstance(context, float) and context.is_integer() and context > 0:
        return int(context)
    if isinstance(context, str) and context.isdigit() and int(context) > 0:
        return int(context)
    return None


def budget_for(role):
    """The packet budget in tokens for a role, or 0 for a role the harness
    doesn't know. Raises ForeignModel like model_for. Never prompts."""
    entry = load().get(role)
    if role not in ROLES and entry is None:
        return 0
    model = model_for(role)
    return explicit_context(entry) or catalog_context(model) or OPENCODE_CONTEXT


def pinned_roster(previous):
    """Every harness role, plus any extra role the previous roster carried,
    pinned. An entry's "context" is kept only when it was measured for the
    pinned model: a 16k budget from a local model would refuse every packet
    the pin's 1M window reads whole."""
    roster = {}
    for role in sorted(set(ROLES) | set(previous)):
        entry = {"model": OPENCODE_MODEL, "variant": OPENCODE_VARIANT}
        kept = previous.get(role)
        same_model = isinstance(kept, dict) and kept.get("model") == OPENCODE_MODEL
        context = explicit_context(kept) if same_model else None
        if context:
            entry["context"] = context
        roster[role] = entry
    return roster


def ensure(again=False):
    """Write the pinned roster unless it's already there. Never prompts, so it
    behaves the same in a terminal, a hook, and the desktop app."""
    state = roster_state()
    if state == "ok" and not again:
        return 0
    if state == "invalid":
        print("harness/models.json was unreadable — rewriting it pinned.",
              file=sys.stderr)
    for problem in foreign_entries().values():
        print(f"replacing a foreign roster entry: {problem}.", file=sys.stderr)
    roster = pinned_roster(load())
    ROSTER.parent.mkdir(parents=True, exist_ok=True)
    ROSTER.write_text(json.dumps(roster, indent=2, sort_keys=True) + "\n")
    print(f"wrote {len(roster)} roles → {ROSTER.relative_to(ROOT)}, all on "
          f"{OPENCODE_MODEL} at {OPENCODE_VARIANT}")
    if sys.stdin.isatty() and shutil.which(opencode_bin()):
        error = probe_pinned()
        if error:
            print(f"  ! probe of {OPENCODE_MODEL_ARG} failed: {error}\n"
                  f"    opencode roles fail until it answers — there is no "
                  f"other model to fall back to, by design.", file=sys.stderr)
    return 0


def usage():
    print(__doc__.strip().splitlines()[0], file=sys.stderr)
    print("usage: scripts/models.py ensure [--again] | get <role> | budget <role>",
          file=sys.stderr)
    sys.exit(2)


def main(args):
    if args[:1] == ["ensure"] and args[1:] in ([], ["--again"]):
        return ensure(again=bool(args[1:]))
    if len(args) != 2 or args[0] not in ("get", "budget"):
        usage()
    command, role = args
    if command == "get":
        print(model_for(role))
        return 0
    budget = budget_for(role)
    if not budget:
        print(f"no budget for '{role}' — not a harness role", file=sys.stderr)
        return 1
    print(budget)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except ForeignModel as exc:
        print(f"models.py: {exc}", file=sys.stderr)
        sys.exit(1)
