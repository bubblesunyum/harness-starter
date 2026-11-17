#!/bin/bash
# Helpers for `harness migrate`: turning a copy install into a reference one.
# Sourced, never run. Read-only against install.sh — nothing here edits it.
#
# A migrate keeps what the project owns (seeds, data, acknowledged forks, own
# files), deletes byte-identical copies of the shared harness, lifts reviewer
# customisations into overlays, and swaps the contract for reference stubs.
# Anything that differs without acknowledgment is left in place and named.

# The reviewer role a reviewer prompt file belongs to, on stdout. Fails loudly
# for any other file: a new reviewer prompt must lift into harness/reviewers/,
# never fall through to generic remove/name handling as a same-path shadow.
migrate_role_of() {
  case "$1" in
    taste|correctness|design) printf '%s\n' "$1" ;;
    *)
      echo "✗ unknown reviewer role: $1 — add it here so the prompt lifts into harness/reviewers/." >&2
      return 1
      ;;
  esac
}

# Whether a project-relative path is one `add --reference` writes. Derived
# from harness_reference_files, not a second list: the next file added there
# classifies here too, instead of silently misclassifying as keep/name.
# Cached in one variable, matched with a case — a migrate classifies a hundred
# files and a grep per file would be a fork per file.
migrate_is_reference_path() {
  if [ -z "${_MIGRATE_REFERENCE_PATHS:-}" ]; then
    _MIGRATE_REFERENCE_PATHS="|$(harness_reference_files | tr '\n' '|')" || return 1
  fi
  case "$_MIGRATE_REFERENCE_PATHS" in
    *"|$1|"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Lines of a project's reviewer prompt with no counterpart in the shared
# prompt, kept in order, into the role's overlay. On stdout the lifted count.
#
#   migrate_lift <project> <shared> <overlay> <rel> <count|write>
#
# count only reports, for the dry run. write creates the overlay — or appends
# under a dated header when it already exists — and reports. The caller
# removes the prompt afterwards, so a second run finds a link and skips it.
# An empty lift reports 0 and writes nothing: the prompt added nothing over
# the shared one, so there is no overlay to keep.
migrate_lift() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PYEOF' || return 1
import datetime
import os
import sys

proj_path, shared_path, overlay_path, rel, mode = sys.argv[1:6]
shared = set(open(shared_path).read().splitlines())
new = [line for line in open(proj_path).read().splitlines()
       if line not in shared]
if mode == "count" or not new:
    print(len(new))
    sys.exit(0)
exists = os.path.exists(overlay_path)
parent = os.path.dirname(overlay_path)
if parent:
    os.makedirs(parent, exist_ok=True)
if exists:
    header = ("\n# Lifted from %s by harness migrate on %s:\n"
              "# the lines below occur in that file but not in the shared\n"
              "# prompt. Prune what the shared prompt now covers; keep only\n"
              "# this project's own checks.\n"
              % (rel, datetime.date.today().isoformat()))
    with open(overlay_path, "a") as handle:
        handle.write(header + "\n".join(new) + "\n")
else:
    header = ("# Lifted from %s by harness migrate: the lines below occur in\n"
              "# that file but not in the shared prompt. Prune what the shared\n"
              "# prompt now covers; keep only this project's own checks.\n"
              % rel)
    with open(overlay_path, "w") as handle:
        handle.write(header + "\n".join(new) + "\n")
print(len(new))
PYEOF
}

# The shared checkout a migrate links against, on stdout. Env-only, no fetch:
# a migrate must fail before writing anything when the harness is nowhere,
# the way `add --reference` does — never clone the network as a side effect.
migrate_reference_root() {
  local target="$1"
  # A starter checkout migrates against its own template/ first, like the
  # finder, so converting the starter needs no machine setup.
  if [ -f "$target/template/.harness-root" ]; then
    (cd "$target/template" && pwd -P)
    return 0
  fi
  if [ -n "${HARNESS_HOME:-}" ]; then
    if [ -f "$HARNESS_HOME/template/.harness-root" ]; then
      (cd "$HARNESS_HOME/template" && pwd -P)
      return 0
    fi
    echo "✗ HARNESS_HOME=$HARNESS_HOME is not a harness checkout (no template/.harness-root)." >&2
    echo "  Point it at a harness-starter clone, or unset it." >&2
    return 1
  fi
  if [ -n "${HOME:-}" ] && { [ -e "$HOME/.harness" ] || [ -L "$HOME/.harness" ]; }; then
    if [ -f "$HOME/.harness/template/.harness-root" ]; then
      (cd "$HOME/.harness/template" && pwd -P)
      return 0
    fi
    echo "✗ ~/.harness is not a harness checkout (no template/.harness-root)." >&2
    echo "  Replace it with a harness-starter clone, or set HARNESS_HOME." >&2
    return 1
  fi
  if [ -e "$target/.harness" ] || [ -L "$target/.harness" ]; then
    if [ -f "$target/.harness/template/.harness-root" ]; then
      (cd "$target/.harness/template" && pwd -P)
      return 0
    fi
    echo "✗ $target/.harness is a stale fetch (no template/.harness-root)." >&2
    echo "  Remove it and set HARNESS_HOME, or re-fetch it." >&2
    return 1
  fi
  echo "✗ migrate --apply needs the shared harness and cannot find it." >&2
  echo "  Set HARNESS_HOME to a harness-starter clone, or link one at ~/.harness." >&2
  return 1
}

