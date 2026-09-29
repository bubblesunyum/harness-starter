#!/bin/bash
# Shared by `harness add` and `harness update`: everything both need to know
# about a target project and the template it came from. Sourced, never run.
#
# The two commands have to agree on all of it — what the file list is, which files
# are copied as-is and which carry the project's own answers, which files carry
# the contract — or `update` reports drift in files `add` never installed, which
# is a worse lie than saying nothing.

# Files the installer copies byte-for-byte and never compares. Three different
# reasons, all meaning "a difference here is not drift":
#   dashboard/vendor/*   third-party assets, copied whole, no substitution
#   dashboard.toml       project-owned run buttons; installed once, never touched
#   *.gitkeep            empty by definition
#   harness/laurels.jsonl  a log the project appends to; the template ships it empty
#   harness/diverged.txt   the acknowledged-fork list; the project edits it,
#                          the template ships it empty
harness_is_data() {
  case "$1" in
    dashboard/vendor/*|dashboard.toml|*/.gitkeep|.gitkeep|harness/laurels.jsonl|harness/diverged.txt) return 0 ;;
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

# Whether a project file carries bd's managed block. The template never does —
# add.sh's tidier removes it on the way in — so a block in the project's copy
# is content the template has no counterpart for, and overwriting the file
# deletes it. update --apply asks this before writing.
harness_has_beads_block() {
  grep -q "BEGIN BEADS" "$1" 2>/dev/null
}

# Project-owned overlays: the files a project's own answers live in. Installed
# once like everything else, but never compared and never converged — a
# difference here is the project, not drift, so `update` stays silent and
# `--apply` never writes. The base file each overlays stays a byte-identical
# contract file, which is what lets its fixes still arrive.
#
#   scripts/verify.steps.sh   the gate's project steps, sourced by verify.sh
#   scripts/review.scope.sh   what a review may see, sourced by review.sh
harness_is_overlay() {
  case "$1" in
    scripts/verify.steps.sh|scripts/review.scope.sh) return 0 ;;
    *) return 1 ;;
  esac
}

# The overlay file carrying a base script's project-owned block, or failure
# for any other file.
harness_overlay_of() {
  case "$1" in
    scripts/verify.sh) printf 'scripts/verify.steps.sh\n' ;;
    scripts/review.sh) printf 'scripts/review.scope.sh\n' ;;
    *) return 1 ;;
  esac
}

# Recover a pre-split project's inline block into its overlay file, on stdout
# what happened. A project from before the split carries its steps and scope
# inside scripts/verify.sh / scripts/review.sh, between the same marker boxes
# the new base files still carry as pointers — converging such a file would
# delete the project's own answers, which is the silent loss this exists to
# prevent.
#
# Succeeds silently when there is nothing to move: the overlay already exists,
# the script isn't there, the block is the pointer (then the template's overlay
# covers it — `add` installs that), or the block carries no answers. Moves the
# block when the project's file carries a filled one. Fails when the file
# differs but holds no block to lift — a fully rewritten script, a missing or
# duplicated marker — which the caller reports loudly instead of converging over.
harness_extract_overlay() {
  local here="$1" target="$2" rel="$3" overlay start end block baseblock tmp
  overlay="$(harness_overlay_of "$rel")" || return 0
  [ -e "$target/$overlay" ] && return 0
  [ -f "$target/$rel" ] || return 0
  case "$rel" in
    scripts/verify.sh) start="── PROJECT STEPS ──"; end="── END PROJECT STEPS ──" ;;
    scripts/review.sh) start="── CONFIGURE ──"; end="── END CONFIGURE ──" ;;
  esac
  # Exactly one block, in order: a missing end marker would lift to end-of-file,
  # a duplicated one would merge both copies with markers inside, and a swapped
  # pair would lift everything after the start line — and the base then
  # converges and deletes what the lift garbled. Count with -F: the boxes are
  # literal text, not a pattern.
  [ "$(grep -cF "$start" "$target/$rel")" -eq 1 ] || return 1
  [ "$(grep -cF "$end" "$target/$rel")" -eq 1 ] || return 1
  [ "$(grep -nF "$start" "$target/$rel" | head -1 | cut -d: -f1)" \
    -lt "$(grep -nF "$end" "$target/$rel" | head -1 | cut -d: -f1)" ] || return 1
  block="$(sed -n "/$start/,/$end/p" "$target/$rel" | sed '1d;$d')"
  baseblock="$(sed -n "/$start/,/$end/p" "$here/template/$rel" | sed '1d;$d')"
  [ "$block" = "$baseblock" ] && return 0
  # A filled block carries answers — real lines to run, not just comments. A
  # stale pointer carries none, and lifting it would strand a comment-only
  # overlay the gate then runs as zero steps and passes vacuously. Code lines
  # decide, not keywords: a comment mentioning `step "..."` is still a comment,
  # and steps or scopes spelled any valid way still count.
  printf '%s' "$block" | grep -qE '^[[:space:]]*[^#[:space:]]' || return 0
  tmp="$(mktemp "$target/.harness-extract-XXXXXX")" || return 1
  {
    printf '# Recovered from %s by the harness: this project'"'"'s own %s,\n' "$rel" \
      "$( [ "$rel" = scripts/verify.sh ] && printf 'gate steps' || printf 'review scope' )"
    printf '# moved here so the base file could converge. Edit freely — the harness\n'
    printf '# installs this file once and never compares or overwrites it.\n\n'
    printf '%s\n' "$block"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  # Renamed, not copied: the temp file sits beside the overlay, so the move is
  # a rename on the same filesystem — a half-written overlay (disk full, lost
  # NFS) would read as moved and block every later recovery, stranding the
  # steps it truncated.
  mv "$tmp" "$target/$overlay" || { rm -f "$tmp"; return 1; }
  printf '%s\n' "$overlay"
  return 0
}

