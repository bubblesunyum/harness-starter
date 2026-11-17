#!/bin/bash
# Behavioural knowledge evals: does the always-loaded layer still teach what
# it claims to teach.
#
#   bash scripts/eval.sh                 # every case in harness/evals/
#   bash scripts/eval.sh --case <name>   # one case, while iterating
#
# Each case is one directory — harness/evals/<case>/ with task.md (what the
# agent must do from a bare worktree), base (the git ref the worktree starts
# at, usually HEAD) and check.sh (exit 0 when the worktree proves the
# behaviour). The runner makes a throwaway worktree at base, overlays the
# candidate knowledge layer, runs the agent headless through scripts/agent.py
# on the pinned model, runs check.sh, and appends one row per case to
# harness/evals/results.jsonl. One run per case, one retry on failure.
#
# Results are appended, never rewritten: the verify lane compares the new rows
# against every committed row, and fails when a case that ever passed there
# now fails — the baseline is a ratchet over history, not the latest row, so
# a committed red run keeps failing until a run passes — when a once-passing
# case disappears, or when total passes drop. A case failing that never passed
# is still a failure on first sight, because the first run of a new case is
# the claim that the layer teaches it. A memory-only change never reaches this
# script — the lane skips before calling here — because memories and reviewer
# traps are keyed, cheap and revertible, while always-loaded text is none of
# those.
#
# Add cases here: one directory per behaviour worth keeping, named for it.
# Seed 3-8 real cases from closed beads — the loop in harness/learning.jsonl
# says which behaviours keep breaking — and keep each task self-contained
# enough that a fake opencode on PATH can stand in for the model in the gate
# probes. The two shipped examples are the shape, not the suite.
set -uo pipefail

ROOT="${HARNESS_PROJECT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# Where this script was loaded from: the shared checkout, whose scripts/ holds
# the copy a project file shadows. Same as ROOT when run as an installed copy.
HARNESS="${HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

# ── Tune here: retries per case, this line only. One retry per the epic — a
# flaky agent gets a second run, a broken layer gets the same verdict twice
# rather than a long tail.
EVAL_RETRIES=1

# One loader for the lane library: every python heredoc in this script execs
# through here with the lib on PYTHONPATH, so no call site pastes its own
# import block. Any extra argv the inline code reads travels after the script.
kl_python() {
  PYTHONPATH="$HARNESS/scripts/lib" python3 - "$@"
}

# The always-loaded layer, one list: read from the lane library, so the
# trigger set the lanes read and the overlay set below are the same files
# and the two cannot drift apart. The single source is KNOWLEDGE_FILES in
# template/scripts/lib/knowledge_layer.py.
KNOWLEDGE_FILES=()
eval "$(kl_python <<'PYEOF'
import knowledge_layer as kl
print("KNOWLEDGE_FILES=(" + " ".join(kl.KNOWLEDGE_FILES) + ")")
PYEOF
)"
[ "${#KNOWLEDGE_FILES[@]}" -gt 0 ] || { echo "eval: cannot read the knowledge layer list" >&2; exit 1; }

usage() {
  awk '/^#/{sub(/^# ?/, ""); print; next} {exit}' "$0"
  exit "${1:-0}"
}

only_case=""
while [ $# -gt 0 ]; do
  case "$1" in
    --case) [ -n "${2:-}" ] || { echo "eval: --case needs a name" >&2; exit 2; }; only_case="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "eval: unknown argument $1" >&2; exit 2 ;;
  esac
done

# Cases live in the project: a project seeds its own from closed beads, and
# the two shipped examples are the shape, not the suite. The starter itself
# runs with the checkout root as its project while its cases sit beside the
# runner in template/, so the shared copy is the fallback only there — a
# checkout carrying template/.harness-root is the harness itself, still inside
# the project. Anywhere else a missing evals dir fails loudly naming it:
# writing rows into the shared checkout would interleave projects, vanish
# from git status here, and leave a baseline no clone can resolve.
EVALS="$ROOT/harness/evals"
if [ ! -d "$EVALS" ]; then
  if [ -d "$HARNESS/harness/evals" ] && { [ "$ROOT" = "$HARNESS" ] || [ -f "$ROOT/template/.harness-root" ]; }; then
    EVALS="$HARNESS/harness/evals"
  else
    echo "eval: no evals dir at $EVALS — seed cases from closed beads (see header)" >&2
    exit 1
  fi
fi
RESULTS="$EVALS/results.jsonl"

