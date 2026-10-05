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

# Move a diverged dashboard/index.html's expressible customizations into its
# dashboard.toml, on stdout one of MOVED or SKIPPED. Fails loudly when the
# toml exists but doesn't parse — appending to a broken file would pile a
# second error onto the first, and the dashboard keeps serving its last good
# table meanwhile, same as the VERDICT move above.
#
# Only what the new [theme]/[board] config expresses moves: a CSS var the
# fork sets to a value the template doesn't (same name, different value) goes
# under [theme], and a changed lane order or dropped lane goes under [board]
# as order/hidden. A var name the template no longer sets (--dusk and its kin
# in every old fork) is staleness, not choice — the new file never reads it,
# so moving it would pin a dead value nobody asked to keep, and it stays out.
# Everything else a fork carries (bead composer deltas, URL view-state,
# lane-logic changes, focus-ring rules, peer-scroll tweaks, dashboard.py
# diffs) is NOT guessed at: this moves config, never code, and the diverged
# line stays put — dropping it is a per-fork call for the owning session, not
# something a lossy re-copy may decide on its own.
#
# The [theme]/[board] shapes below follow scripts/dashboard.py's own readers
# ([theme] there, [board] there): full var names as quoted keys, lane keys in
# display order plus the missing lanes as hidden. The move only writes values
# those readers accept quietly — anything else stays in the diverged file with
# the line still on it, never silently dropped.
harness_migrate_dashboard_fork_config() {
  python3 - "$2/dashboard/index.html" "$1/dashboard/index.html" "$1/dashboard.toml" "$1/harness/diverged.txt" "$2/scripts/dashboard.py" <<'PYEOF'
import importlib.util
import re
import sys
import tomllib

tmpl_html_path, fork_html_path, toml_path, diverged_path, dashboard_py = sys.argv[1:6]

# The [theme]/[board] shapes below are checked by scripts/dashboard.py's own
# readers, imported here rather than mirrored — a second copy drifts until the
# migration writes a table the dashboard rejects. Definitions only, never the
# server (importing it starts nothing). When the import fails the migration
# skips rather than falling back to local copies.
try:
    spec = importlib.util.spec_from_file_location("dashboard_py", dashboard_py)
    db = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(db)
    _check_theme, _check_board = db._check_theme, db._check_board
    _BOARD_SECTIONS = db.BOARD_SECTIONS
except Exception:
    print("SKIPPED")
    sys.exit(0)


def skip():
    print("SKIPPED")
    sys.exit(0)


try:
    with open(diverged_path) as f:
        lines = f.read().splitlines()
except OSError:
    lines = []
# Same comment stripping as harness_diverged_want: a trailing reason stays
# readable without un-acknowledging the fork.
if "dashboard/index.html" not in [ln.split("#", 1)[0].strip() for ln in lines]:
    skip()
try:
    with open(fork_html_path) as f:
        fork_html = f.read()
except OSError:
    skip()
try:
    with open(tmpl_html_path) as f:
        tmpl_html = f.read()
except OSError:
    skip()
if fork_html == tmpl_html:
    skip()


def root_vars(html):
    """The first two :root blocks: the light one, then the dark one inside the
    @media query. A later block, if any, is not the theme — don't guess."""
    blocks = re.findall(r":root\s*\{(.*?)\}", html, re.S)
    out = []
    for block in blocks[:2]:
        out.append({k: v.strip()
                    for k, v in re.findall(r"(--[\w-]+)\s*:\s*([^;]+);", block)})
    while len(out) < 2:
        out.append({})
    return out


def toml_string(s):
    # A TOML literal string takes the value as-is, backslashes and all. Only a
    # value holding a single quote needs the basic form, escapes spelled out.
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


t_light = root_vars(tmpl_html)[0]
f_light = root_vars(fork_html)[0]
# Only values the dashboard reads quietly move: each candidate goes through
# the real [theme] reader, so the move can never write a table that complains
# on every poll. Same name, different value is a deliberate override the new
# file would lose; a name the template no longer sets is staleness, not
# choice. A dark-mode (@media) value has nowhere to go — [theme] applies flat,
# with no media query — so only the light block moves.
def theme_entry_ok(name, value):
    try:
        _check_theme({"theme": {name: value}})
    except ValueError:
        return False
    return True


theme_light = {k: v for k, v in f_light.items()
               if k in t_light and v != t_light[k]
               and theme_entry_ok(k, v)}


def lane_keys(html):
    # Row-by-row from the BEAD_LANES literal: a non-greedy bracket match stops
    # at the first inner ['...'] pair, so walk the lines instead. Unparseable
    # (renamed const, reshaped rows) means don't guess — no board move.
    m = re.search(r"const BEAD_LANES = \[", html)
    if not m:
        return None
    keys = []
    for line in html[m.end():].splitlines():
        if re.match(r"\s*\]", line):
            return keys
        km = re.match(r"\s*\['([\w]+)'", line)
        if km:
            keys.append(km.group(1))
        elif line.strip():
            return None
    return None


# A fork lane key off the dashboard's own section list (a custom lane the
# config cannot name) leaves the board half unmigrated: fail safe, migrate
# nothing for the board, keep the diverged line. The candidate goes through
# the real [board] reader before it is kept.
t_lanes = lane_keys(tmpl_html)
f_lanes = lane_keys(fork_html)
board = None
if (f_lanes is not None and t_lanes is not None and f_lanes != t_lanes
        and all(k in _BOARD_SECTIONS for k in f_lanes)):
    candidate = {"order": f_lanes,
                 "hidden": [k for k in t_lanes if k not in f_lanes]}
    try:
        _check_board({"board": candidate})
    except ValueError:
        board = None
    else:
        board = candidate

if not theme_light and board is None:
    skip()

try:
    with open(toml_path, "rb") as f:
        doc = tomllib.load(f)
except FileNotFoundError:
    doc = {}
except (OSError, tomllib.TOMLDecodeError) as e:
    print(f"✗ dashboard.toml exists but doesn't parse: {e}.", file=sys.stderr)
    print("  Fix it first — the fork-config move appends to that file.", file=sys.stderr)
    sys.exit(1)
if not isinstance(doc, dict):
    print("✗ dashboard.toml holds no table.", file=sys.stderr)
    print("  Fix it first — the fork-config move appends to that file.", file=sys.stderr)
    sys.exit(1)


def take_table(name):
    """Whether the [name] block below may be appended. A table the toml
    already has wins as-is — overwriting it would silently drop a hand edit,
    and a second run must be a no-op, not a duplicate table. A table header
    with no usable keys is already broken, so appending a second header would
    trap the values in an unparseable file: fail instead, before writing."""
    section = doc.get(name)
    if section is None:
        return True
    if not isinstance(section, dict) or not section:
        print(f"✗ dashboard.toml already has a [{name}] section but no usable values.",
              file=sys.stderr)
        print("  Fix it by hand — then re-run, or put the values there yourself.", file=sys.stderr)
        sys.exit(1)
    return False


blocks = []
if theme_light and take_table("theme"):
    lines = ["\n[theme]\n",
             "# Moved from dashboard/index.html by `harness update dashboard` —\n",
             "# CSS var overrides the template doesn't set. Keys are full var\n",
             "# names, read by scripts/dashboard.py.\n"]
    for k in sorted(theme_light):
        lines.append(f"{toml_string(k)} = {toml_string(theme_light[k])}\n")
    blocks.append("".join(lines))
if board is not None and take_table("board"):
    order = ", ".join(toml_string(k) for k in board["order"])
    lines = ["\n[board]\n",
             "# Moved from dashboard/index.html by `harness update dashboard` —\n",
             "# lane keys in the fork's display order; hidden names lanes the\n",
             "# fork doesn't show. Read by scripts/dashboard.py.\n",
             f"order = [{order}]\n"]
    if board["hidden"]:
        hidden = ", ".join(toml_string(k) for k in board["hidden"])
        lines.append(f"hidden = [{hidden}]\n")
    blocks.append("".join(lines))
if not blocks:
    skip()

try:
    with open(toml_path, "ab+") as f:
        f.seek(0, 2)
        if f.tell() > 0:
            f.seek(f.tell() - 1)
            if f.read(1) != b"\n":
                f.write(b"\n")
        for block in blocks:
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

  # A diverged dashboard/index.html's expressible customizations, moved into
  # dashboard.toml before the copy lands — same pattern as the VERDICT move
  # above. A file with nothing expressible reports SKIPPED and stays diverged;
  # only the toml grows, never the fork, so this is lossless either way.
  fork_migration="$(harness_migrate_dashboard_fork_config "$target" "$TEMPLATE")" || return 1
  fork_note=""
  case "$fork_migration" in
    MOVED) fork_note="  moved this project's dashboard theme/board customizations into dashboard.toml" ;;
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
  [ -n "$fork_note" ] && echo "$fork_note"
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
