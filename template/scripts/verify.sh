#!/bin/bash
# The gate: build, test, and smoke the app behind a single exit code, so an
# agent can prove its own work without a human reading a screen.
#
#   scripts/verify.sh           # build + tests
#   scripts/verify.sh --full    # + slower checks and any smoke test
#   scripts/verify.sh --quick   # build only
#
# Output is deliberately tiny. A build tool prints tens of thousands of lines
# and an agent that pipes that into its context has spent a chunk of the day's
# tokens to learn one bit — did it pass. Full logs land in /tmp/{{PREFIX}}-verify/
# and are worth reading only when something fails.
#
# ── FILL THIS IN ──────────────────────────────────────────────────────────
# Everything outside the PROJECT STEPS block below is harness scaffolding and
# works as-is. Replace the steps with your project's real build and test
# commands. Keep them going through `step`, which swallows the log and reports
# one line — that is the whole point of the gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
LOGS=/tmp/{{PREFIX}}-verify
mkdir -p "$LOGS"

mode="${1:---default}"
failed=0
started=$SECONDS

# Everything interesting in a build log is on a line saying "error:" — the rest
# is compile invocations. Keep the first few, deduplicated, and say where the
# whole thing is. Widen the pattern if your toolchain words failures differently.
report() {
  local name="$1" log="$2" status="$3"
  if [ "$status" -eq 0 ]; then
    echo "  ok    $name"
  else
    failed=1
    echo "  FAIL  $name"
    grep -E "(error|failed):" "$log" | sed -e 's/^/        /' | sort -u | head -8
    echo "        full log: $log"
  fi
}

step() {
  local name="$1"; shift
  local log="$LOGS/${name// /-}.log"
  "$@" > "$log" 2>&1
  report "$name" "$log" $?
}

echo "verify: $ROOT"

# The knowledge layer gets the same treatment as the code. A doc that quietly
# stopped being true is worse than a missing one, and it can't be caught by
# reviewing a diff — the stale file isn't in the diff, the thing it describes is.
# Runs first because it takes a second and needs no build.
if context_out="$(scripts/context.py check 2>&1)"; then
  echo "$context_out"
else
  failed=1
  echo "$context_out"
fi

# ── PROJECT STEPS ─────────────────────────────────────────────────────────
# Replace these with your project's real commands. `step <name> <cmd...>` runs
# it, logs it, and prints one line. Nothing else in this file needs to change.

step "build" false   # e.g. cargo build / npm run build / xcodebuild ... build

if [ "$mode" != "--quick" ]; then
  step "tests" false # e.g. cargo test / npm test / pytest -q

  # Test counts are the one detail worth surfacing on success — "ok" alone
  # can't distinguish a green suite from a suite that ran nothing. Point this
  # grep at whatever your runner prints.
  if [ -f "$LOGS/tests.log" ]; then
    grep -oE "[0-9]+ (passed|tests?)[^.]*" "$LOGS/tests.log" | tail -1 | sed -e 's/^/        /'
  fi
fi

if [ "$mode" = "--full" ]; then
  # Anything slow, or anything needing a GUI session: a second platform's
  # build, an integration suite, a smoke check that launches the app and
  # asserts it came up. Delete this block if the project has none.
  :
fi
# ── END PROJECT STEPS ─────────────────────────────────────────────────────

# What the gate proved, as a git tree. Comparing a commit's timestamp against the
# gate's can only ever say "you committed after you verified", which is the
# order the loop prescribes — so it marked every fresh commit unverified. The
# tree says the thing actually worth knowing: whether the content in that commit
# is the content the gate ran against.
if [ "$failed" -eq 0 ]; then
  idx="$LOGS/index"
  rm -f "$idx"
  GIT_INDEX_FILE="$idx" git read-tree HEAD 2>/dev/null &&
    GIT_INDEX_FILE="$idx" git add -A 2>/dev/null &&
    GIT_INDEX_FILE="$idx" git write-tree 2>/dev/null > "$LOGS/tree"
  rm -f "$idx"
fi

# How long the gate takes is worth watching: it's the tax on every change, and
# when it grows past the patience of whoever's waiting, it stops getting run.
echo $((SECONDS - started)) > "$LOGS/elapsed"

[ "$failed" -eq 0 ] && echo "verify: passed" || echo "verify: FAILED"
exit "$failed"
