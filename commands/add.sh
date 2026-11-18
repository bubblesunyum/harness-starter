#!/bin/bash
# install the harness into a project, by reference
#
#   harness add              into the current directory
#   harness add <path>       into that project instead
#
# Everything is inferred: the project's name and its bead prefix come from the
# directory, and an existing ledger keeps the prefix it already has. The one
# thing no script can infer is who the seat is — that's the agent's to choose,
# and it's the first thing the closing instructions ask for.
#
# A reference install keeps the contract in the shared checkout: this writes
# the stubs in template/stubs/, the seeds, CLAUDE.md and scripts/harness — and no
# other contract file — then runs `<target>/scripts/harness link` so the shared
# skills exist before the first session. The shared skills, agents and scripts
# stay in the checkout and arrive through `scripts/harness link` and dispatch.
#
# Never overwrites a file that already exists in the target, and prints what it
# skipped, so a re-run is a safe way to pick up pieces added since.
set -euo pipefail

# Derived from this file's own location, never from the environment. The
# dispatcher execs an already-resolved absolute path, so this is correct there
# too — and a command that took its root from an exported variable would install
# a different checkout's template whenever a stale one was lying around, with no
# error and no sign that it had happened.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMPLATE="$HERE/template"
# Everything `add` and `migrate` have to agree on lives here.
# shellcheck source=lib/install.sh
. "$HERE/commands/lib/install.sh"

# Spelled out rather than sed'd off the comment block above: BSD sed has no
# `\?`, so the version that did that shipped the leading `#` of every line.
usage() {
  cat <<EOF
Installs the agentic development harness into a project, by reference.

  harness add              into the current directory
  harness add <path>       into that project instead

The project's name and its bead prefix are inferred from the directory, and a
project that already has a ledger keeps the prefix it already has. Needs beads
(bd) on PATH; a missing git repository is created. Needs HARNESS_HOME or
~/.harness pointing at a harness-starter checkout; without one this fails
before writing anything. A copied install converts with 'harness migrate'.

A reference install keeps the contract in the shared checkout: add writes the
stubs in template/stubs/, the seeds, CLAUDE.md and scripts/harness — and no other
contract file — then runs '<target>/scripts/harness link' so the shared skills exist
before the first session.

Never overwrites a file that already exists, so re-running is a safe way to
pick up pieces added to the starter since.

harness update and harness diverge are retired: a reference install is always
current, and a same-path project file is a shadow.
EOF
}

# --reference may lead or trail the path; anything else positional is the
# target, as today — an unknown flag reads as a path and fails as one.
pos=""
for arg in ${1+"$@"}; do
  case "$arg" in
    # No-op: reference is the only install, kept so old invocations keep working.
    --reference) ;;
    -h|--help) usage; exit 0 ;;
    *) [ -n "$pos" ] || pos="$arg" ;;
  esac
done

# Before the target is even resolved: resolving inits a git repository,
# and a harness that cannot be found must leave the target untouched.
ref_root="$(harness_reference_root)" || exit 1

# Whether the target already is a repository, read off the raw path before
# resolving it: --init creates one when it isn't, and the install says so below
# in its own voice — resolve_target's stdout is the path, so the notice can't
# come from inside it. -e rather than -d: a linked worktree's .git is a file,
# and it is still a repository — no init happens there, so no notice either.
had_git=0
[ -e "${pos:-$PWD}/.git" ] && had_git=1
target="$(harness_resolve_target --init "${pos:-$PWD}")"
# A copied install is a conversion, not an install: every stub path already
# holds a full copy-install file, so continuing would print "already there"
# for each and exit 0 with the stale contract in place. Refuse before anything
# is written, naming the conversion. The starter itself is exempt — working on
# the harness means installing into a tree that carries the contract by design.
if [ "$target" != "$HERE" ] && harness_is_copy_install "$target"; then
  echo "✗ this is a copied install — convert it with 'harness migrate' (dry run first)." >&2
  echo "  A reference install keeps only stubs and the finder; this tree carries full contract files." >&2
  exit 1
