#!/bin/bash
# Close out work: ledger writes, export, verify, commit, push. The pre-commit
# hook regenerates .beads/issues.jsonl with memories and stages it on every
# commit, so the committed export is fresh whatever moved the ledger since
# the manual export — the order below is belt and braces. The gate is
# read-only (`bd list` never imports; every probe writes only its own
# throwaway repo), and its export check stays as the backstop. The push goes
# last: it needs the network and the Dolt remote, and a failed push must
# never block the commit. Every stage announces itself as it starts, so a
# long run never looks hung.
#
#   scripts/harness wrap-up -m "lowercase terse message" --bead fol-xxx
#     [--close fol-yyy --reason "..."] [--note fol-yyy "stands at ..."]
#     [--remember "..."] [--quick|--full] [--no-push] [--note-file harness/handoffs/<ts>.md]
#     [--no-reflect] [--nominate "one line"]... [--keep-lesson N]... [--candidates-file <path>]
#
# Reflect runs at every close, before the ledger writes (stage 0 below): one
# packet plus the reflector on the pinned model, zero candidates normal.
# --no-reflect skips it; a close with a clean tree and an empty journal skips
# itself out loud (unless --keep-lesson names candidates); a failed reflector
# warns and never blocks the close. Name candidates to keep with --keep-lesson
# (memory-tier keeps land in the ledger via `bd remember`); every candidate is
# logged to harness/learning.jsonl with its outcome, kept or dropped, and why.
# --candidates-file reuses a reviewed list so --keep-lesson keeps what the
# session saw instead of a fresh rerun.
#
# Lane default is the full gate (default verify lane); --quick while
# iterating, --full for the browser suite. Every ledger-shaped thing happens
# first (closes, notes, memories), because every one of them moves the ledger
# the export carries. After the export only reads run (verify), then
# `git add -A` stages the fresh export with the work and the commit carries
# both — and the push follows, best-effort.
#
# Failures: a failed push warns and continues (best-effort — the local ledger
# plus the committed export preserve everything but machine-loss redundancy,
# and --check keeps nagging). A failed gate aborts before any commit, so fix,
# reopen if needed, and rerun. Rerunning on a settled tree is a no-op success.
set -euo pipefail

ROOT="${HARNESS_PROJECT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# Where this script was loaded from: the shared checkout, whose scripts/ holds
# the copy a project file shadows. Same as ROOT when run as an installed copy.
HARNESS="${HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

. "$HARNESS/scripts/lib/paths.sh"
. "$HARNESS/scripts/lib/journal.sh"

SEP=$'\x1f' # unit separator: joins action + args into one array element, so a
            # single loop applies every ledger write (split fields never nest)
ACTIONS=()
NOMINATIONS=()
KEEP_LESSONS=()
PUSH=1 LANE="" MSG="" BEAD="" NOTE_FILE="" NOREFLECT=0 CANDIDATES_FILE=""

usage() {
  awk '/^#/{sub(/^# ?/, ""); print; next} {exit}' "$0"
  exit "${1:-0}"
}

need() { # need COUNT REMAINING FLAG -- fail when fewer than COUNT args remain
  if [ "$1" -gt "$2" ]; then echo "wrap-up: $3 needs a value" >&2; exit 1; fi
}

# --keep-lesson names indices reflect never applied (skipped run, native
# run, no candidates): one shape for every site that reports it. Call only
# behind a non-empty KEEP_LESSONS guard — the expansion is unsafe on an
# empty array under `set -u` on old bash.
warn_keep_ignored() { # warn_keep_ignored REASON
  echo "wrap-up: warning: --keep-lesson ${KEEP_LESSONS[*]} ignored — $1" >&2
}

# One reflect candidate with the session's decision: memory-tier keeps land
# via `bd remember`, other tiers print for the session to apply by hand, and
# every outcome is logged to harness/learning.jsonl. Args: idx tier target
# text evidence. Keeps come from KEEP_LESSONS.
annotate_reflect_lesson() {
  local _idx="$1" _tier="$2" _target="$3" _text="$4" _evidence="$5"
  local _outcome="dropped" _why="no --keep-lesson named it at close" _k
  for _k in ${KEEP_LESSONS[@]+"${KEEP_LESSONS[@]}"}; do
    if [ "$_k" = "$_idx" ]; then _outcome="kept"; break; fi
  done
  if [ "$_outcome" = "kept" ]; then
    if [ "$_tier" = "memory" ]; then
      if bd remember "$_text" --key "$_target" >/dev/null 2>&1 || bd remember "$_text" >/dev/null 2>&1; then
        _why="kept at close (--keep-lesson $_idx)"
      else
        echo "wrap-up: warning: lesson $_idx kept but bd remember failed — recording as dropped" >&2
        _outcome="dropped"
        _why="bd remember failed at close (--keep-lesson $_idx)"
      fi
    else
      echo "wrap-up: lesson $_idx kept — apply the delta to $_target by hand"
      _why="kept at close (--keep-lesson $_idx) — apply by hand"
    fi
  fi
  bash "$HARNESS/scripts/lib/journal.sh" lesson --tier "$_tier" --target "$_target" --text "$_text" --evidence "$_evidence" --outcome "$_outcome" --why "$_why" || echo "wrap-up: warning: cannot log lesson $_idx" >&2
  echo "wrap-up: lesson $_idx [$_tier] $_target — $_outcome"
}

