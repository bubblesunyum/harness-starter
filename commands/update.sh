#!/bin/bash
# report harness files that have drifted from the starter's template
#
#   harness update           check the current directory
#   harness update <path>    check that project instead
#   harness update --diff    also print what actually differs
#   harness update --apply   write the rendered template over stale contract files
#
# `harness add` never overwrites, which is what makes re-running it safe — but it
# also means a fix that ships in the starter never reaches a project that already
# has the file. The skip line scrolls past among the other skip lines and nothing
# says the install didn't take. This is the other half: it says, by name, which
# files are stale.
#
# Report-only by default. Merging is a judgment call — half these files have
# local edits in them by design — and an overwrite-by-default here would be a
# command nobody could afford to run. --apply is the exception, asked for by
# name: it writes the rendered template over the stale contract files, never
# over customised ones, and names every file it changed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMPLATE="$HERE/template"
# shellcheck source=lib/install.sh
. "$HERE/commands/lib/install.sh"

usage() {
  cat <<USAGE
Reports harness files in a project that differ from the starter's template.

  harness update            check the current directory
  harness update <path>     check that project instead
  harness update --diff     also print a unified diff of each difference
  harness update --apply    write the rendered template over stale contract files

Files carrying the harness contract — AGENTS.md, opencode.json, the skills, the
scripts behind them — are reported as warnings and make this exit non-zero: the
project has no reason to edit them, so a difference means a starter fix never
arrived. Files with a FILL THIS IN block are meant to be edited, so those are
listed quietly, for you to check against the template yourself.

Report-only, unless --apply: that rewrites the stale contract files that
exist — never customised ones, never missing ones — and prints each file it
changed. A file carrying a beads block is left for a hand merge, and reviewer
sources still need their follow-ups below. Run 'harness add' to install files
that are missing.
USAGE
}

show_diff=0; apply=0
target=""
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --diff) show_diff=1 ;;
    --apply) apply=1 ;;
    -*) echo "✗ unknown option: $arg" >&2; echo >&2; usage >&2; exit 1 ;;
    *)
      [ -z "$target" ] || { echo "✗ more than one path given: $target and $arg" >&2; exit 1; }
      target="$arg"
      ;;
  esac
done

target="$(harness_resolve_target "${target:-$PWD}")"
name="$(basename "$target")"
prefix="$(harness_prefix_for "$target" "$name")"
files="$(harness_template_files "$HERE")"

# How many lines a list holds. grep -c '' rather than wc -l, which counts
# newlines and calls a list without a trailing one empty.
tally() { printf '%s' "$1" | grep -c ''; }

echo "harness update: $target"
echo "  against $TEMPLATE"
echo

# Rendered into a temporary file rather than compared through a process
# substitution, because the same rendering is wanted twice — once for the
# comparison, once for the diff — and rendering it twice is how the two come to
# disagree.
render_dir="$(mktemp -d)" || { echo "✗ mktemp failed" >&2; exit 1; }
trap 'rm -rf "$render_dir"' EXIT