fi
# Protect even the first prefix lookup from bd's memory-less auto-flush. The
# project setting is persisted once its live ledger has been verified below.
export BD_EXPORT_AUTO=false
# Dependencies, installed or failed loud before anything else: the prefix
# lookup, the ledger, the tidier and the reviewer generation all need both,
# and the old warn-and-continue left the ledger, the brief and the hook dead.
harness_ensure_bd || {
  echo "✗ bd (beads) is not installed and automatic install failed." >&2
  echo "  Install it yourself — 'brew install beads', or see" >&2
  echo "  https://github.com/gastownhall/beads — then re-run." >&2
  exit 1
}
harness_require_python3 || exit 1
# Only a skill created by this install's bd init may be replaced automatically.
had_codex_beads=0
if [ -e "$target/.agents/skills/beads" ] || [ -L "$target/.agents/skills/beads" ]; then
  had_codex_beads=1
fi
# Installing into the starter itself is allowed on purpose — that is how the
# harness gets worked on with the harness. It is not free of a trap; see
# "Working on the starter" in the README.

name="$(basename "$target")"

existing_prefix="$(harness_ledger_prefix "$target")"
prefix="$existing_prefix"
[ -n "$prefix" ] || prefix="$(harness_derive_prefix "$name")"

echo "installing the harness into $target"
[ "$had_git" -eq 0 ] && echo "  initialised a git repository"
echo "  project: $name"
echo "  prefix:  $prefix-"
echo "  harness: $ref_root (reference — shared files stay there)"

# Written once, before the file list is read, because the list depends on it.
# An existing stacks.txt is the project's call and is never re-detected over.
if [ -e "$target/harness/stacks.txt" ]; then
  stacks="$(harness_stacks_want "$target")" || {
    echo "✗ harness/stacks.txt exists but is not readable — fix it and re-run." >&2; exit 1; }
  stacks_from="harness/stacks.txt"
else
  stacks="$(harness_detect_stacks "$target")"
  harness_write_stacks "$target" "$stacks"
  stacks_from="detected — correct harness/stacks.txt if that's wrong"
fi
echo "  stacks:  $(printf '%s' "${stacks:-none}" | tr '\n' ' ') ($stacks_from)"
unknown_stacks="$(harness_unknown_stacks "$HERE" "$stacks")"
if [ -n "$unknown_stacks" ]; then
  echo "  ! harness/stacks.txt names stacks the starter has no guidance for:"
  printf '%s\n' "$unknown_stacks" | sed 's/^/      /'
  echo "    Their reviewers get no platform checks. Fix the names, or remove them."
fi
echo

files="$(harness_reference_files)"
# Every source present before a single write: a missing stub would otherwise
# leave a 0-byte file behind, and the never-overwrite guard would then read
# that as already installed on every re-run.
missing=""
while IFS= read -r rel; do
  # Readable, not just present: an unreadable stub would otherwise truncate
  # the destination to 0 bytes below, and the never-overwrite guard would
  # then read that as already installed on every re-run.
  src_check="$TEMPLATE/$(harness_reference_src "$rel")"
  [ -f "$src_check" ] && [ -r "$src_check" ] || missing="$missing  $rel"$'\n'
done <<< "$files"
if [ -n "$missing" ]; then
  echo "✗ the starter is missing reference sources for:" >&2
  printf '%s' "$missing" >&2
  echo "  restore them (git checkout -- template/stubs) and re-run." >&2
  exit 1
fi

copied=0; skipped=0
while IFS= read -r rel; do
  src="$TEMPLATE/$(harness_reference_src "$rel")"
  dst="$target/$rel"
  if [ -e "$dst" ]; then
    # Never overwritten — that is what makes a re-run safe. An existing file
    # is the project's and stays.
    echo "  skip  $rel (already there)"
    skipped=$((skipped + 1))
    continue
  fi
  mkdir -p "$(dirname "$dst")"
  # Through a temp file, never directly: a failing render (unreadable source
  # in the TOCTOU window) must not leave a 0-byte destination that the
  # never-overwrite guard above then reads as already installed.
  tmp_dst="$(mktemp "$target/.harness-add-XXXXXX")" || exit 1
  if harness_render "$src" > "$tmp_dst"; then
    # mktemp makes 0600; installed files are 0644 (0755 below when the source
    # is executable).
    chmod 644 "$tmp_dst"
    mv "$tmp_dst" "$dst"
  else
    rm -f "$tmp_dst"
    echo "✗ cannot read $src — fix permissions and re-run." >&2
    exit 1
  fi
  [ -x "$src" ] && chmod +x "$dst"
  echo "  add   $rel"
  copied=$((copied + 1))
