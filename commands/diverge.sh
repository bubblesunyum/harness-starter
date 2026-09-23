#!/bin/bash
# acknowledge local forks of the harness contract so update stops failing on them
#
#   harness diverge <file>...     acknowledge each file as a deliberate fork
#
# A forked contract file — a dashboard chip, a widened review scope, a forked
# generator — stays loud-stale under `harness update` forever, which teaches
# the project to ignore the warning. Acknowledging moves it to the diverged
# list: still shown for the record (and under --diff), never failing, never
# written by --apply. Un-acknowledge by deleting the line.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMPLATE="$HERE/template"
# shellcheck source=lib/install.sh
. "$HERE/commands/lib/install.sh"

usage() {
  cat <<USAGE
Acknowledges deliberate local forks of the harness contract.

  harness diverge <file>...   acknowledge each file, relative to the project root

Validates before writing: the file must exist in the template as a contract
file (data files and FILL THIS IN files are already quiet — acknowledging
them does nothing), must exist here, and must actually differ. Already-listed
files are left alone. Run it in the project directory.
USAGE
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
  esac
done

[ "$#" -gt 0 ] || { echo "✗ no files given" >&2; echo >&2; usage >&2; exit 1; }

target="$(harness_resolve_target "$PWD")"
name="$(basename "$target")"
prefix="$(harness_prefix_for "$target" "$name")"
# Fails with its own message: the template list is unreadable, or stacks.txt is.
files="$(harness_files_for "$HERE" "$target")" || {
  [ -e "$target/harness/stacks.txt" ] && [ ! -r "$target/harness/stacks.txt" ] &&
    echo "✗ harness/stacks.txt exists but is not readable — fix it and re-run." >&2
  exit 1
}
list="$target/harness/diverged.txt"

have=""
if [ -f "$list" ]; then
  have="$(harness_diverged_want "$target")" || {
    echo "✗ harness/diverged.txt exists but is not readable" >&2; exit 1; }
fi

fail=0
for rel in "$@"; do
  case "$rel" in
    -*) echo "✗ unknown option: $rel (run in the project; files are relative)" >&2; fail=1; continue ;;
    /*|*..*) echo "✗ $rel: give a repo-relative path, not an absolute or parent one" >&2; fail=1; continue ;;
  esac
  rel="${rel#./}"
  if ! printf '%s\n' "$files" | grep -qxF "$rel"; then
    echo "✗ $rel: no such template file" >&2; fail=1; continue
  fi
  if ! harness_is_contract "$rel" "$TEMPLATE/$rel"; then
    echo "✗ $rel: already quiet (data or FILL THIS IN) — nothing to acknowledge" >&2; fail=1; continue
  fi
  if [ ! -e "$target/$rel" ]; then
    echo "✗ $rel: not here — 'harness add' installs it; acknowledge the fork, not the absence" >&2; fail=1; continue
  fi
  if [ -n "$have" ] && printf '%s\n' "$have" | grep -qxF "$rel"; then
    echo "  already diverged: $rel"
    continue
  fi
  rendered="$(mktemp)" || { echo "✗ mktemp failed" >&2; exit 1; }
  harness_render "$rel" "$TEMPLATE/$rel" "$name" "$prefix" > "$rendered"
  if harness_same "$rel" "$rendered" "$target/$rel"; then
    rm -f "$rendered"
    echo "✗ $rel: already current — nothing to acknowledge" >&2; fail=1; continue
  fi
  rm -f "$rendered"
  mkdir -p "$(dirname "$list")"
  printf '%s\n' "$rel" >> "$list"
  have="$(cat "$list")"
  echo "  diverged: $rel"
done

[ "$fail" -eq 0 ] || exit 1
echo "  acknowledged in harness/diverged.txt — 'harness update' shows it for the record."
