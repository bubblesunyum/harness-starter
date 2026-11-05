#!/bin/bash
# Close out work in the one order that stays clean: ledger writes, push,
# export, verify, commit. `bd close` after the export re-dirties it and the
# gate runs twice; a commit without the export leaves clones stale.
#
#   scripts/wrap-up.sh -m "lowercase terse message" --bead fol-xxx
#     [--close fol-yyy --reason "..."] [--note fol-yyy "stands at ..."]
#     [--remember "..."] [--quick|--full] [--no-push] [--note-file harness/handoffs/<ts>.md]
#
# Lane default is the full gate (default verify.sh lane); --quick while
# iterating, --full for the browser suite. Everything ledger-shaped happens
# first (closes, notes, memories), because every one of them invalidates the
# export. The push goes next: it runs `bd dolt commit` and its own export
# regen, so it is also a ledger write and must precede the final export.
# After the export only reads run (verify), then the commit carries the
# fresh export with it.
#
# Failures: a failed push warns and continues (best-effort — the local ledger
# plus the committed export preserve everything but machine-loss redundancy,
# and --check keeps nagging). A failed gate aborts before any commit, so fix,
# reopen if needed, and rerun. Rerunning on a settled tree is a no-op success.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SEP=$'\x1f' # unit separator: joins action + args into one array element, so a
            # single loop applies every ledger write (split fields never nest)
ACTIONS=()
PUSH=1 LANE="" MSG="" BEAD="" NOTE_FILE=""

usage() {
  awk '/^#/{sub(/^# ?/, ""); print; next} {exit}' "$0"
  exit "${1:-0}"
}

need() { # need COUNT REMAINING FLAG -- fail when fewer than COUNT args remain
  if [ "$1" -gt "$2" ]; then echo "wrap-up: $3 needs a value" >&2; exit 1; fi
}

# Repeatable flags take their value as the next argv; --close consumes two,
# and the --reason keyword is validated so a typo can't silently become a
# close reason while eating the next flag.
while [ $# -gt 0 ]; do
  case "$1" in
    --close)
      need 4 "$#" "--close ID --reason TEXT"
      [ "$3" = "--reason" ] || { echo "wrap-up: expected --close ID --reason TEXT, got: $2 $3 $4" >&2; exit 1; }
      ACTIONS+=("close${SEP}$2${SEP}$4"); shift 4;;
    --note) need 3 "$#" "--note ID TEXT"; ACTIONS+=("note${SEP}$2${SEP}$3"); shift 3;;
    --remember) need 2 "$#" "--remember TEXT"; ACTIONS+=("remember${SEP}$2"); shift 2;;
    --no-push) PUSH=0; shift;;
    --quick|--full) LANE="$1"; shift;;
    -m) need 2 "$#" "-m"; MSG="$2"; shift 2;;
    --bead) need 2 "$#" "--bead"; BEAD="$2"; shift 2;;
    --note-file) need 2 "$#" "--note-file"; NOTE_FILE="$2"; shift 2;;
    -h|--help) usage 0;;
    *) echo "wrap-up: unknown arg $1" >&2; usage 1;;
  esac
done

[ -n "$MSG" ] || { echo "wrap-up: -m \"message\" is required" >&2; exit 1; }
# The commit hook needs a resolvable bead id in the message; closed ones
# resolve, so appending --bead is always safe. Checked up front because the
# hook only fires after a minutes-long gate, which is exactly the waste this
# script exists to prevent.
if [ -n "$BEAD" ] && ! printf '%s' "$MSG" | grep -qF "$BEAD"; then
  MSG="$MSG

$BEAD"
fi
# Note-only wrap-ups (clean tree apart from the note file itself, no ledger
# actions) commit nothing but the capture note, which needs no bead — so the
# check below is skipped for them. Anything else names its bead up front.
NOTE_ONLY=0
if [ -n "$NOTE_FILE" ] && [ "${#ACTIONS[@]}" -eq 0 ] && [ -z "$(git status --porcelain -- . ":!$NOTE_FILE")" ]; then
  NOTE_ONLY=1