done <<< "$files"

echo
echo "  $copied added, $skipped skipped"
# The hook logic lives in scripts/ and is pointed at — both hooks, in both
# hook directories `bd init` may have put in play. Shared with `migrate`,
# which wires the same hooks into converted trees.
harness_wire_all "$target"

# Machine-local files the install ignores on the target's behalf. Appended
# rather than created wholesale: the target's .gitignore is the target's.
# Each would otherwise show up as a diff at the end of every session in every
# checkout.
ignore="$target/.gitignore"
append_ignore() {
  local path="$1" comment="$2"
  if [ -e "$ignore" ] && grep -qxF "$path" "$ignore"; then
    echo "  $path already ignored"
  else
    printf '\n# %s\n%s\n' "$comment" "$path" >> "$ignore"
    echo "  ignored $path"
  fi
}
append_ignore '.claude/launch.json' \
  'The live dashboard port, rewritten on every bind — machine-local.'
append_ignore 'dashboard/state.json' \
  'The dashboard snapshot, rewritten on every poll — machine-local.'
append_ignore '.tmp/' \
  'Agent scratch — created here, removed when done, never committed.'
# Derived, not committed: the shared prompts are the source of truth, and
# `scripts/harness link` regenerates these from them on every session.
append_ignore '.codex/agents/' \
  'Codex agents generated from the shared prompts — scripts/harness link regenerates them.'

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
  # A zero exit from `bd init` is not a working ledger — that is how a project
  # reached a state where every session printed a healthy brief while the
  # ledger had no usable database behind it. Verified with `bd list`, never
  # `bd config`/`bd info`/`bd stats`/`bd doctor`: those auto-import a stale
  # .beads/issues.jsonl when the ledger looks stale to them, resurrecting
  # deleted beads (har-67c) — and doctor refuses embedded mode entirely, which
  # is what this installer produces.
  harness_verify_ledger() {
    local err
    if [ ! -d "$target/.beads/embeddeddolt" ]; then
      echo "  ! ledger has no database behind it (.beads/embeddeddolt missing) — the install did not take." >&2
      echo "    Run 'bd init --prefix $prefix' in $target and check the error." >&2
      return 1
    fi
    if ! err="$(cd "$target" && bd list --json --all 2>&1 >/dev/null)"; then
      echo "  ! ledger initialised but unusable — 'bd list' fails in $target." >&2
      [ -n "$err" ] && printf '%s\n' "$err" | head -5 | sed -e 's/^/    /' >&2
      echo "    Run 'bd list' there yourself and check the error." >&2
      return 1
    fi
  }
  # Keyed on whether a prefix came back above, not on `.beads` existing: the
  # directory can be there with no database behind it, and reporting that as an
  # initialised ledger is how you find out later, one failing `bd` at a time.
  if [ -n "$existing_prefix" ]; then
    if harness_verify_ledger; then
      echo "  ledger already initialised ($prefix-)"
      ledger=1
    else
      # Warn and continue, never wipe or re-init over it: re-add's promise is
      # safe pickup of new pieces, and a broken ledger must not block that.
      # The brief flags the broken ledger every session, and the gate's export
      # check fails until it is fixed — so this stays loud past install.
      echo "  ! ledger exists but is unusable — fix 'bd list' in $target, then re-run." >&2
      echo "    Nothing was overwritten: this never wipes an existing ledger." >&2
      unset ledger
    fi
  elif (cd "$target" && bd init --prefix "$prefix" >/dev/null 2>&1); then
    echo "  initialised the ledger ($prefix-)"
    ledger=1
    # A fresh database behind a committed export means a clone: neither
    # transport hydrates it on its own — bd init with a configured remote
    # starts an empty database without reading issues.jsonl. So add imports it
    # explicitly on fresh init, and only then: an existing ledger keeps
    # whatever it has, and a stale export must never resurrect what the ledger
    # deleted.
    if [ ! -s "$target/.beads/issues.jsonl" ]; then
      : # No export to hydrate from — a genuinely new project, nothing to say.
    elif ! grep -q '"_type"' "$target/.beads/issues.jsonl" 2>/dev/null; then
      echo "  ! .beads/issues.jsonl doesn't look like a ledger export — the ledger starts empty." >&2
      echo "    Fix or remove the file, then run 'bd import .beads/issues.jsonl' yourself." >&2
    elif import_out="$(cd "$target" && bd import .beads/issues.jsonl 2>&1)"; then
      echo "  hydrated the ledger from the committed export"
      echo "$import_out" | sed -e 's/^/    /'
    else
      echo "  ! couldn't import .beads/issues.jsonl — the ledger starts empty." >&2
      echo "$import_out" | sed -e 's/^/    /' >&2
      echo "    Once the ledger is up, run 'bd import .beads/issues.jsonl' yourself." >&2
    fi
    # The exit above says init ran; this says the ledger works. Without it a
    # half-initialised database reports success and every later `bd` fails one
    # at a time — with it the Dolt-remote block below stays gated on a ledger
    # that actually answers.
    if ! harness_verify_ledger; then
      unset ledger
    fi
  else
    echo "  ! bd init failed — run 'bd init --prefix $prefix' yourself and check the error."
    exit 1
  fi
  if [ -n "${ledger:-}" ]; then
    harness_set_manual_export_policy "$target" || exit 1
  fi
  # Every `bd` invocation forks a detached `bd send-metrics` that POSTs to a
  # third-party endpoint. The dashboard runs `bd` several times a poll, so this
  # is not a handful of events a day — it was measured at ~150k POSTs a day on
  # one machine, and network wakeups are what put `bd` at the top of Activity
  # Monitor's Energy tab with no session open. The setting is global rather than
  # per-repo, so this is idempotent across projects.
  # From inside the target: run from the caller's cwd this lands in whatever
  # ledger the caller happens to stand in (the gate's ledger guard caught it).
  (cd "$target" && bd config set metrics.disabled true >/dev/null 2>&1) &&
    echo "  bd telemetry off" ||
    echo "  ! could not turn bd telemetry off — run 'bd config set metrics.disabled true'."
