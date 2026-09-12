#!/bin/bash
# Shared by `harness add` and `harness update`: everything both need to know
# about a target project and the template it came from. Sourced, never run.
#
# The two commands have to agree on all of it — what the file list is, what the
# placeholders become, which files carry the contract — or `update` reports
# drift in files `add` never installed, which is a worse lie than saying nothing.

# Files the installer copies byte-for-byte and never compares. Two different
# reasons, both meaning "a difference here is not drift":
#   dashboard/vendor/*   third-party assets, copied whole, no substitution
#   *.gitkeep            empty by definition
#   harness/laurels.jsonl  a log the project appends to; the template ships it empty
harness_is_data() {
  case "$1" in
    dashboard/vendor/*|*/.gitkeep|.gitkeep|harness/laurels.jsonl) return 0 ;;
    *) return 1 ;;
  esac
}

# A template file carrying a FILL THIS IN block is one the install instructions
# tell the project to edit — verify.sh's build steps, the reviewers' recurring
# bugs, the seat's name. Those files differing from the template is the harness
# working, not failing.
#
# Read off the template's own content rather than kept as a list here, so adding
# a fill-in block to a file is all it takes: a list would go stale in exactly the
# direction that produces false alarms, and false alarms are how a warning stops
# being read.
#
# Matched with the block's box rule rather than on the bare words, which caught
# .claude/HARNESS.md the moment it started *describing* this rule — prose about
# the marker is not the marker, and the file quietly dropped out of the contract
# set as a result.
harness_is_customised() {
  grep -q "── FILL THIS IN" "$1" 2>/dev/null
}

# Everything else. These are the harness itself — the contract every agent reads
# (AGENTS.md, opencode.json), the machinery behind the scripts, the skills. The
# project has no reason to edit them, so a difference means the install is stale
# and a fix that shipped in the starter never arrived.
harness_is_contract() {
  local rel="$1" src="$2"
  harness_is_data "$rel" && return 1
  harness_is_customised "$src" && return 1
  return 0
}

# Resolve and validate a target project directory, echoing the resolved path.
# -P, so a symlink pointing at the starter can't slip past add.sh's guard by
# comparing unequal to the path it resolves to.
#
# With --init (harness add only), a directory with no .git gets one rather than
# an error: a repository is a dependency of the harness — the commit-msg hook
# and the review packet both need one — and installing a dependency is what an
# installer does. No commit is made; an empty repo installs fine, and the hook
# fires on the first real commit either way. Refused when the target already
# sits inside another repository's working tree, where a nested repository is a
# mess nobody asked for — that refusal names the toplevel. A bare check never
# inits: `harness update` only reports, and a command that only reports must not
# create repositories as a side effect.
harness_resolve_target() {
  local init=0
  if [ "${1:-}" = "--init" ]; then init=1; shift; fi
  local target="${1:-}"
  [ -n "$target" ] || { echo "✗ no target directory given" >&2; return 1; }
  [ -e "$target" ] || { echo "✗ no such path: $target" >&2; return 1; }
  [ -d "$target" ] || { echo "✗ not a directory: $target" >&2; return 1; }
  target="$(cd "$target" && pwd -P)"
  # Whether this is a repository is git's call, not the filesystem's: a
  # directory named .git that rev-parse won't vouch for — half a `git init`, a
  # stray file, a moved worktree's pointer — is a broken state, and trusting
  # the name alone installs a harness onto a repository that doesn't work.
  local toplevel
  toplevel="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null || true)"
  # The toplevel names the target itself for a plain repository, a linked
  # worktree, and a submodule alike — .git is a file in the latter two, which
  # is why the check reads rev-parse rather than testing for a directory. Any
  # of those already is a repository; installing there is fine, and calling a
  # worktree nested would send whoever reads it after the wrong bug.
  if [ -n "$toplevel" ] && [ "$toplevel" = "$target" ]; then
    printf '%s\n' "$target"
    return 0
  fi
  # A .git entry git itself rejects, with no working tree above it either.
  # Repairing that here would be guessing about a state git already calls
  # broken — an empty .git costs nothing to recreate properly, and a strange
  # one deserves a look before anything builds on it. Say so instead.
  if [ -z "$toplevel" ] && [ -e "$target/.git" ]; then
    echo "✗ $target has a .git entry but is not a git working tree." >&2
    echo "  Remove it, or run 'git init' there yourself once it looks right." >&2
    return 1
  fi
  if [ "$init" -eq 1 ]; then
    # A bare repository has no working tree and no .git entry, so the checks
    # above pass it through — and `git init` would then happily create a .git
    # inside it and copy a working tree's files around it. Refuse first.
    if [ "$(git -C "$target" rev-parse --is-bare-repository 2>/dev/null || true)" = "true" ]; then
      echo "✗ $target is a bare git repository — harness add needs a working tree." >&2
      echo "  The harness installs files, and a bare repository has nowhere to put them." >&2
      return 1
    fi
    if [ -n "$toplevel" ]; then
      echo "✗ $target is inside the git repository at $toplevel." >&2
      echo "  harness add never creates a nested repository — pick a directory outside it." >&2
      return 1
    fi
    git -C "$target" init -q >&2 || {
      echo "✗ couldn't git init $target — run 'git init' there yourself." >&2
      return 1
    }
    printf '%s\n' "$target"
    return 0
  fi
  # A bare repository takes its own refusal: 'git init' is the corruption the
  # add guard above exists to prevent, so it must not be the advice here.
  if [ "$(git -C "$target" rev-parse --is-bare-repository 2>/dev/null || true)" = "true" ]; then
    echo "✗ $target is a bare git repository — this needs a working tree." >&2
    echo "  Pick a working-tree directory instead." >&2
    return 1
  fi
  echo "✗ $target is not a git repository." >&2
  echo "  The commit-msg hook and the review packet both need one — run 'git init' first." >&2
  return 1
}