# Stage 0: one reflector pass over this close, before anything moves the
# ledger: the packet carries the session diff, the live journal, the actions
# below (still pending), recent findings, the note draft and the session's
# nominations. Default on; --no-reflect skips; a close with a clean tree and
# an empty journal skips itself out loud unless --keep-lesson names
# candidates. Nothing here blocks the close: a failed reflector warns and the
# close continues without candidates. Kept lessons land memory-tier in the
# ledger via `bd remember`, and every candidate is logged to
# harness/learning.jsonl with its outcome — anything else kept is a small
# delta the session applies by hand. --candidates-file reuses a reviewed list
# so --keep-lesson indexes what the session saw, not a fresh rerun.
run_reflect_stage() {
  if [ "$NOREFLECT" -eq 1 ]; then
    echo "wrap-up: reflect skipped (--no-reflect)"
    if [ "${#KEEP_LESSONS[@]}" -gt 0 ]; then
      warn_keep_ignored "reflect did not run, so there is nothing to keep"
    fi
    return 0
  fi
  local _reflect_sid _reflect_live _reflect_empty _reflect_pending
  local _reflect_args _reflect_out _reflect_cands _reflect_n _reflect_tab
  local kind rest a b e _nom
  local _idx _tier _target _text _evidence _k
  _reflect_sid="$(journal_session_id 2>/dev/null)" || _reflect_sid=""
  _reflect_live=""
  if [ -n "$_reflect_sid" ]; then
    _reflect_live="$(journal_live_file "$ROOT" "$_reflect_sid" 2>/dev/null)" || _reflect_live=""
  fi
  _reflect_empty=0
  if [ -z "$(git status --porcelain)" ] && [ "${#ACTIONS[@]}" -eq 0 ] && [ -z "$NOTE_FILE" ] && [ "${#NOMINATIONS[@]}" -eq 0 ] && [ "${#KEEP_LESSONS[@]}" -eq 0 ]; then
    if [ -z "$_reflect_live" ] || [ ! -s "$_reflect_live" ]; then
      _reflect_empty=1
    fi
  fi
  if [ "$_reflect_empty" -eq 1 ]; then
    echo "wrap-up: reflect skipped — clean tree and empty journal (nothing to reflect on)"
    return 0
  fi
  echo "wrap-up: reflecting on this close..."
  _reflect_pending=""
  for e in ${ACTIONS[@]+"${ACTIONS[@]}"}; do
    kind="${e%%"$SEP"*}"; rest="${e#*"$SEP"}"
    a="${rest%%"$SEP"*}"; b="${rest#*"$SEP"}"
    case "$kind" in
      close) _reflect_pending="${_reflect_pending}close $a -- $b
";;
      note) _reflect_pending="${_reflect_pending}note $a -- $b
";;
      remember) _reflect_pending="${_reflect_pending}remember -- $a
";;
    esac
  done
  _reflect_args=()
  [ -n "$NOTE_FILE" ] && _reflect_args+=(--note-file "$NOTE_FILE")
  [ -n "$CANDIDATES_FILE" ] && _reflect_args+=(--candidates-file "$CANDIDATES_FILE")
  for _nom in ${NOMINATIONS[@]+"${NOMINATIONS[@]}"}; do
    _reflect_args+=(--nominate "$_nom")
  done
  _reflect_out="$(mktemp)" || {
    echo "wrap-up: warning: cannot stage reflect output — continuing without candidates" >&2
    _reflect_out=""
  }
  if [ -z "$_reflect_out" ]; then
    return 0
  fi
  if HARNESS_REFLECT_PENDING="$_reflect_pending" "$(harness_script reflect.sh)" ${_reflect_args[@]+"${_reflect_args[@]}"} >"$_reflect_out" 2>&1; then
    cat "$_reflect_out"
    _reflect_cands="$(grep -m1 '^CANDIDATES ' "$_reflect_out" | sed 's/^CANDIDATES //')" || _reflect_cands=""
    if grep -q '^REFLECTOR_NATIVE' "$_reflect_out"; then
      if [ "${#KEEP_LESSONS[@]}" -gt 0 ]; then
        warn_keep_ignored "the reflector runs natively, so keeps need --candidates-file or a real run"
      fi
      journal_event "reflect" "packet built, native run left to the session" || true
    elif [ -n "$_reflect_cands" ] && [ -f "$_reflect_cands" ] && [ -s "$_reflect_cands" ]; then
      _reflect_n="$(grep -c . "$_reflect_cands")"
      echo "wrap-up: reflector proposed $_reflect_n candidate(s)"
      _reflect_tab="$(python3 - "$_reflect_cands" <<'PYEOF'