else
  # Unreachable: harness_ensure_bd above either provides bd or exits. Kept as a
  # loud net rather than silently continuing with a dead ledger, brief and hook.
  echo "✗ bd is not installed and provisioning failed — install it and re-run (see above)." >&2
  exit 1
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
    leftover_origin=1
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
    leftover_dolt="$dolt_url"
  fi
fi

# `bd init` leaves blocks in CLAUDE.md and in AGENTS.md — two in the latter,
# its INTEGRATION block and a CODEX SETUP one. Remove both: AGENTS.md already
# carries the project workflow. `bd init` also
# registers a `bd prime` SessionStart hook — ~1900 tokens of command reference
# beside the brief that exists to replace it — so a fresh install would
# otherwise start out paying for both. .claude/HARNESS.md has the reasoning;
# the gate catches any of it coming back.
#
# Deliberately no `bd setup codex`: its block restates what template/AGENTS.md
# already says, in worse words, and every re-run would re-append it over a
# deliberate removal. The template supplies the project brief hook for Codex.
if command -v bd >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
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

# Keep the project contract; generated Beads instructions use a different policy.
agents = target / "AGENTS.md"
if agents.exists() and BLOCK.search(agents.read_text()):
    rewrite(agents, BLOCK.sub("", agents.read_text()).rstrip() + "\n")
    did.append("removed generic beads blocks from AGENTS.md")

