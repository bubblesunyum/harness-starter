#!/bin/bash
# The `harness update dashboard` implementation. Sourced by commands/update.sh,
# never run — commands/*.sh is what the dispatcher lists, so living here keeps
# a subcommand from showing up as a top-level command.
#
# `harness add` never overwrites and `harness update --apply` never touches a
# deliberate fork, which is what makes both safe to run — but it also means a
# dashboard fix ships nowhere. The dashboard is the exception: everything a
# project owns lives in dashboard.toml beside the shipped files (run buttons,
# the verdict pattern, the project name), never in them, so re-copying is a
# plain copy with nothing to merge. dashboard.toml is never touched;
# dashboard/state.json — the live snapshot, rewritten on every poll — is kept
# as it was.

# Whether the target's dashboard.py carries a VERDICT answer its
# dashboard.toml doesn't have yet: a project from before the verdict moved
# into the toml. Exits 0 when there is an answer to move, 1 otherwise — so
# `harness update --apply` can refuse to converge the file (the copy would
# delete the answer) and both commands can point at the one that moves it.
harness_dashboard_verdict_unmigrated() {
  python3 - "$1/scripts/dashboard.py" "$1/dashboard.toml" <<'PYEOF' 2>/dev/null
import re
import sys
import tomllib

py_path, toml_path = sys.argv[1], sys.argv[2]
try:
    text = open(py_path).read()
except OSError:
    sys.exit(1)
# Non-greedy up to the first closing quote, trailing content ignored: a
# comment after the pattern is valid Python, and requiring end-of-line would
# read the answer as absent and let a later copy delete it.
m = re.search(r'^VERDICT\s*=\s*r(["\'])(.*?)\1', text, re.M)
if not m or m.group(2) in ("", "(?!)"):
    sys.exit(1)
try:
    with open(toml_path, "rb") as f:
        doc = tomllib.load(f)
except (OSError, tomllib.TOMLDecodeError):
    sys.exit(0)
section = doc.get("verdict", {})
if isinstance(section, dict) and isinstance(section.get("pattern"), str):
    sys.exit(1)
sys.exit(0)
PYEOF
}

# Move a pre-toml VERDICT answer from the target's dashboard.py into its
# dashboard.toml, on stdout one of MOVED, TOML-WINS, or NONE. Fails loudly
# when the toml exists but doesn't parse — appending to a broken file would
# pile a second error onto the first, and the dashboard keeps serving its
# last good table meanwhile, so there is no hurry worth breaking things for.
harness_migrate_dashboard_verdict() {
  python3 - "$1/scripts/dashboard.py" "$1/dashboard.toml" <<'PYEOF'
import re
import sys
import tomllib

py_path, toml_path = sys.argv[1], sys.argv[2]
try:
    text = open(py_path).read()
except OSError:
    print("NONE")
    sys.exit(0)
m = re.search(r'^VERDICT\s*=\s*r(["\'])(.*?)\1', text, re.M)
if not m or m.group(2) in ("", "(?!)"):
    print("NONE")
    sys.exit(0)
pattern = m.group(2)
try:
    compiled = re.compile(pattern)
except re.error as e:
    print(f"✗ scripts/dashboard.py carries a VERDICT pattern that does not compile: {e}.",
          file=sys.stderr)
    print("  Fix it by hand — no automatic move is safe.", file=sys.stderr)
    sys.exit(1)
# log_ok reads the verdict word out of one (...) group; anything else would
# serve a permanent wrong answer from the toml, so it fails here instead,
# before anything is written.
if compiled.groups != 1:
    print("✗ scripts/dashboard.py carries a VERDICT pattern with "
          f"{compiled.groups} (...) groups — the dashboard needs exactly one, the verdict word.",
          file=sys.stderr)
    print("  Group the rest with (?:...) by hand, then re-run.", file=sys.stderr)
    sys.exit(1)


def toml_string(s):
    # A TOML literal string takes the pattern as-is, backslashes and all, and
    # so survives this move byte-for-byte. Only a pattern holding a single
    # quote needs the basic form, with its escapes spelled out.
    if "'" not in s and "\n" not in s:
        return "'" + s + "'"
    out = '"'
    for c in s:
        if c == "\\":
            out += "\\\\"
        elif c == '"':
            out += '\\"'
        elif c == "\n":
            out += "\\n"
        elif c == "\t":
            out += "\\t"
        elif c == "\r":
            out += "\\r"
        elif ord(c) < 0x20:
            out += f"\\u{ord(c):04X}"
        else:
            out += c
    return out + '"'


try:
    with open(toml_path, "rb") as f:
        doc = tomllib.load(f)
except FileNotFoundError:
    doc = None
except (OSError, tomllib.TOMLDecodeError) as e:
    print(f"✗ dashboard.toml exists but doesn't parse: {e}.", file=sys.stderr)
    print("  Fix it first — the VERDICT move appends to that file.", file=sys.stderr)
    sys.exit(1)
if isinstance(doc, dict) and "verdict" in doc:
    section = doc["verdict"]
    if isinstance(section, dict) and isinstance(section.get("pattern"), str):
        if section["pattern"] == pattern:
            print("NONE")
        else:
            print("TOML-WINS")
        sys.exit(0)
    # A [verdict] table with no usable pattern — a bare header, a typo'd key,
    # a non-string — is already broken: the dashboard complains about it on
    # every poll. Appending a second table would pile a duplicate-table error
    # onto it and trap the answer in an unparseable file, so this fails
    # instead, before writing anything.
    print("✗ dashboard.toml already has a [verdict] section but no usable pattern.",
          file=sys.stderr)
    print("  Fix it by hand — then re-run, or put the pattern there yourself.", file=sys.stderr)
    sys.exit(1)
block = ("\n[verdict]\n"
         "# Moved from scripts/dashboard.py by `harness update dashboard` —\n"
         "# that file is byte-identical everywhere now, so this is where the\n"
         "# answer lives. The dashboard picks it up on the next poll.\n"
         f"pattern = {toml_string(pattern)}\n")
try:
    with open(toml_path, "ab+") as f:
        f.seek(0, 2)
        if f.tell() > 0:
            f.seek(f.tell() - 1)
            if f.read(1) != b"\n":
                f.write(b"\n")
        f.write(block.encode())
except OSError as e:
    print(f"✗ cannot write {toml_path}: {e}.", file=sys.stderr)
    sys.exit(1)
print("MOVED")
PYEOF
}