import json, sys
for pos, line in enumerate(open(sys.argv[1]), 1):
    line = line.strip()
    if not line:
        continue
    cand = json.loads(line)
    print("%d\t%s\t%s\t%s\t%s" % (pos, cand["tier"], cand["target"], cand["text"], cand["evidence"]))
PYEOF
)" || _reflect_tab=""
      if [ -n "$_reflect_tab" ]; then
        printf '%s\n' "$_reflect_tab" | while IFS=$'\t' read -r _idx _tier _target _text _evidence; do
          [ -n "$_idx" ] || continue
          annotate_reflect_lesson "$_idx" "$_tier" "$_target" "$_text" "$_evidence"
        done
      fi
      for _k in ${KEEP_LESSONS[@]+"${KEEP_LESSONS[@]}"}; do
        case "$_k" in
          ''|*[!0-9]*) echo "wrap-up: warning: --keep-lesson $_k names no candidate" >&2;;
          *) if [ "$_k" -lt 1 ] || [ "$_k" -gt "$_reflect_n" ]; then echo "wrap-up: warning: --keep-lesson $_k names no candidate (1-$_reflect_n)" >&2; fi;;
        esac
      done
      journal_event "reflect" "$_reflect_n candidate(s), ${#KEEP_LESSONS[@]} kept" || true
    else
      if grep -q '^REFLECTOR_FAILED' "$_reflect_out"; then
        echo "wrap-up: warning: $(grep -m1 '^REFLECTOR_FAILED' "$_reflect_out" | sed 's/^REFLECTOR_FAILED //') — continuing without candidates" >&2
      else
        echo "wrap-up: reflect proposed nothing — continuing"
      fi
      if [ "${#KEEP_LESSONS[@]}" -gt 0 ]; then
        warn_keep_ignored "reflect produced no candidates, so there is nothing to keep"
      fi
      journal_event "reflect" "no candidates" || true
    fi
  else
    cat "$_reflect_out"
    echo "wrap-up: warning: reflect failed — continuing without candidates" >&2
    journal_event "reflect" "failed, continuing" || true
  fi
  rm -f "$_reflect_out"
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
    --nominate) need 2 "$#" "--nominate TEXT"; NOMINATIONS+=("$2"); shift 2;;
    --keep-lesson) need 2 "$#" "--keep-lesson N"; KEEP_LESSONS+=("$2"); shift 2;;
    --candidates-file) need 2 "$#" "--candidates-file PATH"; CANDIDATES_FILE="$2"; shift 2;;
    --no-reflect) NOREFLECT=1; shift;;
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

# ── 0. Reflect. One reflector pass over this close; the shape lives on
# run_reflect_stage above so this stage stays one call.
run_reflect_stage

# ── 1. Ledger writes. Nothing after this point may move the ledger before
# the export — a stray `bd` write here still needs a fresh export, and the
# gate's export check says so.
# Empty-array-safe under `set -u` even on old bash: the ${arr[@]+...} form
# expands to nothing when unset-or-empty instead of erroring.
echo "wrap-up: settling the ledger (${#ACTIONS[@]} action(s))..."
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

# ── 2. Export. The last ledger read before the commit; only reads run
# between here and the commit.
echo "wrap-up: exporting the ledger..."
bd export --include-memories -o .beads/issues.jsonl

# ── 3. Verify. Aborts before any commit on failure.
echo "wrap-up: verifying${LANE:+ ($LANE lane)}..."
if [ -z "$LANE" ]; then
  "$(harness_script verify.sh)"
else
  "$(harness_script verify.sh)" "$LANE"
fi

# ── 4. Commit the work with the fresh export inside it. A pending note file
# stays out via pathspec exclusion so it lands in its own capture commit below
# instead of riding the bead commit.
echo "wrap-up: committing..."
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

# ── 5. Handoff note as its own capture commit (path already allowlisted).
if [ -n "$NOTE_FILE" ]; then
  echo "wrap-up: recording the handoff note..."
  git add "$NOTE_FILE"
  if [ -n "$(git status --porcelain)" ]; then
    git commit -m "record session handoff"
  fi
fi

# ── 6. Push. Best-effort by design (AGENTS.local.md): needs the network and
# the Dolt remote, and a failed push must never block the commit — which is
# why it goes after, not before. Its own export regen rewrites the working
# file with identical content, so the clean check below still passes.
if [ "$PUSH" = 1 ]; then
  echo "wrap-up: pushing the ledger (best-effort)..."
  if ! "$(harness_script ledger-push.sh)"; then
    echo "wrap-up: warning: ledger push failed — committed anyway; --check will keep nagging" >&2
  fi
fi

# ── 7. Prove the promise.
if [ -n "$(git status --porcelain)" ]; then
  echo "wrap-up: FAILED — tree still dirty:" >&2
  git status --porcelain >&2
  exit 1
fi
"$(harness_script ledger-push.sh)" --check
echo "wrap-up: clean"