# Everything else. These are the harness itself — the contract every agent reads
# (AGENTS.md, opencode.json), the machinery behind the scripts, the skills. The
# project has no reason to edit them, so a difference means the install is stale
# and a fix that shipped in the starter never arrived.
harness_is_contract() {
  local rel="$1" src="$2"
  harness_is_data "$rel" && return 1
  harness_is_overlay "$rel" && return 1
  harness_is_customised "$src" && return 1
  return 0
}

# How many lines a list holds. grep -c '' rather than wc -l, which counts
# newlines and calls a list without a trailing one empty.
harness_tally() { printf '%s' "$1" | grep -c ''; }

# Whether a path is on an acknowledged-forks list. The list, not the project,
# is the first argument, so both callers read the same way.
harness_in_diverged_list() {
  [ -n "${1:-}" ] && printf '%s\n' "$1" | grep -qxF "${2:-}"
}

# Resolve and validate a target project directory, echoing the resolved path.
# -P, so a symlink pointing at the starter can't slip past add.sh's guard by
# comparing unequal to the path it resolves to.
#
# With --init (harness add only), a directory with no .git gets one rather than
# an error: a repository is a dependency of the harness — the commit-msg hook
# and the review packet both need one — and installing a dependency is what an
# installer does. No commit is made; an empty repo installs fine, and the hook
# fires on the first real commit either way. The initial branch is main,
# regardless of the machine's init.defaultBranch. Refused when the target already
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
    # Explicit -b main rather than the machine's init.defaultBranch, which is
    # still master on machines that never set it. Git before 2.28 has no -b:
    # there, init with the local default and point the unborn HEAD at main
    # before any commit can land on the wrong name.
    (git -C "$target" init -q -b main >&2 || {
      git -C "$target" init -q >&2 &&
      git -C "$target" symbolic-ref HEAD refs/heads/main >&2
    }) || {
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
    # Read off `bd list`, never `bd config get`: config (and info) auto-import
    # a stale .beads/issues.jsonl when the ledger looks stale to them,
    # resurrecting deleted beads (har-67c), while list never imports.
    prefix="$(cd "$target" && bd list --json --all 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); i=(d[0].get("id","") if d else ""); print(i.split("-",1)[0] if "-" in i else "")' 2>/dev/null)" || true
    if [ -z "$prefix" ]; then
      # Empty (or missing) ledger: no bead id to read the prefix off, so fall
      # back to the configured one — this is what keeps a re-add from
      # re-running `bd init` on an initialised-but-empty ledger. Only fires
      # when list showed zero beads, i.e. a fresh clone (whose explicit import
      # follows in add.sh) or vanishingly rarely a ledger whose sole bead was
      # just deleted without a regen.
      prefix="$(cd "$target" && bd config get issue_prefix 2>/dev/null | tr -d '[:space:]')" || true
    fi
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

# Stack guidance: template/harness/stacks/<name>.md, one file per language or
# platform, holding the reviewer checks that only make sense there — force
# unwraps for Swift, innerHTML for the web. Installed only into projects that
# use the stack, because guidance for someone else's platform is worse than
# none: a reviewer told to check for retain cycles in a JavaScript page goes
# looking for them. Everything else in template/ ships to every project.
#
# Which stacks a project has is recorded in its harness/stacks.txt, not
# re-detected on every run. `add` writes it once from harness_detect_stacks, and
# from then on the list is the project's: a wrong guess is corrected by editing
# it, and a correction that the next `add` quietly re-detected away would be a
# setting nobody could make stick.

# The stack a template path belongs to, or failure for a file every project gets.
harness_stack_of() {
  case "$1" in
    harness/stacks/*.md) local name="${1#harness/stacks/}"; printf '%s\n' "${name%.md}" ;;
    *) return 1 ;;
  esac
}

# The stacks a project looks like it uses, one per line. Only markers that can't
# mean anything else: a package.json alone is as likely a CLI as a web app, so
# it counts only when it names a browser UI framework.
harness_detect_stacks() {
  local target="$1" page
  if [ -e "$target/Package.swift" ] ||
     [ -n "$(find "$target" -maxdepth 2 \( -name '*.xcodeproj' -o -name '*.xcworkspace' \) \
                 -not -path '*/.build/*' -print -quit 2>/dev/null)" ]; then
    echo swift
  fi
  for page in index.html public/index.html src/index.html app/index.html; do
    [ -f "$target/$page" ] && { echo web; return 0; }
  done
  if [ -f "$target/package.json" ] &&
     grep -qE '"(react|vue|svelte|@sveltejs/kit|next|nuxt|vite|astro|solid-js|preact|lit|@angular/core)"[[:space:]]*:' \
       "$target/package.json"; then
    echo web
  fi
  return 0
}

# The project's stacks from harness/stacks.txt, comments and blanks stripped, on
# stdout. Empty when the file is absent. Fails when it exists but can't be read —
# an unreadable list reading as "no stacks" would quietly drop every reviewer's
# platform checks. Silent on failure; the caller says whose fault it is.
harness_stacks_want() {
  local list="$1/harness/stacks.txt"
  [ -e "$list" ] || return 0
  [ -r "$list" ] || return 1
  sed -e 's/#.*//' "$list" | sed -e 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true
}

# harness/stacks.txt as `add` first writes it: what detection found, and how to
# correct it.
harness_write_stacks() {
  local target="$1" found="$2"
  mkdir -p "$target/harness"
  {
    echo "# The stacks this project is built on, one per line. The reviewers read the"
    echo "# guidance in harness/stacks/<name>.md for each one listed here."
    echo "#"
    echo "# harness add wrote this from what it found in the project, and never"
    echo "# rewrites it. If it guessed wrong, edit it; to pick up guidance for a stack"
    echo "# you added, re-run harness add. The names are the files in the starter's"
    echo "# template/harness/stacks/."
    # An if, not `&&`: with nothing found the test would be the group's status,
    # and add runs under set -e — a project with no stack stopped the install.
    if [ -n "$found" ]; then printf '%s\n' "$found"; fi
  } > "$target/harness/stacks.txt"
}

# Names in a project's stacks.txt that the template has no guidance for, one per
# line. A typo there otherwise installs nothing and says nothing.
#
# Checked against the names harness_stack_of derives from the file list — the
# same exact match harness_files_for installs by — not against the filesystem:
# on a case-insensitive disk `Web` finds web.md, and `../codex` finds a file
# outside stacks/, and both then install nothing while this called them known.
harness_unknown_stacks() {
  local here="$1" want="$2" known rel stack
  known="$(harness_template_files "$here" | while IFS= read -r rel; do
             harness_stack_of "$rel" || true
           done)" || return 1
  while IFS= read -r stack; do
    [ -n "$stack" ] || continue
    printf '%s\n' "$known" | grep -qxF -- "$stack" || printf '%s\n' "$stack"
  done <<< "$want"
}