# Whether a diverged entry is honored here: contract files only. Vendor files
# are data, so `harness update` already fails loudly on those entries as
# acknowledging nothing — honoring them here while update rejects them would
# give contradictory orders, obeying update by deleting the line and then
# overwriting the fork it protected.
harness_dashboard_is_diverged() {
  [ -f "$TEMPLATE/$2" ] || return 1
  harness_in_diverged_list "$1" "$2" || return 1
  harness_is_contract "$2" "$TEMPLATE/$2"
}

# Re-copy the dashboard files from the template over a project that has them.
# Takes the resolved target directory. Copies dashboard/ and
# scripts/dashboard.py, never touches dashboard.toml, keeps
# dashboard/state.json, and moves a pre-toml VERDICT answer into the toml
# before the copy lands. Run 'harness add' first if the project has no
# dashboard at all.
harness_update_dashboard() {
  local target="$1"
  local all files diverged_want ignored extras dead updated removed skipped
  local rel found migration verdict_note

  # The dashboard file set, derived from what git says the template ships
  # rather than spelled out here — a spelled-out list goes stale in exactly
  # the direction that silently stops shipping a new vendor asset.
  all="$(harness_template_files "$HERE")" || return 1
  files="$(printf '%s\n' "$all" | grep -E '^(dashboard/|scripts/dashboard\.py$)' || true)"
  [ -n "$files" ] || { echo "✗ the template ships no dashboard files — nothing to update." >&2; return 1; }

  diverged_want=""
  if [ -f "$target/harness/diverged.txt" ]; then
    diverged_want="$(harness_diverged_want "$target")" || {
      echo "✗ harness/diverged.txt exists but is not readable — acknowledged forks can't be honored." >&2
      return 1
    }
  fi
  # Entries named but not honored, so the run says what it ignored instead of
  # silently overwriting a line someone wrote meaning protection.
  ignored=""
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    harness_in_diverged_list "$diverged_want" "$rel" || continue
    harness_is_contract "$rel" "$TEMPLATE/$rel" && continue
    ignored="$ignored  $rel"$'\n'
  done <<< "$files"

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
    return 1
  fi

  # The one answer a project may still carry inside a shipped file, moved into
  # dashboard.toml before the copy lands — after this the re-copy is a plain
  # copy with nothing to merge, and dashboard.py stays byte-identical
  # everywhere.
  migration="$(harness_migrate_dashboard_verdict "$target")" || return 1
  verdict_note=""
  case "$migration" in
    MOVED) verdict_note="  moved this project's VERDICT pattern into dashboard.toml" ;;
    TOML-WINS) verdict_note="  dashboard.toml already set a verdict — dropped the VERDICT answer dashboard.py carried" ;;
  esac

  updated=""; removed=""; skipped=""
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if harness_dashboard_is_diverged "$diverged_want" "$rel"; then
      skipped="$skipped  $rel"$'\n'
      continue
    fi
    harness_dashboard_install_file "$TEMPLATE/$rel" "$target/$rel" "$rel" || return 1
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

  echo "harness update dashboard: $target"
  if [ -n "$updated" ]; then
    echo "  updated $(harness_tally "$updated") file(s) from the template:"
    printf '%s' "$updated"
  fi
  [ -n "$verdict_note" ] && echo "$verdict_note"
  if [ -f "$target/dashboard/state.json" ]; then
    echo "  kept dashboard/state.json (live snapshot)"
  fi
  echo "  never re-copied dashboard.toml — it is the project's"
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
}

# A template file as it lands in the project, through a same-dir temp and a
# rename: the shell truncates the redirect target before reading the source,
# so a failing read would otherwise leave a 0-byte shipped file behind. The
# temp sits beside the destination so the move is a rename on one filesystem.
harness_dashboard_install_file() {
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
  harness_render "$src" > "$tmp" || { rm -f "$tmp"; return 1; }
  # mktemp makes 0600 and the rename keeps it: restore the modes `harness add`
  # leaves — readable everywhere, executable only where the template is — or
  # one run revokes group read on every dashboard file and it never heals.
  chmod 644 "$tmp" || { rm -f "$tmp"; return 1; }
  [ -x "$src" ] && chmod +x "$tmp"
  mv "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
}
