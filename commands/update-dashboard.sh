#!/bin/bash
# re-copy the dashboard over a project that already has it, leaving its config alone
#
#   harness update-dashboard         into the current directory
#   harness update-dashboard <path>  into that project instead
#
# `harness add` never overwrites and `harness update --apply` never touches a
# deliberate fork, which is what makes both safe to run — but it also means a
# dashboard fix ships nowhere. The dashboard is the exception: everything a
# project owns lives in dashboard.toml beside the shipped files (run buttons,
# project name), never in them, so re-copying is a plain copy with nothing to
# merge. dashboard.toml is never touched; dashboard/state.json — the live
# snapshot, rewritten on every poll — is kept as it was.
#
# The one answer a project may carry inside the shipped files is the VERDICT
# pattern in scripts/dashboard.py, FILL THIS IN until it moves into the toml
# beside the run table. That line is carried across the copy, so an update
# never deletes the single thing the file holds that the template doesn't.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMPLATE="$HERE/template"
# shellcheck source=lib/install.sh
. "$HERE/commands/lib/install.sh"

usage() {
  cat <<USAGE
Re-copies the dashboard files from the starter over a project that has them.

  harness update-dashboard         into the current directory
  harness update-dashboard <path>  into that project instead

Copies dashboard/ and scripts/dashboard.py from the template. Never touches
dashboard.toml — that file is the project's, installed once — and keeps
dashboard/state.json, the live snapshot. The VERDICT pattern a project set in
scripts/dashboard.py is carried across. Contract files acknowledged in
harness/diverged.txt are left alone, like 'harness update --apply' leaves
them. A diverged entry naming a file the template no longer ships fails
loudly — fix the list, 'harness update' says the same.
Run 'harness add' first if the project has no dashboard at all.
USAGE
}

target=""
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    -*) echo "✗ unknown option: $arg" >&2; echo >&2; usage >&2; exit 1 ;;
    *)
      [ -z "$target" ] || { echo "✗ more than one path given: $target and $arg" >&2; exit 1; }
      target="$arg"
      ;;
  esac
done

# No --init: an updater must not create repositories as a side effect. A path
# that isn't a working tree fails here, with resolve_target's own message.
target="$(harness_resolve_target "${target:-$PWD}")"

# The dashboard file set, derived from what git says the template ships rather
# than spelled out here — a spelled-out list goes stale in exactly the
# direction that silently stops shipping a new vendor asset.
all="$(harness_template_files "$HERE")" || exit 1
files="$(printf '%s\n' "$all" | grep -E '^(dashboard/|scripts/dashboard\.py$)' || true)"
[ -n "$files" ] || { echo "✗ the template ships no dashboard files — nothing to update." >&2; exit 1; }

diverged_want=""
if [ -f "$target/harness/diverged.txt" ]; then
  diverged_want="$(harness_diverged_want "$target")" || {
    echo "✗ harness/diverged.txt exists but is not readable — acknowledged forks can't be honored." >&2
    exit 1
  }
fi
# Whether a diverged entry is honored here: contract files only. dashboard.py
# carries FILL THIS IN and vendor files are data, so `harness update` already
# fails loudly on those entries as acknowledging nothing — honoring them here
# while update rejects them would give contradictory orders, obeying update by
# deleting the line and then overwriting the fork it protected.
is_diverged() {
  [ -f "$TEMPLATE/$1" ] || return 1
  harness_in_diverged_list "$diverged_want" "$1" || return 1
  harness_is_contract "$1" "$TEMPLATE/$1"
}
# Entries named but not honored, so the run says what it ignored instead of
# silently overwriting a line someone wrote meaning protection.
ignored=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  harness_in_diverged_list "$diverged_want" "$rel" || continue
  harness_is_contract "$rel" "$TEMPLATE/$rel" && continue
  ignored="$ignored  $rel"$'\n'
done <<< "$files"

# The project's VERDICT answer, when it has one. Compared by value against the
# template's own line, deliberately: a project sitting on a stale default keeps
# its working line rather than silently taking a new default it never chose.
# The other edge — the template losing the line entirely, which the header
# anticipates — has no safe copy, so it fails loudly below instead of
# announcing a carry it never made.
template_verdict="$(grep -E '^VERDICT = ' "$TEMPLATE/scripts/dashboard.py" | head -1 || true)"
target_verdict=""
if [ -f "$target/scripts/dashboard.py" ]; then
  target_verdict="$(grep -E '^VERDICT = ' "$target/scripts/dashboard.py" | head -1 || true)"
fi
carry_verdict=0
if [ -n "$target_verdict" ] && [ "$target_verdict" != "$template_verdict" ]; then
  carry_verdict=1
fi
if [ "$carry_verdict" -eq 1 ] && [ -z "$template_verdict" ]; then
  echo "✗ scripts/dashboard.py carries a VERDICT answer but the template no longer has a VERDICT line." >&2
  echo "  Merge it by hand — an automatic copy would delete the answer." >&2
  exit 1