# harness_template_files narrowed to one project: every file, except stack
# guidance for a stack the project doesn't list. What add installs, update
# compares and diverge will acknowledge.
harness_files_for() {
  local here="$1" target="$2" files want rel stack
  files="$(harness_template_files "$here")" || return 1
  want="$(harness_stacks_want "$target")" || return 1
  while IFS= read -r rel; do
    if stack="$(harness_stack_of "$rel")"; then
      printf '%s\n' "$want" | grep -qxF "$stack" || continue
    fi
    printf '%s\n' "$rel"
  done <<< "$files"
}

# A template file as it lands in a project, on stdout. Byte-for-byte, always:
# nothing in template/ is substituted anymore. Per-project values — the bead
# prefix, the /tmp paths, the title — resolve at runtime from the ledger and
# the checkout, so what ships is what's on disk here. That is what makes
# `update` a plain comparison and `--apply` a plain copy.
harness_render() {
  cat "$1"
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

# harness_same against a template source. The form the copy loop wants, where
# there is no installed file lying around to compare against — the template is
# rendered (copied) and compared.
harness_current() {
  local rel="$1" src="$2" dst="$3" rendered result
  rendered="$(mktemp)" || return 1
  harness_render "$src" > "$rendered"
  harness_same "$rel" "$rendered" "$dst" && result=0 || result=1
  rm -f "$rendered"
  return "$result"
}

# The project's acknowledged forks, one path per line, comments and blanks
# stripped, on stdout. Fails when the file exists but can't be read: an
# unreadable list silently un-acknowledging every fork is the false alarm this
# file exists to prevent. Silent on failure — the caller says whose fault it is.
harness_diverged_want() {
  local list="$1/harness/diverged.txt"
  [ -e "$list" ] || return 0
  [ -r "$list" ] || return 1
  sed -e 's/#.*//' "$list" | sed -e 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true
}

# missing | invalid | empty | ok for a target's per-role model roster, read
# through its own models.py — one parser, not two. Anything but ok suggests
# running ensure: agent.py runs and review budgets need a roster, though the
# generated agents never do. No python3, no models.py,
# any error: missing, which is the direction that suggests running ensure.
harness_roster_state() {
  python3 - "$1" 2>/dev/null <<'PYEOF' || echo missing
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
try:
    from models import roster_state
    print(roster_state())
except Exception:
    print("missing")
PYEOF
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