# The prefix a project's ledger already uses, or empty if it has none. Every bead
# ever filed carries it, so an existing ledger keeps it — a second prefix would
# orphan all of them.
#
# `|| true` because a `.beads` directory can exist without a database behind it —
# copied in, or left by an interrupted `bd init`. Without it the failing command
# substitution takes the caller down under `set -e`, silently.
harness_ledger_prefix() {
  local target="$1" prefix=""
  if [ -d "$target/.beads" ] && command -v bd >/dev/null 2>&1; then
    prefix="$(cd "$target" && bd config get issue_prefix 2>/dev/null | tr -d '[:space:]')" || true
  fi
  printf '%s\n' "$prefix"
}

# A prefix derived from the project's directory name. Leading digits go because a
# prefix has to start with a letter, and the fallback exists because a name with
# no usable characters must not leave this empty: `bd init --prefix ""` exits 0
# and leaves a ledger where every later command errors, and the commit-msg regex
# becomes `\b-[a-z0-9]+` — a word boundary before a bare dash, which nothing can
# ever match. That combination is a repo where no bead can be filed and no commit
# made without --no-verify.
harness_derive_prefix() {
  local prefix
  prefix="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cd '[:alnum:]' | sed 's/^[0-9]*//' | cut -c1-3)"
  [ -n "$prefix" ] || prefix="bd"
  printf '%s\n' "$prefix"
}

# The prefix a project's files were substituted with: the ledger's, or the
# derived one. What `update` has to reproduce to compare anything.
harness_prefix_for() {
  local prefix
  prefix="$(harness_ledger_prefix "$1")"
  [ -n "$prefix" ] || prefix="$(harness_derive_prefix "$2")"
  printf '%s\n' "$prefix"
}

# The template's file list, as paths relative to template/, one per line.
#
# What ships is what the repo says ships. `find` would also sweep up whatever a
# working checkout has left lying in template/ — __pycache__, once the dashboard
# has run — and a .pyc reaching the substitution dies with "illegal byte
# sequence" partway through the copy, leaving a half-installed project behind.
# Tracked files plus untracked ones git isn't ignoring: the set `git status`
# calls clean.
#
# git lists what the index knows about, which is not the same as what is on disk:
# a tracked file deleted and not yet staged is still listed. Checked here, before
# a caller writes a single file, because add.sh's copy redirects into the
# destination before sed reads the source — a missing source leaves a 0-byte file
# behind, and the never-overwrite guard then reads that as already installed on
# every re-run.
harness_template_files() {
  local here="$1" files missing
  if ! git -C "$here" rev-parse --git-dir >/dev/null 2>&1; then
    echo "✗ $here is not a git checkout — the file list comes from git." >&2
    return 1
  fi
  files="$(git -C "$here" ls-files --cached --others --exclude-standard -- template | sort)"
  if [ -z "$files" ]; then
    echo "✗ git lists no files under $here/template — nothing to install." >&2
    return 1
  fi
  missing="$(while IFS= read -r rel; do
    [ -f "$here/$rel" ] || echo "  $rel"
  done <<< "$files")"
  if [ -n "$missing" ]; then
    echo "✗ git lists files that aren't on disk in $here:" >&2
    echo "$missing" >&2
    echo "  restore them (git checkout -- template) or stage the deletions, then re-run." >&2
    return 1
  fi
  printf '%s\n' "$files" | sed 's|^template/||'
}