if [ -n "$only_case" ] && [ ! -d "$EVALS/$only_case" ]; then
  echo "eval: no such case $only_case in $EVALS" >&2
  exit 2
fi

# No commits, no worktree to make and no baseline to regress against — a
# fresh install stays green rather than failing on a harness that did nothing
# wrong. The verify lane skips before calling here for the same reason; this
# is the backstop for a direct run.
if ! rev="$(git rev-parse HEAD 2>/dev/null)"; then
  echo "eval: no commits yet — nothing to overlay, skipping"
  exit 0
fi
# Pinned once: the stamp below and every baseline lookup behind it read this
# rev, never live HEAD — a commit landing mid-run must not move the baseline
# under the verdict.
export EVAL_BASE_REV="$rev"

# The one worktree at a time, reaped whatever happens: an eval that leaves a
# worktree behind pollutes every later git command in the repo, so the trap
# owns the removal and each case also removes explicitly on its way out. The
# trap stays covered the whole time: worktree is blanked only after an
# explicit removal, never before, so a failed add still reaps.
worktree=""
cleanup() {
  if [ -n "$worktree" ] && [ -e "$worktree" ]; then
    git worktree remove --force "$worktree" 2>/dev/null || { rm -rf "$worktree"; git worktree prune; }
  fi
  worktree=""
}
trap cleanup EXIT

# Display names arrive sanitised from the enumeration bridge below (the
# full boundary set as spaces, plus an index on collisions) — nothing
# downstream re-sanitises, so the words on a verdict line are exactly the
# words the baseline stored.
raws=()
displays=()
candidates=()
for d in "$EVALS"/*/; do
  [ -d "$d" ] || continue
  # Parameter expansion, not basename: command substitution strips trailing
  # newlines, so "foo" and "foo<newline>" would collapse to one candidate
  # and the failing case would never run.
  base="${d%/}"
  candidates+=("${base##*/}")
