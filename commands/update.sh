#!/bin/bash
# report harness files that have drifted from the starter's template
#
#   harness update           check the current directory
#   harness update <path>    check that project instead
#   harness update --diff    also print what actually differs
#
# `harness add` never overwrites, which is what makes re-running it safe — but it
# also means a fix that ships in the starter never reaches a project that already
# has the file. The skip line scrolls past among the other skip lines and nothing
# says the install didn't take. This is the other half: it says, by name, which
# files are stale.
#
# It only reports. Merging is a judgment call — half these files have local edits
# in them by design — and a command that overwrote them would be a command nobody
# could afford to run.
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

Files carrying the harness contract — AGENTS.md, opencode.json, the skills, the
scripts behind them — are reported as warnings and make this exit non-zero: the
project has no reason to edit them, so a difference means a starter fix never
arrived. Files with a FILL THIS IN block are meant to be edited, so those are
listed quietly, for you to check against the template yourself.

Nothing is ever written. Run 'harness add' to install files that are missing.
USAGE
}

show_diff=0
target=""
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --diff) show_diff=1 ;;
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
  if harness_is_contract "$rel" "$src"; then
    stale="$stale  $rel"$'\n'
  else
    customised="$customised  $rel"$'\n'
  fi
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
done <<< "$files"

if [ -n "$stale" ]; then
  count="$(printf '%s' "$stale" | grep -c '')"
  echo "⚠ $count contract file(s) exist and differ from the template"
  printf '%s' "$stale"
  echo "  The harness contract is not installed here — diff and merge each one."
  echo
fi

if [ -n "$missing" ]; then
  count="$(printf '%s' "$missing" | grep -c '')"
  echo "  $count file(s) missing — 'harness add $target' installs them"
  printf '%s' "$missing"
  echo
fi

if [ -n "$customised" ]; then
  count="$(printf '%s' "$customised" | grep -c '')"
  echo "  $count customised file(s) differ — expected, they carry FILL THIS IN blocks."
  echo "  Worth a look anyway when the starter has moved:"
  printf '%s' "$customised"
  echo
fi

[ -n "$diffs" ] && printf '%s' "$diffs"

if [ -n "$stale" ] || [ "$missing_contract" -gt 0 ]; then
  echo "harness update: stale"
  exit 1
fi
echo "harness update: contract files are current"