# What the shared codex generator would write for one agent, on stdout.
# Compared against the project's .codex/agents/<name>.toml: a generated file
# that matches is derived output, one that doesn't is named, never deleted.
migrate_codex_expected() {
  python3 - "$1" "$2" "$3" <<'PYEOF' || return 1
import importlib.util
import sys
from pathlib import Path

here, name, out = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location(
    "harness_codex_support",
    str(Path(here) / "template/scripts/codex-support.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = Path(here) / "template"
Path(out).write_text(
    module.agent_text(root / ".claude/agents" / (name + ".md"), root))
PYEOF
}

# Bring kept hook files back to the reference shape without touching project
# answers: strip bd's managed blocks from the instruction files and drop bd's
# own hook entries, the way `add` tidies what bd installs. Additive only —
# a kept file that still points at removed scripts is named, never rewritten.
# Prints one tidy line per file changed, nothing when already clean.
migrate_tidy_reference() {
  python3 - "$1" <<'PYEOF' || return 1
import json
import re
import sys
from pathlib import Path

BLOCK = re.compile(r"<!-- BEGIN BEADS.*?<!-- END BEADS[^>]*-->\n*", re.S)
target = Path(sys.argv[1])

for name in ("CLAUDE.md", "AGENTS.md"):
    doc = target / name
    if not doc.exists():
        continue
    try:
        text = doc.read_text()
    except OSError as exc:
        print("  ! %s unreadable (%s) — left alone" % (name, exc),
              file=sys.stderr)
        continue
    if BLOCK.search(text):
        doc.write_text(BLOCK.sub("", text).rstrip() + "\n")
        print("  tidy    %s — removed the duplicate beads block" % name)

for name in (".codex/hooks.json", ".claude/settings.json"):
    doc = target / name
    if not doc.exists():
        continue
    try:
        config = json.loads(doc.read_text())
    except (OSError, ValueError) as exc:
        print("  ! %s does not parse (%s) — left alone" % (name, exc),
              file=sys.stderr)
        continue
    hooks = config.get("hooks") if isinstance(config, dict) else None
    # Valid JSON of an unexpected shape is left alone, loudly: aborting here,
    # after the deletes, would strand a half-migrated tree with no links.
    if not isinstance(hooks, dict) or not all(
            isinstance(g, list) and all(isinstance(x, dict) and isinstance(x.get("hooks", []), list) for x in g)
            for g in hooks.values()):
        if hooks not in (None, {}):
            print("  ! %s has an unexpected hooks shape — left alone; check it by hand" % name,
                  file=sys.stderr)
        continue
    removed = False
    for event, groups in list(hooks.items()):
        kept = []
        for group in groups:
            # bd's generic hooks, and the per-project dashboard hooks: there
            # is one dashboard now, run from the starter, and a project's
            # scripts/dashboard.py is gone after migration.
            entries = [h for h in group.get("hooks", [])
                       if not isinstance(h, dict) or not re.search(r"\bbd\s+(?:codex-hook|prime)\b"
                                        r"|scripts/dashboard\.py\s+(?:up|down)\b"
                                        r"|scripts/harness\s+dashboard\b",
                                        str(h.get("command", "")))]
            removed |= len(entries) != len(group.get("hooks", []))
            if entries:
                kept.append({**group, "hooks": entries})
        if kept:
            hooks[event] = kept
        else:
            hooks.pop(event)
    if removed:
        doc.write_text(json.dumps(config, indent=2) + "\n")
        print("  tidy    %s — dropped generic beads and per-project dashboard hooks" % name)
PYEOF
}

# Whether a project file is an unedited copy of a shared file at any starter
# revision, not just today's. Old installs carry copies from older revisions,
# and byte-comparing against today alone reads every one of them as edited.
#
#   migrate_historic_sha <starter> <rel> <project-file> <cache-dir>
#
# prints the short sha of the newest commit whose template/<rel> blob is
# byte-identical to the project file — "worktree" when it matches the working
# tree but no commit (a dirty checkout) — and fails otherwise. The caller
# decides the fate; a file differing only in baked install-time substitutions
# never matches a blob, so it stays named, never removed.
#
# The blob set is one "blobhex commit" file per path under the cache dir the
# caller owns, so a dry run walks each file's history once. --follow pulls the
# blobs from before a rename too, when the file once lived outside template/.
# A starter without history (or a log failure) simply never matches: the file
# stays named, which is the safe direction to be wrong in.
migrate_historic_sha() {
  local starter="$1" rel="$2" dst="$3" cache="$4" list blob line want
  want="$(git hash-object "$dst" 2>/dev/null)" || return 1
  list="$cache/$rel"
  if [ ! -f "$list" ]; then
    mkdir -p "$(dirname "$list")" || return 1
    # Newest commit first; the first commit listed per blob wins. --no-abbrev
    # keeps the raw blob ids whole for the comparison below, which also leaves
    # %h whole — so the cache holds the full commit and the short form is
    # derived once, below, only for the commit that actually matched.
    git -C "$starter" log --all --format='COMMIT %H' --raw --no-abbrev \
      --follow -- "template/$rel" 2>/dev/null | awk '
      /^COMMIT / { commit=$2; next }
      /^:/ { blob=$4; if (blob !~ /^0+$/ && !seen[blob]++) print blob" "commit }
    ' > "$list" || return 1
    # The working tree is the comparison for everything else, so it belongs
    # in the set: usually it duplicates the newest commit and adds nothing.
    # A worktree-only blob (a dirty checkout) has no commit; label it so the
    # caller can say "identical" instead of naming a revision it never
    # shipped in.
    # A path the starter has since deleted (the old copy-install configs) has
    # no working-tree blob; its history alone still identifies old copies.
    if [ -f "$starter/template/$rel" ]; then
      blob="$(git hash-object "$starter/template/$rel" 2>/dev/null)" || return 1
      if ! grep -q "^$blob " "$list" 2>/dev/null; then
        printf '%s worktree\n' "$blob" >> "$list" || return 1
      fi
    fi
  fi
  line="$(grep -m1 "^$want " "$list" 2>/dev/null)" || return 1
  [ -n "$line" ] || return 1
  line="${line##* }"
  if [ "$line" != worktree ]; then
    line="$(git -C "$starter" rev-parse --short "$line" 2>/dev/null)" || return 1
  fi
  printf '%s\n' "$line"
}

# The newest starter commit that still shipped template/<rel>, on stdout: HEAD
# while the path still exists there, else the parent of the commit that deleted
# it. Fails when history holds no such commit (a shallow clone). One
# resolution for two readers: migrate_last_shipped shows the content at this
# revision, and the migrate probe archives the whole tree at it.
migrate_last_shipped_rev() {
  local starter="$1" rel="$2" rev
  if git -C "$starter" cat-file -e "HEAD:template/$rel" 2>/dev/null; then
    git -C "$starter" rev-parse HEAD
    return
  fi
  rev="$(git -C "$starter" rev-list -1 HEAD -- "template/$rel")" || return 1
  [ -n "$rev" ] || return 1
  git -C "$starter" rev-parse "$rev^"
}

# The last content the starter shipped at template/<rel>, for a path it has
# since deleted: the revision above resolves HEAD-vs-deleted, this shows it.
migrate_last_shipped() {
  local starter="$1" rel="$2" rev
  rev="$(migrate_last_shipped_rev "$starter" "$rel")" || return 1
  git -C "$starter" show "$rev:template/$rel"
}

# An acknowledged fork the migrate honors, on stdin, as project-relative
# paths: nothing else may claim a diverged entry. Kept beside the read above
# because both callers read the same way.
#
# A diverged entry that acknowledges nothing: not a template file the migrate
# classifies (typo, removed file, or a path outside template/), or one
# already quiet (data, overlay, or FILL THIS IN, nothing to acknowledge).
# Either way the acknowledgment does nothing, so the list is broken and says
# so loudly before anything is written — a typo silently un-acknowledging the
# fork it meant is the failure this prevents.
migrate_validate_diverged() {
  local files="$1" want bad=""
  while IFS= read -r want; do
    [ -n "$want" ] || continue
    if ! printf '%s\n' "$files" | grep -qxF "$want"; then
      bad="$bad  $want (no such template file)"$'\n'
    elif ! harness_is_contract "$want" "$TEMPLATE/$want"; then
      bad="$bad  $want (already quiet — data, overlay, or FILL THIS IN, nothing to acknowledge)"$'\n'
    fi
  done <<< "$2"
  if [ -n "$bad" ]; then
    echo "✗ $(printf '%s' "$bad" | grep -c . || true) diverged entry(s) acknowledge nothing — typo, removed file, or a file already quiet:" >&2
    printf '%s' "$bad" >&2
    echo "  Fix harness/diverged.txt and re-run." >&2
    return 1
  fi
  return 0
}

# Append one gitignore line with its comment, like `add` does. Silent when
# already there; one tidy line when added.
migrate_append_ignore() {
  local target="$1" path="$2" comment="$3" ignore="$1/.gitignore"
  if [ -e "$ignore" ] && grep -qxF "$path" "$ignore"; then
    return 0
  fi
  # A file without a trailing newline would glue the append onto its last
  # line; command substitution strips newlines, so non-empty means missing.
  if [ -e "$ignore" ] && [ -n "$(tail -c 1 "$ignore")" ]; then
    printf '\n' >> "$ignore" || return 1
  fi
  printf '\n# %s\n%s\n' "$comment" "$path" >> "$ignore" || return 1
  echo "  tidy    .gitignore — now ignores $path"
}