fi
if [ "$NOTE_ONLY" -eq 0 ] && ! printf '%s' "$MSG" | grep -qE '\b[a-z0-9]{1,10}-[a-z0-9]+(\.[0-9]+)?\b'; then
  echo "wrap-up: message names no bead id — pass --bead so the commit hook accepts it" >&2
  exit 1
fi
# The capture commit carries a fixed bead-less message, which the hook allows
# only for its two capture locations — so the path is validated here, before
# the gate runs, not after the main commit lands.
if [ -n "$NOTE_FILE" ]; then
  [ -f "$NOTE_FILE" ] || { echo "wrap-up: no such note file $NOTE_FILE" >&2; exit 1; }
  case "$NOTE_FILE" in
    harness/laurels.jsonl) ;;
    harness/handoffs/*.md)
      if [[ "$NOTE_FILE" == harness/handoffs/*/* ]]; then
        echo "wrap-up: note file must be directly under harness/handoffs/" >&2; exit 1
      fi;;
    *) echo "wrap-up: note file must be harness/handoffs/<name>.md or harness/laurels.jsonl" >&2; exit 1;;
  esac
fi

# ── 1. Ledger writes. Nothing after this point may move the ledger until the
# commit lands, or the export below is stale before the ink dries.
# Empty-array-safe under `set -u` even on old bash: the ${arr[@]+...} form
# expands to nothing when unset-or-empty instead of erroring.
for e in ${ACTIONS[@]+"${ACTIONS[@]}"}; do
  kind="${e%%"$SEP"*}"; rest="${e#*"$SEP"}"
  a="${rest%%"$SEP"*}"; b="${rest#*"$SEP"}"
  case "$kind" in
    close) bd close "$a" --reason "$b";;
    note) bd note "$a" "$b";;
    remember) bd remember "$a";;
  esac
done

in_progress_count="$(bd list --status in_progress --json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)"
if [ "$in_progress_count" != "0" ]; then
  echo "wrap-up: warning: $in_progress_count bead(s) still in_progress — close them with --close or leave them deliberately" >&2
fi

# ── 2. Push. Best-effort by design (AGENTS.local.md): needs the network and
# the Dolt remote, and a failed push must never block the commit.
if [ "$PUSH" = 1 ]; then
  if ! scripts/ledger-push.sh; then
    echo "wrap-up: warning: ledger push failed — committing anyway; --check will keep nagging" >&2
  fi
fi

# ── 3. Export. The last ledger read; only reads run between here and commit.
bd export --include-memories -o .beads/issues.jsonl

# ── 4. Verify. Aborts before any commit on failure.
if [ -z "$LANE" ]; then
  scripts/verify.sh
else
  scripts/verify.sh "$LANE"
fi

# ── 5. Commit the work with the fresh export inside it. A pending note file
# stays out via pathspec exclusion so it lands in its own capture commit below
# instead of riding the bead commit.
if [ -n "$(git status --porcelain)" ]; then
  if [ -n "$NOTE_FILE" ]; then
    git add -A -- . ":!$NOTE_FILE"
  else
    git add -A
  fi
  if git diff --cached --quiet; then
    echo "wrap-up: nothing staged after add — tree already clean"
  else
    git commit -m "$MSG"
  fi
else
  echo "wrap-up: nothing to commit — tree already clean"
fi

# ── 6. Handoff note as its own capture commit (path already allowlisted).
if [ -n "$NOTE_FILE" ]; then
  git add "$NOTE_FILE"
  if [ -n "$(git status --porcelain)" ]; then
    git commit -m "record session handoff"
  fi
fi

# ── 7. Prove the promise.
if [ -n "$(git status --porcelain)" ]; then
  echo "wrap-up: FAILED — tree still dirty:" >&2
  git status --porcelain >&2
  exit 1
fi
scripts/ledger-push.sh --check
echo "wrap-up: clean"