done
# Sorted NUL-safe: newline names never see a line-based sort, and the key
# is the raw name so the run reads the same whatever order the filesystem
# listed. Python assigns the display names too (bash 3.2 has no assoc
# arrays for the counts): the safe form bare, or suffixed with an index
# when two raws sanitise alike — both run, rows stay distinct, and a
# suffix already taken by a literal case name is skipped until free.
# A filtered --case run narrows AFTER indexing, never before: the verdict
# baseline holds the indexed displays from full runs, so filtering on the
# raw name before the bridge would store a bare name the ratchet never
# matches and every filtered run would misfire.
only_disp=""
if [ "${#candidates[@]}" -gt 0 ]; then
  while IFS= read -r -d '' raw && IFS= read -r -d '' disp; do
    raws+=("$raw")
    displays+=("$disp")
  done < <(printf '%s\0' "${candidates[@]}" | python3 -c '
import sys
chunks = sys.stdin.buffer.read().split(b"\x00")
if chunks and chunks[-1] == b"":
    chunks.pop()
ordered = sorted(chunk for chunk in chunks if chunk)
def safe(chunk):
    for byte in (b"\x09", b"\x0a", b"\x0b", b"\x0c", b"\x0d",
                 b"\x1c", b"\x1d", b"\x1e"):
        chunk = chunk.replace(byte, b" ")
    return chunk
freq = {}
for chunk in ordered:
    key = safe(chunk)
    freq[key] = freq.get(key, 0) + 1
taken = set()
out = sys.stdout.buffer
for chunk in ordered:
    base = safe(chunk)
    if freq[base] > 1 or base in taken:
        idx = 1
        while True:
            disp = base + (" (%d)" % idx).encode("ascii")
            if disp not in taken:
                break
            idx += 1
        taken.add(disp)
    else:
        disp = base
        taken.add(disp)
    out.write(chunk + b"\x00" + disp + b"\x00")
')
    if [ "${#raws[@]}" -ne "${#candidates[@]}" ]; then
      echo "eval: cannot enumerate the cases in $EVALS" >&2
      exit 1
    fi
  fi
if [ -n "$only_case" ]; then
  # Narrow after indexing: the baseline holds the indexed displays from
  # full runs, so filtering before the bridge would store a bare name the
  # ratchet never matches. Raw names are unique on disk, so at most one
  # pair survives. C-style loop: arithmetic never trips set -u on empty.
  only_disp=""
  keep_r=()
  keep_d=()
  for ((i = 0; i < ${#raws[@]}; i++)); do
    if [ "${raws[$i]}" = "$only_case" ]; then
      keep_r+=("${raws[$i]}")
      keep_d+=("${displays[$i]}")
      only_disp="${displays[$i]}"
    fi
  done
  raws=()
  displays=()
  for ((i = 0; i < ${#keep_r[@]}; i++)); do
    raws+=("${keep_r[$i]}")
    displays+=("${keep_d[$i]}")
  done
fi
# No early exit on an empty suite: a committed-green case with no directory
# is a deleted regression, and an empty suite is all of them at once — so the
# verdict below names the missing cases instead of calling it nothing to run.

# Per-case outcomes for the append-and-compare pass at the bottom, one
# tab-separated line each: name, pass (1/0), tokens. Names are sanitised on
# the way in (the full boundary set becomes spaces) so the verdict parse
# below cannot break on them.
new_rows="$(mktemp)" || { echo "eval: cannot make a scratch file" >&2; exit 1; }
trap 'rm -f "$new_rows"; cleanup' EXIT

# One case, start to finish: worktree, overlay, attempts, verdict — the
# three helpers below own one phase each, so the case body stays flat.
# The candidate knowledge layer over the base tree: exactly the
# always-loaded text the behavioural lane triggers on, root and template/
# counterparts alike — a breaking template/ change the overlay skipped would
# evaluate the clean base layer and sail through. Reviewer traps stay out —
# they are keyed and revertible, and this script does not judge them.
overlay_layer() {
  local wt="$1" f s rel
  # The ${arr[@]+...} form expands to nothing when the array is empty: under
  # set -u a bare empty array expansion fails, so the loop needs the guard.
  for f in ${KNOWLEDGE_FILES[@]+"${KNOWLEDGE_FILES[@]}"}; do
    if [ -f "$ROOT/$f" ]; then
      cp "$ROOT/$f" "$wt/$f"
    else
      # Deleted since base: the worktree starts at base, so without this
      # the stale file lingers and the agent passes on a broken tree.
      rm -f "$wt/$f"
    fi
    if [ -f "$ROOT/template/$f" ]; then
      mkdir -p "$wt/template"
      cp "$ROOT/template/$f" "$wt/template/$f"
    else
      rm -f "$wt/template/$f"
    fi
  done
  # Skills nest — one file per skill dir, suits included — so the copy and the
  # mirror below walk with find: bash 3.2 has no globstar, and a one-level
  # glob would leave nested skills stale in the worktree. NUL-separated, so
  # odd names survive the trip.
  while IFS= read -r -d '' s; do
    [ -f "$s" ] || continue
    rel="${s#"$ROOT"/}"
    # Parameter expansion, not dirname: command substitution strips
    # trailing newlines, so a skill dir ending in one would copy to the
    # wrong worktree path and evaluate the wrong tree.
    parent="${rel%/*}"
    [ "$parent" = "$rel" ] && parent="."
    mkdir -p "$wt/$parent"
    cp "$s" "$wt/$rel"
  done < <(find "$ROOT/.claude/skills" "$ROOT/template/.claude/skills" -name SKILL.md -print0 2>/dev/null)
  # Mirror deletions (renames fall out as delete-then-add): a worktree skill
  # with no candidate counterpart is removed, not left for the agent to read.
  while IFS= read -r -d '' s; do
    [ -f "$s" ] || continue
    rel="${s#"$wt"/}"
    [ -f "$ROOT/$rel" ] || rm -f "$s"
  done < <(find "$wt/.claude/skills" "$wt/template/.claude/skills" -name SKILL.md -print0 2>/dev/null)
}

# Up to EVAL_RETRIES+1 agent attempts in the case worktree. Leaves the
# verdict inputs in globals: attempt_pass (1/0), attempt_out (the reply),
# attempt_check and attempt_err (the last check and error output).
run_attempts() {
  local dir="$1" task check_out err_file attempt
  task="$(cat "$dir/task.md")"
  attempt_pass=0
  attempt_out=""
  attempt_check=""
  attempt_err=""
  attempt=0
  while [ "$attempt" -le "$EVAL_RETRIES" ]; do
    attempt=$((attempt + 1))
    err_file="$(mktemp)" || { echo "eval: mktemp failed" >&2; exit 1; }
    if attempt_out="$(HARNESS_PROJECT="$worktree" HARNESS_ROOT="$HARNESS" python3 "$HARNESS/scripts/agent.py" implement "$task" 2>"$err_file")"; then
      if check_out="$(cd "$worktree" && bash "$dir/check.sh" 2>&1)"; then
        attempt_pass=1
        rm -f "$err_file"
        break
      else
        attempt_check="$check_out"
      fi
    else
      # The agent invocation itself failed, so no check ran: drop the
      # previous attempt's check output rather than reporting it beside an
      # error from a different run.
      attempt_check=""
    fi
    attempt_err="$(tail -5 "$err_file" 2>/dev/null)"
    rm -f "$err_file"
  done
}

# One verdict line per case, then the why indented: a failing gate says what
# the agent did, not just that it failed. Appends the tab-separated row the
# verdict below compares against the committed baseline.
report_verdict() {
  local display="$1" tokens
  # Tokens are the reply in the harness own unit — length over four, the
  # same divisor scripts/context.py counts the always-loaded layer with.
  tokens=$((${#attempt_out} / 4))
  printf '%s\t%s\t%s\n' "$display" "$attempt_pass" "$tokens" >> "$new_rows"
  if [ "$attempt_pass" = 1 ]; then
    echo "ok eval $display"
  else
    echo "FAIL eval $display"
    # The verdict line stays one line per case; the why follows indented, so
    # a failing gate says what the agent did, not just that it failed.
    if [ -n "$attempt_check" ]; then
      printf '%s\n' "$attempt_check" | tail -5 | sed 's/^/        /'
    fi
    if [ -n "$attempt_err" ]; then
      printf '%s\n' "$attempt_err" | sed 's/^/        /'
    fi
  fi
}

run_one_case() {
  local raw="$1"
  local display="$2"
  local dir="$EVALS/$raw"
  if [ ! -f "$dir/task.md" ] || [ ! -f "$dir/check.sh" ]; then
    echo "FAIL eval $display"
    echo "        $display has no task.md or check.sh — add both per the header above"
    printf '%s\t0\t0\n' "$display" >> "$new_rows"
    return 0
  fi
  local base="HEAD"
  if [ -f "$dir/base" ]; then
    base="$(tr -d '[:space:]' < "$dir/base")"
    [ -n "$base" ] || base="HEAD"
  fi
  # A case starting at HEAD starts at the pinned rev, not whatever HEAD
  # became while earlier cases ran — the same skew the verdict pins below.
  if [ "$base" = "HEAD" ]; then
    base="$rev"
  fi
  if ! git rev-parse --verify "$base" >/dev/null 2>&1; then
    echo "FAIL eval $display"
    echo "        base ref $base does not resolve"
    printf '%s\t0\t0\n' "$display" >> "$new_rows"
    return 0
  fi
  worktree="$(mktemp -d "${TMPDIR:-/tmp}/eval-XXXXXX")" || { echo "eval: mktemp failed" >&2; exit 1; }
  rmdir "$worktree" || { echo "eval: cannot shape the worktree path" >&2; exit 1; }
  if ! git worktree add --detach "$worktree" "$base" >/dev/null 2>&1; then
    echo "FAIL eval $display"
    echo "        cannot make a worktree at $base"
    printf '%s\t0\t0\n' "$display" >> "$new_rows"
    # Explicit removal first, prune after the fallback: a failed add leaves
    # a stale registration behind. Blanked only now the trap has nothing
    # left to reap.
    git worktree remove --force "$worktree" 2>/dev/null || rm -rf "$worktree"
    git worktree prune
    worktree=""
    return 0
  fi
  overlay_layer "$worktree"
  run_attempts "$dir"
  report_verdict "$display"
  git worktree remove --force "$worktree" 2>/dev/null || { rm -rf "$worktree"; git worktree prune; }
  worktree=""
}

if [ "${#raws[@]}" -gt 0 ]; then
  i=0
  while [ "$i" -lt "${#raws[@]}" ]; do
    run_one_case "${raws[$i]}" "${displays[$i]}"
    i=$((i + 1))
  done
fi

# Append the new rows beside the cases, then judge them against every
# committed row: a case that ever passed there and fails here blocks, and so
# does a drop in total passes over that committed-green set, or a committed
# green case with no directory now — including all of them at once, when the
# suite is empty. A case that never passed and fails still fails on first
# sight — the first run of a new case is the claim that the layer teaches it.
# A filtered --case run scopes the verdict to that case: only it is compared,
# and the totals cover the selected set.
python3 - "$RESULTS" "$new_rows" "$rev" "$EVALS" "$only_disp" <<'PYEOF' || exit 1
import datetime
import json
import os
import subprocess
import sys

results_path, rows_path, harness_rev, evals_dir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
only_disp = sys.argv[5] if len(sys.argv) > 5 else ""
# The verdict reads the baseline at the pinned rev, never live HEAD: the
# runner exported EVAL_BASE_REV at start, and the argv rev is the fallback.
base_rev = os.environ.get("EVAL_BASE_REV") or harness_rev

try:
    with open(rows_path, encoding="utf-8", errors="replace") as handle:
        raw = handle.read().split("\n")
except OSError as exc:
    print("eval: cannot read the new rows: %s" % exc)
    sys.exit(1)

current = {}
order = []
malformed = 0
for line in raw:
    if not line.strip():
        continue
    fields = line.split("\t")
    if len(fields) != 3:
        malformed += 1
        continue
    name, passed, tokens = fields
    try:
        tokens = int(tokens)
    except ValueError:
        tokens = 0
    if name not in current:
        order.append(name)
    current[name] = {"pass": passed == "1", "tokens": tokens}
if malformed:
    print("eval: %d malformed row(s) in the new results"
          " — names must survive the tab-separated pass" % malformed)
    sys.exit(1)

try:
    with open(results_path, encoding="utf-8", errors="replace") as handle:
        live = handle.read().split("\n")
except OSError:
    live = []


def base_passes(lines):
    """Committed pass state by case. A case is green when ANY committed row
    passed — a ratchet over history, not the latest row — so a committed red
    run keeps failing until a run passes."""
    passed = {}
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        case = row.get("case")
        if case is None or not isinstance(row.get("pass"), bool):
            continue
        if row["pass"]:
            passed[case] = True
        else:
            passed.setdefault(case, False)
    return passed


stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
new_lines = []
for name in order:
    info = current[name]
    new_lines.append(json.dumps({"case": name, "harness_rev": harness_rev,
                                 "pass": info["pass"], "tokens": info["tokens"],
                                 "ts": stamp}))

if new_lines:
    try:
        with open(results_path, "a") as handle:
            if not live:
                handle.write("# Behavioural eval outcomes, one JSON object per case per run.\n")
                handle.write("# Readers skip blank lines and lines starting with #, which is this.\n")
            for line in new_lines:
                handle.write(line + "\n")
    except OSError as exc:
        print("eval: cannot append to %s: %s" % (results_path, exc))
        sys.exit(1)

# The baseline resolves through the physical tree: under a symlinked project
# path the logical results path never startswith git's physical toplevel, so
# both sides go through the real path first.
top = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                     capture_output=True, text=True,
                     errors="replace").stdout.strip()
rel = None
if top:
    real_top = os.path.realpath(top)
    real_results = os.path.realpath(results_path)
    if real_results == real_top or real_results.startswith(real_top + os.sep):
        rel = os.path.relpath(real_results, real_top)
baseline = []
if rel:
    shown = subprocess.run(["git", "show", base_rev + ":" + rel],
                           capture_output=True, text=True,
                           errors="replace")
    if shown.returncode == 0:
        # split on \n only, so exotic boundaries stay inside their JSON row.
        baseline = shown.stdout.split("\n")

base = base_passes(baseline)
if only_disp:
    # A filtered run judges one case: the caller already resolved the raw
    # name to its indexed display, so narrow to exactly that row — the
    # baseline from full runs stores indexed displays, never bare names.
    base = {name: ok for name, ok in base.items() if name == only_disp}

regressed = []
for name in order:
    if current[name]["pass"]:
        continue
    if base.get(name) is True:
        regressed.append("%s passed on the last committed harness, now fails" % name)
    else:
        regressed.append("%s has no passing baseline yet" % name)
for name in sorted(base):
    # A committed-green case with no directory now is a deleted regression,
    # not a smaller suite: totals alone cannot see it, because they iterate
    # the current cases only.
    if base[name] is True and name not in current:
        regressed.append("%s passed on the last committed harness but has no case now" % name)

base_total = sum(1 for ok in base.values() if ok is True)
now_total = sum(1 for name, ok in base.items()
                if ok is True and current.get(name, {}).get("pass") is True)
if now_total < base_total:
    regressed.append("total passes dropped %d -> %d" % (base_total, now_total))

for line in regressed:
    print("eval: regression — " + line)
if not current and not regressed:
    print("eval: SKIP — no cases in %s — nothing to run" % evals_dir)
sys.exit(1 if regressed else 0)
PYEOF
