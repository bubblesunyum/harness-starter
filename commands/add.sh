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
# skipped, so a re-run is a safe way to pick up pieces added since.
set -euo pipefail

# Derived from this file's own location, never from the environment. The
# dispatcher execs an already-resolved absolute path, so this is correct there
# too — and a command that took its root from an exported variable would install
# a different checkout's template whenever a stale one was lying around, with no
# error and no sign that it had happened.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMPLATE="$HERE/template"

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
pick up pieces added to the starter since.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

target="${1:-$PWD}"
[ -e "$target" ] || { echo "✗ no such path: $target" >&2; exit 1; }
[ -d "$target" ] || { echo "✗ not a directory: $target" >&2; exit 1; }
# -P, so a symlink pointing at the starter can't slip past the guard below by
# comparing unequal to the path it resolves to — that lets the installer write
# its own template files into its own checkout.
target="$(cd "$target" && pwd -P)"
[ -d "$target/.git" ] || {
  echo "✗ $target is not a git repository." >&2
  echo "  The commit-msg hook and the review packet both need one — run 'git init' first." >&2
  exit 1
}
# Installing into the starter itself is allowed on purpose — that is how the
# harness gets worked on with the harness. It is not free of a trap; see
# "Working on the starter" in the README.

name="$(basename "$target")"

# An existing ledger keeps the prefix it already has: every bead ever filed
# carries it, and a second one would orphan all of them.
# `|| true` because a `.beads` directory can exist without a database behind it
# — copied in, or left by an interrupted `bd init`. Without it the failing
# command substitution takes the whole script down under `set -e`, silently:
# stderr is already going to /dev/null, so the install just stops with no
# output, nothing copied, and no hook wired.
prefix=""
if [ -d "$target/.beads" ] && command -v bd >/dev/null 2>&1; then
  prefix="$(cd "$target" && bd config get issue_prefix 2>/dev/null | tr -d '[:space:]')" || true
fi
existing_prefix="$prefix"

# Otherwise derived from the directory name. Leading digits go because a prefix
# has to start with a letter, and the fallback exists because a name with no
# usable characters must not leave this empty: `bd init --prefix ""` exits 0 and
# leaves a ledger where every later command errors, and the commit-msg regex
# becomes `\b-[a-z0-9]+` — a word boundary before a bare dash, which nothing can
# ever match. That combination is a repo where no bead can be filed and no
# commit made without --no-verify.
if [ -z "$prefix" ]; then
  prefix="$(printf '%s' "$name" | tr 'A-Z' 'a-z' | tr -cd '[:alnum:]' | sed 's/^[0-9]*//' | cut -c1-3)"
  [ -n "$prefix" ] || prefix="bd"
fi

echo "installing the harness into $target"
echo "  project: $name"
echo "  prefix:  $prefix-"
echo

# What ships is what the repo says ships. `find` would also sweep up whatever a
# working checkout has left lying in template/ — __pycache__, once the dashboard
# has run — and a .pyc reaching the sed below dies with "illegal byte sequence"
# partway through the copy, leaving a half-installed project behind. Tracked
# files plus untracked ones git isn't ignoring: the set `git status` calls clean.
if ! git -C "$HERE" rev-parse --git-dir >/dev/null 2>&1; then
  echo "✗ $HERE is not a git checkout — the installer takes its file list from git." >&2
  exit 1
fi
files="$(git -C "$HERE" ls-files --cached --others --exclude-standard -- template | sort)"
if [ -z "$files" ]; then
  echo "✗ git lists no files under $HERE/template — nothing to install." >&2
  exit 1
fi

# git lists what the index knows about, which is not the same as what is on disk:
# a tracked file deleted and not yet staged is still listed. Checked here, before
# a single file is written, because the copy below redirects into the destination
# before sed reads the source — a missing source leaves a 0-byte file behind, and
# the never-overwrite guard then reads that as already installed on every re-run.
# Half an install that reports success is the failure this whole script is shaped
# to avoid.
missing="$(while IFS= read -r rel; do
  [ -f "$HERE/$rel" ] || echo "  $rel"
done <<< "$files")"
if [ -n "$missing" ]; then
  echo "✗ git lists files that aren't on disk in $HERE:" >&2
  echo "$missing" >&2
  echo "  restore them (git checkout -- template) or stage the deletions, then re-run." >&2
  exit 1
fi

copied=0; skipped=0
while IFS= read -r rel; do
  rel="${rel#template/}"
  src="$TEMPLATE/$rel"
  dst="$target/$rel"
  if [ -e "$dst" ]; then
    echo "  skip  $rel (already there)"
    skipped=$((skipped + 1))
    continue
  fi
  mkdir -p "$(dirname "$dst")"
  # Binaries and vendored assets are copied whole; only text gets substituted.
  case "$rel" in
    dashboard/vendor/*) cp "$src" "$dst" ;;
    *) sed -e "s/{{PROJECT}}/$name/g" \
           -e "s/{{PREFIX_UPPER}}/$(printf '%s' "$prefix" | tr 'a-z' 'A-Z')/g" \
           -e "s/{{PREFIX}}/$prefix/g" "$src" > "$dst" ;;
  esac
  [ -x "$src" ] && chmod +x "$dst"
  echo "  add   $rel"
  copied=$((copied + 1))
done <<< "$files"

echo
echo "  $copied added, $skipped skipped"
echo

# The hook lives in scripts/ and is pointed at, rather than copied into
# .git/hooks — beads rewrites that directory on upgrade and would eat it.
hook="$target/.git/hooks/commit-msg"
delegate='exec "$(git rev-parse --show-toplevel)"/scripts/hooks/commit-msg "$@"'
if [ -e "$hook" ] && grep -qF "$delegate" "$hook"; then
  echo "  commit-msg hook already wired"
elif [ -e "$hook" ]; then
  # Someone else's hook. Left alone rather than merged into: it is the one file
  # here that can block every commit in the repo if it is got wrong.
  echo "  ! .git/hooks/commit-msg exists — add this line to it yourself:"
  echo "      exec \"\$(git rev-parse --show-toplevel)\"/scripts/hooks/commit-msg \"\$@\""
else
  printf '#!/bin/bash\n%s\n' "$delegate" > "$hook"
  chmod +x "$hook"
  echo "  wired the commit-msg hook"
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

if command -v bd >/dev/null 2>&1; then
  # Keyed on whether a prefix came back above, not on `.beads` existing: the
  # directory can be there with no database behind it, and reporting that as an
  # initialised ledger is how you find out later, one failing `bd` at a time.
  if [ -n "$existing_prefix" ]; then
    echo "  ledger already initialised ($prefix-)"
  elif (cd "$target" && bd init --prefix "$prefix" >/dev/null 2>&1); then
    echo "  initialised the ledger ($prefix-)"
  else
    echo "  ! bd init failed — run 'bd init --prefix $prefix' yourself and check the error."
  fi
else
  echo "  ! bd is not installed — the ledger, the brief, and the commit hook all need it."
  echo "    See https://github.com/steveyegge/beads"
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

2. CLAUDE.snippet.md — paste its three sections into CLAUDE.md, delete the file.
   They have to be always-loaded; everything else about the harness lives
   behind the `workflow` skill and should stay there.

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