# bd init can install context hooks after the template was copied. Preserve
# unrelated hooks and replace only the generic Beads context entry points.
codex = target / ".codex/hooks.json"
if codex.exists():
    config = json.loads(codex.read_text())
    hooks = config.setdefault("hooks", {})
    removed = False
    for event, groups in list(hooks.items()):
        kept = []
        for group in groups:
            entries = [h for h in group.get("hooks", [])
                       if not re.search(r"\bbd\s+(?:codex-hook|prime)\b", h.get("command", ""))]
            removed |= len(entries) != len(group.get("hooks", []))
            if entries:
                kept.append({**group, "hooks": entries})
        if kept:
            hooks[event] = kept
        else:
            hooks.pop(event)
    starts = hooks.setdefault("SessionStart", [])
    # A reference install points its hooks at the finder, never at installed
    # scripts: the Codex brief entry names scripts/harness.
    want_pat = r"scripts/harness(?![\w/-])"
    want_cmd = 'bash "$(git rev-parse --show-toplevel)/scripts/harness" session --hook'
    added = not any(re.search(want_pat, h.get("command", ""))
                    for g in starts for h in g.get("hooks", []))
    if added:
        starts.append({"matcher": "^(startup|resume|clear|compact)$", "hooks": [{
            "type": "command",
            "command": want_cmd,
            "timeout": 60, "statusMessage": "Loading the harness brief"}]})
    if removed or added:
        rewrite(codex, json.dumps(config, indent=2) + "\n")
        did.append("configured the Codex project brief without generic beads hooks")

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

# A .opencode/opencode.json shadows the root one — opencode reads only the
# deeper file — so a plugin-only copy there would silently unload AGENTS.md.
# The root instructions are merged in; the shadow's own entries stay.
if merged="$(harness_merge_opencode "$target")"; then
  if [ -n "$merged" ]; then echo "  $merged"; fi
else
  echo "  ! .opencode/opencode.json exists but the instructions couldn't be merged in." >&2
  echo "    opencode reads it instead of opencode.json, so without them AGENTS.md never loads." >&2
  echo "    Copy the instructions list from opencode.json by hand." >&2
fi

# Leftover problems and post-install setup survive only as beads: install
# stdout scrolls away, `bd ready` doesn't. Each files only when its condition
# still holds and no open bead already carries the title, so re-add files no
# duplicates — and filling the file (or fixing the cause) clears it from ready.
harness_file_setup_beads() {
  local target="$1"
  local needs_filing=0
  local seat_todo=0 claude_todo=0 steps_todo=0 reviewers_todo=0
  local stacks_design=""
  [ -n "${leftover_origin:-}" ] && needs_filing=1
  [ -n "${leftover_dolt:-}" ] && needs_filing=1
  [ -n "${unknown_stacks:-}" ] && needs_filing=1
  if harness_seat_blank "$target"; then seat_todo=1; needs_filing=1; fi
  if harness_claude_stock "$target"; then claude_todo=1; needs_filing=1; fi
  if harness_verify_steps_placeholder "$target"; then steps_todo=1; needs_filing=1; fi
  if harness_reviewers_missing "$target"; then reviewers_todo=1; needs_filing=1; fi
  if [ "$needs_filing" -eq 0 ]; then return 0; fi
  if [ -n "${leftover_origin:-}" ]; then
    harness_file_bead "$target" "connect the ledger to a git origin" \
      "Give the repo an origin, then register it as the ledger's Dolt remote so beads travel: bd dolt remote add origin git+<the origin URL>. Until then every bead lives only on this machine." \
      "bd dolt remote list shows origin pointing at the current remote URL." \
      "needs-human" || true
  fi
  if [ -n "${leftover_dolt:-}" ]; then
    harness_file_bead "$target" "register the ledger's Dolt remote" \
      "bd dolt remote add origin $leftover_dolt fails in this project; run it, read the error, and fix the cause. Until it succeeds the ledger stays on this machine." \
      "bd dolt remote list shows origin pointing at the current remote URL." \
      "" || true
  fi
  if [ -n "${unknown_stacks:-}" ]; then
    stacks_design="harness add found these names in harness/stacks.txt with no guidance in the starter: $(printf '%s' "$unknown_stacks" | tr '\n' ' '). Fix the names (the valid ones are the files in template/harness/stacks/), or remove them; the reviewers get no platform checks until then."
    harness_file_bead "$target" "fix the unknown stack names in harness/stacks.txt" \
      "$stacks_design" \
      "harness/stacks.txt names only stacks the starter guides, and harness add prints no unknown-stack warning." \
      "" || true
  fi
  if [ "$seat_todo" -eq 1 ]; then
    harness_file_bead "$target" "name the seat in harness/seat.md" \
      "Choose a name you would want to be called and write two or three paragraphs on what this seat is for, about this project specifically, replacing the FILL THIS IN block. Fill in the Name field or the brief greets the seat as 'unnamed'." \
      "harness/seat.md carries a filled Name field and no FILL THIS IN block; the brief greets the seat by name." \
      "" || true
  fi
  if [ "$claude_todo" -eq 1 ]; then
    harness_file_bead "$target" "fill in CLAUDE.md with this project's standards" \
      "Write this project's own architecture, naming, testing and traps in CLAUDE.md; it already imports AGENTS.md, so repeat none of the contract. Replace the stock placeholder text harness add wrote." \
      "CLAUDE.md holds project-specific standards with no stock placeholder text remaining." \
      "" || true
  fi
  if [ "$steps_todo" -eq 1 ]; then
    harness_file_bead "$target" "write the project's gate steps in scripts/verify.steps.sh" \
      "Replace the placeholder steps with the project's real build and test commands, each going through step (probe_step for slow or throwaway-repo checks), and point the test-count grep at the real runner output." \
      "scripts/verify.sh runs the project's real commands; no placeholder step remains." \
      "" || true
  fi
  if [ "$reviewers_todo" -eq 1 ]; then
    harness_file_bead "$target" "add project-specific reviewer checks in harness/reviewers/" \
      "Write this language and framework's actual recurring bugs in harness/reviewers/taste.md, correctness.md and design.md; the reviewer agents read them as overlays over their generic checks. Confirm harness/stacks.txt names the right stacks first." \
      "harness/reviewers/taste.md, correctness.md and design.md exist with this project's checks." \
      "" || true
  fi
  # Filing wrote to the ledger without auto-export, so refresh the committed
  # export with memories — the same helper that set the policy, kept loud.
  harness_set_manual_export_policy "$target" || true
}
if [ -n "${ledger:-}" ]; then
  harness_file_setup_beads "$target"
  # Filing and ensure leave generated files the gate checks are tracked, but
  # neither stages them — a fresh install would land red on untracked files.
  # Best-effort and never fatal; never stage or touch anything else.
  if [ -e "$target/.beads/issues.jsonl" ] && ! git -C "$target" add .beads/issues.jsonl 2>/dev/null; then
    echo "  ! couldn't stage .beads/issues.jsonl — the gate will say untracked until it is staged."
  fi