# A template file as it would land in this project, on stdout. Binaries and
# vendored assets are copied whole; only text gets substituted.
harness_render() {
  local rel="$1" src="$2" name="$3" prefix="$4"
  case "$rel" in
    dashboard/vendor/*) cat "$src"; return ;;
  esac
  sed -e "s/{{PROJECT}}/$name/g" \
      -e "s/{{PREFIX_UPPER}}/$(printf '%s' "$prefix" | tr 'a-z' 'A-Z')/g" \
      -e "s/{{PREFIX}}/$prefix/g" "$src"
}

# Whether a target file still matches what the template would produce.
#
# Not just `cmp`, because the installer mutates two kinds of file after copying
# them and would otherwise report every fresh install as stale — which is the
# false alarm that teaches everyone to ignore the warning:
#
#   *.md    `bd` leaves its managed block in AGENTS.md. That block is
#           beads' to maintain, not the harness's, so it is ignored on both
#           sides — the same BEGIN/END pair add.sh's tidier already knows about.
#   *.json  the tidier rewrites .claude/settings.json through json.dumps, which
#           reorders every key. Same settings, different bytes.
#
# Anything else is compared byte for byte.
harness_same() {
  local rel="$1" a="$2" b="$3" na nb result
  cmp -s "$a" "$b" && return 0
  case "$rel" in
    *.md|*.json) ;;
    *) return 1 ;;
  esac
  na="$(mktemp)" && nb="$(mktemp)" || return 1
  harness_normalise "$rel" "$a" > "$na"
  harness_normalise "$rel" "$b" > "$nb"
  cmp -s "$na" "$nb" && result=0 || result=1
  rm -f "$na" "$nb"
  return "$result"
}

# A file with the installer's own post-copy edits taken back out, on stdout. What
# harness_same compares, and what the diff shows — so the diff shows the same
# difference the warning is about, rather than re-raising the block it ignored.
#
# Without python3 the normalisation can't run and the file passes through whole:
# a project may then be told a file differs when it doesn't, which is the safe
# direction to be wrong in.
harness_normalise() {
  local rel="$1" src="$2"
  case "$rel" in
    *.md|*.json) ;;
    *) cat "$src"; return ;;
  esac
  command -v python3 >/dev/null 2>&1 || { cat "$src"; return; }
  python3 - "$rel" "$src" <<'PYEOF' || cat "$src"
import json
import re
import sys

# Requires the closing marker, so a file carrying an unclosed BEGIN passes
# through whole rather than being silently truncated from that line down —
# which would hide every real difference below it.
BLOCK = re.compile(r"<!-- BEGIN BEADS.*?<!-- END BEADS[^>]*-->\n*", re.S)
rel, src = sys.argv[1], sys.argv[2]

text = open(src).read()
if rel.endswith(".json"):
    # Unparseable JSON falls through to the raw file: differing is then the
    # honest answer, and it says look at the file, which is right either way.
    text = json.dumps(json.loads(text), indent=2, sort_keys=True)
else:
    text = BLOCK.sub("", text).rstrip()
sys.stdout.write(text + "\n")
PYEOF
}

# harness_same against a template source, rendering it on the way. The form the
# copy loop wants, where there is no rendered file lying around to compare.
harness_current() {
  local rel="$1" src="$2" dst="$3" rendered result
  rendered="$(mktemp)" || return 1
  harness_render "$rel" "$src" "$HARNESS_NAME" "$HARNESS_PREFIX" > "$rendered"
  harness_same "$rel" "$rendered" "$dst" && result=0 || result=1
  rm -f "$rendered"
  return "$result"
}

# The Dolt remote URL for a git origin. bd speaks its own dialect: a `git+`
# scheme prefix, and no scp-style shorthand — `bd dolt remote add` rejects
# `git@github.com:org/repo.git` outright ("first path segment in URL cannot
# contain colon"), so the form every `git clone` prints has to be rewritten into
# a real ssh:// URL before bd will take it.
#
# Empty for anything unrecognised rather than a guess. A wrong remote pushes the
# ledger somewhere nobody will look for it, and reports success doing it.
harness_dolt_remote_url() {
  local url="$1"
  case "$url" in
    git+*)                        printf '%s\n' "$url" ;;
    https://*|http://*|ssh://*|file://*)
                                  printf 'git+%s\n' "$url" ;;
    *@*:*)                        printf 'git+ssh://%s/%s\n' "${url%%:*}" "${url#*:}" ;;
    /*)                           printf 'git+file://%s\n' "$url" ;;
    *)                            printf '\n' ;;
  esac
}