fi

# A template file as it lands in the project, through a same-dir temp and a
# rename: the shell truncates the redirect target before reading the source,
# so a failing read would otherwise leave a 0-byte shipped file behind. The
# temp sits beside the destination so the move is a rename on one filesystem.
install_file() {
  local src="$1" dst="$2" rel="$3" tmp
  mkdir -p "$(dirname "$dst")" || { echo "✗ cannot write $(dirname "$dst")" >&2; return 1; }
  # A directory where a file goes is a state no copy can fix — and without
  # this, the rename below would move the temp file inside it and report
  # success while installing nothing.
  if [ -e "$dst" ] && [ ! -f "$dst" ]; then
    echo "✗ $rel exists and is not a file — remove it and re-run." >&2
    return 1
  fi
  tmp="$(mktemp "$(dirname "$dst")/.harness-update-XXXXXX")" || { echo "✗ mktemp failed" >&2; return 1; }
  if [ "$carry_verdict" -eq 1 ] && [ "$dst" = "$target/scripts/dashboard.py" ]; then
    # Carried through the environment, not -v: every awk spells backslash
    # escapes in -v assignments, and the pattern is mostly backslashes.
    VERDICT_LINE="$target_verdict" awk '{ if (/^VERDICT = /) print ENVIRON["VERDICT_LINE"]; else print }' \
      "$src" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    harness_render "$src" > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  # mktemp makes 0600 and the rename keeps it: restore the modes `harness add`
  # leaves — readable everywhere, executable only where the template is — or
  # one run revokes group read on every dashboard file and it never heals.
  chmod 644 "$tmp" || { rm -f "$tmp"; return 1; }
  [ -x "$src" ] && chmod +x "$tmp"
  mv "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
}

# On-disk extras the template no longer ships, collected before anything is
# written: a diverged entry naming one fails loudly rather than deleting the
# file or pinning it — `harness update` fails on that entry too, so both
# commands give the same order: fix the list.
extras=""
if [ -d "$target/dashboard" ]; then
  while IFS= read -r found; do
    [ -n "$found" ] || continue
    rel="${found#"$target"/}"
    [ "$rel" = "dashboard/state.json" ] && continue
    printf '%s\n' "$files" | grep -qxF "$rel" && continue
    extras="$extras  $rel"$'\n'
  done <<< "$(cd "$target/dashboard" && find . -type f -print | sed 's|^\./|dashboard/|')"
fi
dead=""
while IFS= read -r rel; do
  rel="${rel#  }"
  [ -n "$rel" ] || continue
  harness_in_diverged_list "$diverged_want" "$rel" || continue
  dead="$dead  $rel"$'\n'
done <<< "$extras"
if [ -n "$dead" ]; then
  echo "✗ $(harness_tally "$dead") diverged entry(s) name files the template no longer ships:" >&2
  printf '%s' "$dead" >&2
  echo "  Fix harness/diverged.txt — 'harness update' fails on these too." >&2
  exit 1
fi

updated=""; removed=""; skipped=""; carried=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if is_diverged "$rel"; then
    skipped="$skipped  $rel"$'\n'
    continue
  fi
  install_file "$TEMPLATE/$rel" "$target/$rel" "$rel" || exit 1
  [ "$rel" = "scripts/dashboard.py" ] && [ "$carry_verdict" -eq 1 ] && carried=1
  updated="$updated  $rel"$'\n'
done <<< "$files"

# The delete half of delete + re-copy: files the template no longer ships are
# not the project's to keep — except the live snapshot, which was never the
# template's. Anything a diverged line named already failed loudly above.
while IFS= read -r rel; do
  rel="${rel#  }"
  [ -n "$rel" ] || continue
  rm -f "$target/$rel"
  removed="$removed  $rel"$'\n'
done <<< "$extras"

echo "harness update-dashboard: $target"
if [ -n "$updated" ]; then
  echo "  updated $(harness_tally "$updated") file(s) from the template:"
  printf '%s' "$updated"
fi
if [ "$carried" -eq 1 ]; then
  echo "  carried the project's VERDICT pattern across scripts/dashboard.py"
fi
if [ -f "$target/dashboard/state.json" ]; then
  echo "  kept dashboard/state.json (live snapshot)"
fi
echo "  never touched dashboard.toml"
if [ -n "$removed" ]; then
  echo "  removed $(harness_tally "$removed") file(s) the template no longer ships:"
  printf '%s' "$removed"
fi
if [ -n "$ignored" ]; then
  echo "  ignored $(harness_tally "$ignored") diverged entry(s) that acknowledge nothing — data or FILL THIS IN:"
  printf '%s' "$ignored"
  echo "  'harness update' fails loudly on these; fix the list there."
fi
if [ -n "$skipped" ]; then
  echo "  left $(harness_tally "$skipped") diverged file(s) alone — acknowledged in harness/diverged.txt:"
  printf '%s' "$skipped"
  echo "  delete the line to un-acknowledge."
fi
