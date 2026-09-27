#!/bin/bash
# Builds the review packet: everything a reviewing agent needs about a change,
# in one file, so it doesn't spend a dozen tool calls rediscovering the diff.
#
#   scripts/review.sh                 # working tree vs HEAD
#   scripts/review.sh HEAD~3          # since a commit
#   scripts/review.sh master          # since a branch (use on a feature branch)
#
# Prints the packet path. Hand that to the reviewer agents — see the
# agentic-review skill. Refuses (non-zero) when the packet exceeds the
# smallest reviewer budget instead — see below.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Per-role models live machine-locally in harness/models.json, and a fresh
# clone has none. First review writes it (prompting in a terminal, guidance
# otherwise); later runs are silent — so the reviewers below always know what
# they run on, and the gate's agent check has something to compare against.
# Stderr stays visible: the no-terminal guidance and any traceback are the
# signal here, not noise. `|| true` only keeps a failing ensure from taking
# the packet down with it.
scripts/models.py ensure || true

# BSD and GNU disagree on both of these, and a starter shouldn't only run on the
# machine it was written on.
mtime() { stat -f '%m' "$@" 2>/dev/null || stat -c '%Y' "$@"; }
stamp() { date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$1" +%Y%m%d%H%M.%S; }

base="${1:-}"
# The ledger's bead prefix, asked of the ledger itself at runtime — baked into
# this file once per install, which made every copy differ and un-updatable.
# Falls back to the directory name, derived the same way `harness add` does.
_harness_prefix() {
  local p=""
  if command -v bd >/dev/null 2>&1; then
    p="$(bd config get issue_prefix 2>/dev/null | tr -d '[:space:]')" || true
  fi
  if ! printf '%s' "$p" | grep -qE '^[a-z0-9]{1,10}$'; then
    # Physical path, matching what `harness add` derived at install time and what
    # the Python scripts resolve: through a symlink the logical name could be
    # anything, and two scripts deriving different fallbacks disagree.
    p="$(basename "$(cd "$ROOT" && pwd -P)" | tr 'A-Z' 'a-z' | tr -cd '[:alnum:]' | sed 's/^[0-9]*//' | cut -c1-3)"
    [ -n "$p" ] || p="bd"
  fi
  printf '%s\n' "$p"
}
packet=/tmp/$(_harness_prefix)-review-packet.md

# No base given: review what isn't committed yet, and fall back to the last
# commit when the tree is clean — "review my work" almost never means "review
# nothing".
narrow_hint=""
if [ -z "$base" ]; then
  if [ -n "$(git status --porcelain)" ]; then
    range=""; label="uncommitted working tree"
    narrow_hint="split the change into smaller commits and review each with scripts/review.sh <commit>"
  else
    range="HEAD~1"; label="HEAD (last commit)"
    narrow_hint="the last commit alone is too big to review whole — split it"
  fi
else
  range="$base"; label="since $base"
  narrow_hint="re-run with a narrower range (a nearer commit, or fewer commits)"
fi

# ── CONFIGURE ─────────────────────────────────────────────────────────────
# What a review is allowed to see lives in scripts/review.scope.sh, sourced
# just below. That file is yours — installed once, never compared or
# overwritten — so scope edits there are safe and packet fixes here still
# arrive with `harness update`.
if [ -f "$ROOT/scripts/review.scope.sh" ]; then
  . "$ROOT/scripts/review.scope.sh"
else
  echo "  ! no scripts/review.scope.sh — the packet has no scope to review." >&2
  echo "    'harness add' installs it; a project from before the split recovers" >&2
  echo "    its scope from its old review.sh on 'harness update --apply'." >&2
  exit 1
fi
# ── END CONFIGURE ─────────────────────────────────────────────────────────

diff_cmd() {
  if [ -z "$range" ]; then git diff HEAD "$@" -- "${SCOPE[@]}"
  else git diff "$range"... "$@" -- "${SCOPE[@]}"; fi
}

# A file that isn't tracked yet is still part of the change — usually the most
# important part, since a new file is where a new capability lands, and a review
# that can't see it is reviewing half the work.
#
# Read out with `--no-index` rather than staged with `add -N`: this script is
# read-only about the repository, and an intent-to-add entry it left behind
# would be picked up in full by the next `git commit -a` — an untracked scratch
# file riding along in an unrelated commit.
untracked() { [ -n "$range" ] || git ls-files --others --exclude-standard -- "${SCOPE[@]}"; }

untracked_diff() {
  untracked | while IFS= read -r file; do
    [ -n "$file" ] && git diff --no-index --no-color -- /dev/null "$file" || true
  done
}

files=$(printf '%s\n%s' "$(diff_cmd --name-only)" "$(untracked)" | sed '/^$/d')

# Captures taken while the change was being verified. The design reviewer looks
# at these rather than at the diff — a card that clips its own text is invisible
# in a diff and obvious in a screenshot.
#
# What counts as "since" differs by what's being reviewed. For a range, it's that
# commit's date. For an uncommitted tree it can't be HEAD's: the last commit may
# be days old, and everything screenshot since then — including whole sessions of
# unrelated work — gets swept in and read as this change's current state. The
# first edit in the working tree is the honest mark, so the oldest changed file
# is what dates the window.
marker=$(mktemp)
if [ -n "$range" ]; then
  since=$(git log -1 --format=%cd --date=format:'%Y%m%d%H%M.%S' "$range" 2>/dev/null || true)
else
  # NUL-separated, and forgiving: a changed file may have a space in its name or
  # have been deleted outright, and under `set -e` a stat that fails on one of
  # those would take the whole script down before the fallback below could run.
  # A loop rather than `... | xargs -0 mtime`: mtime is a shell function and
  # xargs execs, so it cannot see it — the call failed silently and every
  # uncommitted review fell back to the hour-ago window below. The `|| true`
  # on mtime is load-bearing: a changed file may be deleted by now, and under
  # `set -e` that failure would take the script down before the fallback.
  since=$(printf '%s' "$files" | while IFS= read -r f; do
    [ -n "$f" ] && mtime "$f" 2>/dev/null || true
  done | sort -n | head -1 || true)
  [ -n "$since" ] && since=$(stamp "$since")
fi
# An hour back is the fallback when there's nothing to date against at all — a
# tree whose changed files have all been deleted, say.
touch -t "${since:-$(stamp $(( $(date +%s) - 3600 )))}" "$marker"
# -L because /tmp is a symlink to /private/tmp, and find won't descend one.
# Ordered by when they were taken, not by name, so the last capture of a screen
# is the one that's true now — a verification run leaves the broken states it
# was fixing behind it, and a reviewer reading those as current would report
# bugs that no longer exist.
shots=$(find -L /tmp -maxdepth 1 -name "$CAPTURES" -newer "$marker" 2>/dev/null |
        while IFS= read -r f; do echo "$(mtime "$f") $f"; done | sort -n | cut -d' ' -f2-)
rm -f "$marker"

{
  echo "# Review packet — $label"
  echo
  if [ -z "$files" ]; then
    echo "Nothing in scope changed."
  else
    echo "## Files changed"
    echo '```'
    diff_cmd --stat
    untracked | sed 's/^/ new: /'
    echo '```'
    echo
    echo "## Diff"
    echo '```diff'
    diff_cmd
    untracked_diff
    echo '```'
  fi
  echo
  echo "## Captures"
  echo
  if [ -n "$shots" ]; then
    echo "Screenshots taken while verifying this change, oldest first. Read each one."
    echo "Where several show the same screen, the **last** is how it looks now and"
    echo "the earlier ones are states already fixed — review the last, and don't"
    echo "report a defect a later capture shows resolved."
    echo
    echo "$shots" | sed 's/^/- /'
  else
    echo "None. If this change alters anything on screen, that is itself a finding:"
    echo "it shipped unseen. Drive the app and capture it first."
  fi
} > "$packet"

lines=$(wc -l < "$packet" | tr -d ' ')

# Refuse a packet no reviewer can read whole: a local reviewer silently
# receives a truncated packet and reports confidently on its first pages — a
# review that appears to run and appears to pass, which is the worst outcome
# this script can produce. The binding budget is the smallest known one across
# the roles that read the packet; a role with no configured model is skipped
# rather than guessed at. Size is bytes/3 — rough, and biased toward refusing:
# code-heavy diffs tokenize near 3 chars/token, and a false refusal costs a
# re-run while a false pass silently truncates the review. A wrong budget is
# fixed per role in harness/models.json ("context" in tokens), not here.
tokens=$(($(wc -c < "$packet" | tr -d ' ') / 3))
binding_role=""; binding_budget=0
for role in reviewer-taste reviewer-correctness reviewer-design; do
  budget=$(scripts/models.py budget "$role" 2>/dev/null || true)
  case "$budget" in ''|*[!0-9]*) continue ;; esac
  if [ -z "$binding_role" ] || [ "$budget" -lt "$binding_budget" ]; then
    binding_role="$role"; binding_budget="$budget"
  fi
done
if [ -n "$binding_role" ]; then
  if [ "$tokens" -gt "$binding_budget" ]; then
    echo "refusing: packet is ~$tokens tokens, over $binding_role's ${binding_budget}-token budget." >&2
    echo "no reviewer is handed a packet it cannot read whole. $narrow_hint." >&2
    echo "packet left at $packet for inspection — do not hand it to a reviewer whole." >&2
    exit 1
  fi
elif [ "$lines" -gt 3000 ]; then
  # No budgets known (no roster) — the old heuristic is all there is. A packet
  # past a few thousand lines means the change is too big to review in one
  # pass — say so rather than letting a reviewer silently skim it.
  echo "warning: packet is large; consider reviewing in stages (scripts/review.sh <earlier-commit>)" >&2
fi

echo "$packet ($label, $(echo "$files" | grep -c . ) files, $lines lines, ~$tokens tokens)"