stale=""; customised=""; missing=""; missing_contract=0; diffs=""
applied=""; skipped_beads=""
# Whether a flagged file is a reviewer source, split by kind. Merging a stale
# contract source is half the job — the generated copies, the hashes, and the
# gate are the other half, and the report below says so. A customised source
# differs on every install that ever filled it in, so an order to rebuild there
# would nag forever; those get a pointer at the checks instead. Missing sources
# set neither: those are add's to install, which already runs the same steps.
agents_contract=0; agents_custom=0
while IFS= read -r rel; do
  src="$TEMPLATE/$rel"
  dst="$target/$rel"
  harness_is_data "$rel" && continue
  if [ ! -e "$dst" ]; then
    # A contract file that isn't there is the same failure as a stale one, with
    # a louder cause — opencode.json simply absent from an older install is the
    # case this whole command was written for.
    missing="$missing  $rel"$'\n'
    harness_is_contract "$rel" "$src" && missing_contract=$((missing_contract + 1))
    continue
  fi
  rendered="$render_dir/rendered"
  harness_render "$rel" "$src" "$name" "$prefix" > "$rendered"
  harness_same "$rel" "$rendered" "$dst" && continue
  if harness_is_contract "$rel" "$src"; then contract=1; else contract=0; fi
  case "$rel" in
    .claude/agents/*)
      if [ "$contract" -eq 1 ]; then agents_contract=1; else agents_custom=1; fi
      ;;
  esac
  if [ "$show_diff" -eq 1 ]; then
    # Padded through spaces rather than by repeating the rule character or
    # slicing a fixed one: `seq` given a negative count counts back up from 1,
    # and bash substrings cut by bytes, so a path long enough to shorten the
    # rule got either a longer header or a chopped-in-half box character.
    pad=$((72 - ${#rel}))
    [ "$pad" -ge 3 ] || pad=3
    diffs="$diffs$(printf '── %s %s\n' "$rel" \
                     "$(printf '%*s' "$pad" '' | sed 's/ /─/g')")"$'\n'
    # The normalised forms, so the diff shows the difference the warning is
    # about and not the beads block the comparison deliberately ignored.
    harness_normalise "$rel" "$rendered" > "$render_dir/a"
    harness_normalise "$rel" "$dst" > "$render_dir/b"
    diffs="$diffs$(diff -u --label "template/$rel" --label "$rel" \
                     "$render_dir/a" "$render_dir/b" || true)"$'\n\n'
  fi
  if [ "$apply" -eq 1 ] && [ "$contract" -eq 1 ]; then
    # Written only now, after the diff above was taken from the pre-write
    # state — a --diff --apply run shows what the apply changed, not an empty
    # diff of each file against itself.
    if harness_has_beads_block "$dst"; then
      # Left stale and named below, loudly.
      skipped_beads="$skipped_beads  $rel"$'\n'
      stale="$stale  $rel"$'\n'
    else
      harness_render "$rel" "$src" "$name" "$prefix" > "$dst"
      [ -x "$src" ] && chmod +x "$dst"
      applied="$applied  $rel"$'\n'
    fi
  elif [ "$contract" -eq 1 ]; then
    stale="$stale  $rel"$'\n'
  else
    customised="$customised  $rel"$'\n'
  fi
done <<< "$files"

if [ -n "$stale" ]; then
  echo "⚠ $(tally "$stale") contract file(s) exist and differ from the template"
  printf '%s' "$stale"
  echo "  The harness contract is not installed here — diff and merge each one."
  echo
fi

if [ -n "$missing" ]; then
  echo "  $(tally "$missing") file(s) missing — 'harness add $target' installs them"
  printf '%s' "$missing"
  echo
fi

if [ -n "$customised" ]; then
  echo "  $(tally "$customised") customised file(s) differ — expected, they carry FILL THIS IN blocks."
  echo "  Worth a look anyway when the starter has moved:"
  printf '%s' "$customised"
  echo
fi

if [ -n "$applied" ]; then
  echo "  applied $(tally "$applied") contract file(s) from the template:"
  printf '%s' "$applied"
  echo "  Review with git diff; revert any with git checkout -- <file>."
  echo
fi

if [ -n "$skipped_beads" ]; then
  echo "  $(tally "$skipped_beads") contract file(s) left stale — each carries a beads block the"
  echo "  template has no copy of, so overwriting would delete it. Merge by hand:"
  printf '%s' "$skipped_beads"
  echo
fi

if [ "$agents_contract" -eq 1 ]; then
  echo "  These include reviewer sources — merging is only half the job:"
  echo "    python3 scripts/codex-support.py write"
  if [ -f "$target/scripts/models.py" ] &&
     [ "$(harness_roster_state "$target")" != "ok" ]; then
    # The roster is machine-local and no commit carries it, so a fresh machine
    # regenerates model-free agents until someone runs this once per role.
    echo "    scripts/models.py ensure   (no usable roster — generated agents carry no model lines)"
  fi
  [ -f "$target/scripts/opencode-agents.py" ] && echo "    scripts/opencode-agents.py"
  echo "    scripts/context.py bless"
  echo "    scripts/verify.sh"
  echo
elif [ "$agents_custom" -eq 1 ] &&
     { [ -f "$target/scripts/codex-support.py" ] || [ -f "$target/scripts/opencode-agents.py" ]; }; then
  # Customised sources differ on every install that ever filled them in, so an
  # order to rebuild here would nag forever. The checks answer the question
  # that has an answer — whether the generated copies kept up.
  echo "  Reviewer sources differ — the generated copies may not have kept up:"
  [ -f "$target/scripts/codex-support.py" ] && echo "    python3 scripts/codex-support.py check"
  [ -f "$target/scripts/opencode-agents.py" ] && echo "    scripts/opencode-agents.py check"
  echo
fi

[ -n "$diffs" ] && printf '%s' "$diffs"

if [ -n "$stale" ] || [ "$missing_contract" -gt 0 ]; then
  echo "harness update: stale"
  exit 1
fi
if [ -n "$applied" ]; then
  echo "harness update: applied"
  exit 0
fi
echo "harness update: contract files are current"
