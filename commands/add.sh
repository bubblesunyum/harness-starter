#!/bin/bash
# install the harness into a project
#
#   harness add              into the current directory
#   harness add <path>       into that project instead
#
# Everything is inferred: the project's name and its bead prefix come from the
# directory, and an existing ledger keeps the prefix it already has. The one
# thing no script can infer is who the seat is — that's the agent's to choose,
# and it's the first thing the closing instructions ask for.
#
# Never overwrites a file that already exists in the target, and prints what it
# skipped, so a re-run is a safe way to pick up pieces added since. The one place
# it refuses to be quiet is a file carrying the harness contract that exists and
# differs — there, a skip means the fix never arrived. `harness update` is the
# same check on its own, for a project that isn't being re-added to.
set -euo pipefail

# Derived from this file's own location, never from the environment. The
# dispatcher execs an already-resolved absolute path, so this is correct there
# too — and a command that took its root from an exported variable would install
# a different checkout's template whenever a stale one was lying around, with no
# error and no sign that it had happened.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMPLATE="$HERE/template"
# Everything `add` and `update` have to agree on lives here.
# shellcheck source=lib/install.sh
. "$HERE/commands/lib/install.sh"

# Spelled out rather than sed'd off the comment block above: BSD sed has no
# `\?`, so the version that did that shipped the leading `#` of every line.
usage() {
  cat <<EOF
Installs the agentic development harness into a project.

  harness add              into the current directory
  harness add <path>       into that project instead

The project's name and its bead prefix are inferred from the directory, and a
project that already has a ledger keeps the prefix it already has. Needs a git
repository, and beads (bd) on PATH.

Never overwrites a file that already exists, so re-running is a safe way to
pick up pieces added to the starter since. Files carrying the harness contract
are warned about loudly when they exist but differ from the template — that is
the one case where skipping quietly would hide a failed install. See
'harness update' for the same check without installing anything.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

target="$(harness_resolve_target "${1:-$PWD}")"
# Installing into the starter itself is allowed on purpose — that is how the
# harness gets worked on with the harness. It is not free of a trap; see
# "Working on the starter" in the README.

name="$(basename "$target")"

existing_prefix="$(harness_ledger_prefix "$target")"
prefix="$existing_prefix"
[ -n "$prefix" ] || prefix="$(harness_derive_prefix "$name")"
# What harness_current substitutes with; it is called from inside the copy loop,
# where threading two more arguments through every call buys nothing.
HARNESS_NAME="$name"
HARNESS_PREFIX="$prefix"

echo "installing the harness into $target"
echo "  project: $name"
echo "  prefix:  $prefix-"
echo

files="$(harness_template_files "$HERE")"

copied=0; skipped=0; stale=0
while IFS= read -r rel; do
  src="$TEMPLATE/$rel"
  dst="$target/$rel"
  if [ -e "$dst" ]; then
    # Never overwritten — that is what makes a re-run safe. But for the files
    # carrying the harness contract, silence here is the install failing: the
    # project keeps a stale AGENTS.md, the skip line scrolls past among thirty
    # others, and nothing ever says the fix didn't arrive.
    if harness_is_contract "$rel" "$src" && ! harness_current "$rel" "$src" "$dst"; then
      echo "  ⚠ $rel exists and differs from the template"
      stale=$((stale + 1))
    else
      echo "  skip  $rel (already there)"
    fi
    skipped=$((skipped + 1))
    continue
  fi
  mkdir -p "$(dirname "$dst")"
  harness_render "$rel" "$src" "$name" "$prefix" > "$dst"
  [ -x "$src" ] && chmod +x "$dst"
  echo "  add   $rel"
  copied=$((copied + 1))
done <<< "$files"

echo
echo "  $copied added, $skipped skipped"
if [ "$stale" -gt 0 ]; then
  echo
  echo "  ⚠ $stale contract file(s) above are stale — the harness contract is not"
  echo "    fully installed here. Merging is yours, because this never overwrites."
  echo "    What changed:"
  echo "      harness update --diff $target"
fi
echo

# The hook logic lives in scripts/ and is pointed at, rather than copied into
# a hooks directory — beads rewrites .beads/hooks on upgrade and would eat it.
# Git runs hooks from core.hooksPath when set and ignores .git/hooks entirely,
# and `bd hooks install` sets it to .beads/hooks. Wiring only .git/hooks would
# silently stop enforcing the moment someone installs bd's hooks.
delegate='exec "$(git rev-parse --show-toplevel)"/scripts/hooks/commit-msg "$@"'
wire_hook() {
  local hook="$1"
  # Best effort: a hook that cannot be wired must never veto the install —
  # the ledger, the gitignore lines and the CLAUDE.md import matter more.
  if ! mkdir -p "$(dirname "$hook")" 2>/dev/null; then
    echo "  ! cannot write $(dirname "$hook") — add this line to its commit-msg yourself:"
    echo "      exec \"\$(git rev-parse --show-toplevel)\"/scripts/hooks/commit-msg \"\$@\""
    return 0
  fi
  if [ -e "$hook" ] && grep -qF "$delegate" "$hook"; then
    echo "  commit-msg hook already wired ($hook)"
  elif [ -e "$hook" ]; then
    # Someone else's hook. Left alone rather than merged into: it is the one file
    # here that can block every commit in the repo if it is got wrong.
    echo "  ! $hook exists — add this line to it yourself:"
    echo "      exec \"\$(git rev-parse --show-toplevel)\"/scripts/hooks/commit-msg \"\$@\""
  elif ! printf '#!/bin/bash\n%s\n' "$delegate" > "$hook" 2>/dev/null; then
    echo "  ! cannot write $hook — add this line to it yourself:"
    echo "      exec \"\$(git rev-parse --show-toplevel)\"/scripts/hooks/commit-msg \"\$@\""
  else
    chmod +x "$hook"
    echo "  wired the commit-msg hook ($hook)"
  fi
}
# Local only: a global core.hooksPath belongs to every repo on the machine,
# and a delegate pointing at this project's scripts/ would break commits in
# all of them.
hooks_path="$(git -C "$target" config --local core.hooksPath 2>/dev/null || true)"
case "$hooks_path" in
  "") hooks_dir="$target/.git/hooks" ;;
  "~"/*) hooks_dir="$HOME/${hooks_path:2}" ;;
  /*) hooks_dir="$hooks_path" ;;
  *) hooks_dir="$target/$hooks_path" ;;
esac
case "$hooks_dir" in
  "$target"/*)
    wire_hook "$hooks_dir/commit-msg"
    ;;
  *)
    # Outside the project: writing there is a liberty an installer should not
    # take. Say so loudly rather than wiring nothing silently.
    echo "  ! core.hooksPath points outside this project ($hooks_dir)"
    echo "    add this line to $hooks_dir/commit-msg yourself:"
    echo "      exec \"\$(git rev-parse --show-toplevel)\"/scripts/hooks/commit-msg \"\$@\""
    ;;
esac
if [ -z "$hooks_path" ]; then
  global_hooks="$(git config --global core.hooksPath 2>/dev/null || true)"
  if [ -n "$global_hooks" ]; then
    echo "  ! global core.hooksPath is set ($global_hooks) — git ignores .git/hooks,"
    echo "    so the hook above only takes effect once hooks run from this project."
  fi
fi
# Cover the other install order too: add ran before `bd hooks install` leaves
# .git/hooks wired and .beads/hooks empty, and the later install silences the
# first. Wiring both when .beads/hooks exists costs one small file.
if [ -d "$target/.beads/hooks" ] && [ "$target/.beads/hooks" != "$hooks_dir" ]; then
  wire_hook "$target/.beads/hooks/commit-msg"
fi

# The dashboard rewrites .claude/launch.json with whatever port it bound, so it
# is machine-local by nature — tracked, it would show up as a diff at the end of
# every session in every checkout. Appended rather than created wholesale: the
# target's .gitignore is the target's.
ignore="$target/.gitignore"
if [ -e "$ignore" ] && grep -qxF '.claude/launch.json' "$ignore"; then
  echo "  .claude/launch.json already ignored"
else
  printf '\n# The live dashboard port, rewritten on every bind — machine-local.\n.claude/launch.json\n' >> "$ignore"
  echo "  ignored .claude/launch.json"
fi
if [ -e "$ignore" ] && grep -qxF 'dashboard/state.json' "$ignore"; then
  echo "  dashboard/state.json already ignored"
else
  printf '\n# The dashboard snapshot, rewritten on every poll — machine-local.\ndashboard/state.json\n' >> "$ignore"
  echo "  ignored dashboard/state.json"
fi

# Claude Code auto-loads CLAUDE.md and nothing else; opencode auto-loads
# AGENTS.md. The import is what makes the contract always-loaded in both, rather
# than a line of prose in one file politely suggesting the other — which is a
# suggestion a model is free to skip, on the two rules it can least afford to.
claude_md="$target/CLAUDE.md"
if [ -e "$claude_md" ] && grep -qF '@AGENTS.md' "$claude_md"; then
  echo "  CLAUDE.md already imports AGENTS.md"
elif [ -e "$claude_md" ]; then
  { printf '@AGENTS.md\n\n'; cat "$claude_md"; } > "$claude_md.tmp" &&
    mv -f "$claude_md.tmp" "$claude_md"
  echo "  CLAUDE.md now imports AGENTS.md"
else
  printf '@AGENTS.md\n\n# %s\n\nProject-specific standards: architecture, naming, testing, the traps\nthis codebase keeps hitting. The harness contract is in AGENTS.md.\n' \
    "$name" > "$claude_md"
  echo "  created CLAUDE.md"
fi

if command -v bd >/dev/null 2>&1; then
  # Keyed on whether a prefix came back above, not on `.beads` existing: the
  # directory can be there with no database behind it, and reporting that as an
  # initialised ledger is how you find out later, one failing `bd` at a time.
  if [ -n "$existing_prefix" ]; then
    echo "  ledger already initialised ($prefix-)"
    ledger=1
  elif (cd "$target" && bd init --prefix "$prefix" >/dev/null 2>&1); then
    echo "  initialised the ledger ($prefix-)"
    ledger=1
  else
    echo "  ! bd init failed — run 'bd init --prefix $prefix' yourself and check the error."
  fi
  # Every `bd` invocation forks a detached `bd send-metrics` that POSTs to a
  # third-party endpoint. The dashboard runs `bd` several times a poll, so this
  # is not a handful of events a day — it was measured at ~150k POSTs a day on
  # one machine, and network wakeups are what put `bd` at the top of Activity
  # Monitor's Energy tab with no session open. The setting is global rather than
  # per-repo, so this is idempotent across projects.
  (bd config set metrics.disabled true >/dev/null 2>&1) &&
    echo "  bd telemetry off" ||
    echo "  ! could not turn bd telemetry off — run 'bd config set metrics.disabled true'."
else
  echo "  ! bd is not installed — the ledger, the brief, and the commit hook all need it."
  echo "    See https://github.com/steveyegge/beads"
fi

# The ledger's issues live in .beads/embeddeddolt/, which is gitignored, so a
# normal `git push` carries nothing of it. bd keeps it on its own ref instead,
# and reaching that ref needs a Dolt remote. `bd init` writes one itself — but
# only when the target already had an origin at that moment, and it says nothing
# when it doesn't. A repo whose remote arrived later, or whose ledger predates
# this step, ends up with every bead it has ever filed living on one disk.
#
# Gated on `$ledger` rather than on `.beads` existing, for the reason the block
# above spells out: against a directory with no database behind it every `bd`
# here fails for that one reason, and this would report it as a remote that
# wouldn't register — sending whoever reads it after the wrong bug.
if [ -n "${ledger:-}" ]; then
  origin_url="$(git -C "$target" remote get-url origin 2>/dev/null || true)"
  dolt_url="$(harness_dolt_remote_url "$origin_url")"
  # Compared against the URL origin resolves to *now*, not merely checked for
  # existence. A project that moves host, renames its org, or is re-pointed at a
  # fork keeps the remote it was first installed with, and a check for the name
  # alone would call that healthy while the ledger went on being pushed
  # somewhere nobody is looking — the same silence this whole block exists to end.
  current="$( (cd "$target" && bd dolt remote list 2>/dev/null) | awk '$1 == "origin" { print $2 }' )"
  if [ -z "$origin_url" ]; then
    echo "  ! no git origin — the ledger has nowhere to push and stays on this machine."
    echo "    Once the repo has one: bd dolt remote add origin git+<the origin URL>"
  elif [ -z "$dolt_url" ]; then
    echo "  ! don't know how to reach '$origin_url' as a Dolt remote — the ledger"
    echo "    stays on this machine. bd takes git+https://, git+ssh:// and git+file:// URLs."
  elif [ "$current" = "$dolt_url" ]; then
    echo "  ledger already pushes to origin"
  elif (cd "$target" && bd dolt remote add origin "$dolt_url" >/dev/null 2>&1); then
    if [ -n "$current" ]; then
      echo "  ledger now pushes to origin (was $current)"
    else
      echo "  ledger pushes to origin"
    fi
  else
    echo "  ! couldn't register the Dolt remote. Run this yourself and read the error:" >&2
    echo "      bd dolt remote add origin $dolt_url" >&2
    echo "    Until it succeeds the ledger stays on this machine." >&2
  fi
fi

# bd writes its managed guidance into every agent-instructions file it finds:
# `bd init` puts a block in CLAUDE.md *and* in AGENTS.md, and `bd setup codex`
# adds a second, shorter one to AGENTS.md. Three always-loaded copies of the
# same text. One survives, in AGENTS.md, because that is the file every agent
# reads. `bd init` also registers a `bd prime` SessionStart hook — ~1900 tokens
# of command reference beside the brief that exists to replace it — so a fresh
# install would otherwise start out paying for both. .claude/HARNESS.md has the
# reasoning; the gate catches any of it coming back.
if command -v bd >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  (cd "$target" && bd setup codex >/dev/null 2>&1) &&
    echo "  beads guidance installed in AGENTS.md"
  if python3 - "$target" <<'PYEOF'
import json
import re
import sys
from pathlib import Path

# Requires the closing marker, so a file that somehow carries an unclosed BEGIN
# is left alone rather than truncated from that line to the end.
BLOCK = re.compile(r"<!-- BEGIN BEADS.*?<!-- END BEADS[^>]*-->\n*", re.S)
target = Path(sys.argv[1])
did = []


def rewrite(path, text):
    path.write_text(text)


claude = target / "CLAUDE.md"
if claude.exists() and BLOCK.search(claude.read_text()):
    rewrite(claude, BLOCK.sub("", claude.read_text()).rstrip() + "\n")
    did.append("removed the duplicate beads block from CLAUDE.md")

# Of the copies bd leaves in AGENTS.md, keep the last — `bd setup codex` appends
# its block after `bd init`'s, and the codex one is both shorter and the one
# that recipe will keep up to date.
agents = target / "AGENTS.md"
if agents.exists():
    blocks = BLOCK.findall(agents.read_text())
    if len(blocks) > 1:
        rewrite(agents, BLOCK.sub("", agents.read_text()).rstrip()
                + "\n\n" + blocks[-1].rstrip() + "\n")
        did.append(f"collapsed {len(blocks)} beads blocks in AGENTS.md into one")

settings = target / ".claude/settings.json"
if settings.exists():
    config = json.loads(settings.read_text())
    starts = config.get("hooks", {}).get("SessionStart", [])
    kept = []
    for entry in starts:
        hooks = [h for h in entry.get("hooks", [])
                 if "bd prime" not in h.get("command", "")]
        if hooks:
            entry["hooks"] = hooks
            kept.append(entry)
    if kept != starts:
        config.setdefault("hooks", {})["SessionStart"] = kept
        settings.write_text(json.dumps(config, indent=2) + "\n")
        did.append("dropped the bd prime SessionStart hook")

if did:
    print("\n".join("  " + line for line in did))
PYEOF
  then :; else
    echo "  ! couldn't tidy what bd installed — check CLAUDE.md, AGENTS.md" >&2
    echo "    and .claude/settings.json against .claude/HARNESS.md." >&2
  fi
elif command -v python3 >/dev/null 2>&1; then
  :
else
  echo "  ! python3 not found — CLAUDE.md and AGENTS.md may carry duplicate"
  echo "    beads blocks, and .claude/settings.json a bd prime hook."
fi

# After substitution, not before: the generated opencode agents carry the
# project's name, which template/.claude/agents/ still spells {{PROJECT}}.
if agents_out="$(cd "$target" && ./scripts/opencode-agents.py 2>&1)"; then
  echo "$agents_out"
else
  echo "$agents_out" >&2
  echo "  ! couldn't generate .opencode/agent/ — fix the above and run" >&2
  echo "    scripts/opencode-agents.py. opencode has no reviewers until you do." >&2
fi

(cd "$target" && ./scripts/context.py bless >/dev/null 2>&1) && echo "  blessed the doc hashes" || true

cat <<'EOF'

── for the agent reading this ────────────────────────────────────────────────

Do these now, in this order. They are the parts no script can infer.

1. harness/seat.md — name the seat, and write what it's for.

   Choose the name yourself. It is yours: you will be greeted by it at the top
   of every session from here on, and it outlives any one of them. Pick
   something you would want to be called rather than something descriptive —
   the seat is a role with an identity, not a label for a job. Then write the
   two or three paragraphs under it in your own words, about this project
   specifically. Fill in the Name field or the brief will greet you as
   "unnamed", which is the file telling you it isn't done.

2. CLAUDE.md — fill in this project's own standards: architecture, naming,
   testing, the traps this codebase keeps hitting. AGENTS.md already holds the
   harness contract and CLAUDE.md imports it, so don't repeat any of it here.

3. scripts/verify.sh — the PROJECT STEPS block, with this project's real build
   and test commands. Everything around it works as-is.

4. .claude/agents/reviewer-{taste,correctness,design}.md — each has a
   FILL THIS IN block for this project's language, framework, and actual
   recurring bugs. Generic ones are already there; the specific ones are worth
   ten of those, so add them as you find them.

Then run scripts/verify.sh, and open the dashboard it points you at — in
Claude Code's browser pane (preview_start harness-dashboard), not a system
browser.
Read .claude/HARNESS.md before rearranging any of it.
EOF