fi

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

3. scripts/verify.steps.sh — this project's real build and test commands, going
   through `step`. scripts/harness verify runs the gate from the shared checkout.

4. harness/reviewers/{taste,correctness,design}.md — this project's own
   reviewer checks: the language, framework, and actual recurring bugs.
   The shared reviewers read these files as overlays over their generic
   checks — so put the specific ones here, they are worth ten of the generic
   ones. Checks for the project's language and platform come from
   harness/stacks/ — check that harness/stacks.txt named the right stacks
   above.

Then run scripts/harness doctor and scripts/harness session, and open the starter's
dashboard — the starter's dashboard shows this project, and nothing is
installed here for it.
Read .claude/HARNESS.md before rearranging any of it.
EOF

# bd init creates a generic copied Beads skill. The harness supplies its own;
# existing project copies still require manual reconciliation.
if [ "$had_codex_beads" -eq 0 ] && [ -d "$target/.agents/skills/beads" ] &&
   [ ! -L "$target/.agents/skills/beads" ]; then
  rm -rf "$target/.agents/skills/beads"
fi

# Linked at install time, not on first run: Claude Code only discovers skills
# present at launch. And linked only now, after bd init and the cleanup above:
# bd init writes .agents/skills/beads/SKILL.md, and with the links already in
# place that write lands through them in the SHARED checkout's beads skill.
echo "  linking the shared skills"
"$target/scripts/harness" link || {
  echo "✗ scripts/harness link failed in $target — run it yourself and read the error." >&2
  exit 1
}

# Shared sources are linked before Codex discovery links are generated: a
# reference install runs the shared generator through the finder — its
# .codex/agents and .agents/skills are per-project output either way.
if ! (cd "$target" && ./scripts/harness codex-support write); then
  echo "  ! Codex setup needs reconciliation; shared sources were preserved." >&2
  exit 1
fi

# The single pointer: install stdout scrolls away, the ledger doesn't.
if [ -n "${ledger:-}" ]; then
  echo "  setup and leftover tasks are filed as beads — 'bd ready' in $target lists them."
fi
