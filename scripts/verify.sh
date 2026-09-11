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
# tokens to learn one bit — did it pass. Full logs land in /tmp/har-verify/
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
LOGS=/tmp/har-verify
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
  local status=$?
  # The exit code alongside the log, so readers need not guess the verdict
  # from the text: a passing step often logs nothing at all.
  echo "$status" > "$log.status"
  report "$name" "$log" $status
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

# The reviewers exist twice — .claude/agents/ for Claude Code, .opencode/agent/
# generated from it — and the generated half drifts silently, because nothing
# about editing the source makes opencode complain. Checked rather than
# regenerated: a gate that quietly fixed this would pass every time and never
# say the two had parted company.
if agents_out="$(scripts/opencode-agents.py check 2>&1)"; then
  echo "$agents_out"
else
  failed=1
  echo "$agents_out"
fi

# ── PROJECT STEPS ─────────────────────────────────────────────────────────
# There is no compiler here, so the gate is what a compiler would have caught:
# every script parses, and the CLI can still list its own commands. Cheap enough
# that there's no excuse for skipping it.

step "shell parses" bash -c '
  set -e
  for f in bin/harness commands/*.sh commands/lib/*.sh scripts/*.sh scripts/hooks/* \
           template/scripts/*.sh template/scripts/hooks/*; do
    [ -f "$f" ] || continue
    bash -n "$f" || { echo "error: $f"; exit 1; }
  done'

step "python parses" bash -c '
  set -e
  for f in scripts/*.py template/scripts/*.py; do
    [ -f "$f" ] || continue
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$f" \
      || { echo "error: $f"; exit 1; }
  done'

# A template file that still says {{PROJECT}} after substitution is one the
# installer missed — and the placeholder only shows up at the far end, in an
# installed project, long after anyone would connect it to this change.
step "placeholders substitute" bash -c '
  # Each step checked on its own. An && chain here reports ok when its own setup
  # failed: probe would be empty, the install would never run, grep would find
  # nothing to complain about, and the gate would pass vacuously — which is the
  # silent success this project exists to avoid, in the check meant to catch it.
  probe=$(mktemp -d) || { echo "error: mktemp failed"; exit 1; }
  trap "rm -rf \"$probe\"" EXIT
  git init -q "$probe" || { echo "error: git init failed in $probe"; exit 1; }
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  [ -f "$probe/scripts/brief.sh" ] || { echo "error: install produced no scripts/"; exit 1; }
  left=$(grep -rl "{{" "$probe" --include="*.sh" --include="*.py" --include="*.md" \
                --include="*.html" --include="*.json" 2>/dev/null || true)
  [ -z "$left" ] || { echo "error: placeholders survived in: $left"; exit 1; }'

# A fresh install has to come out clean, or the drift warning cries wolf on every
# project that ever ran `harness add` — and a warning nobody believes is worse
# than no warning. This caught it once already: the installer's own post-copy
# edits to AGENTS.md and .claude/settings.json read as drift until the comparison
# learned to normalise them away.
step "a fresh install reads as current" bash -c '
  probe=$(mktemp -d) || { echo "error: mktemp failed"; exit 1; }
  trap "rm -rf \"$probe\"" EXIT
  git init -q "$probe" || { echo "error: git init failed in $probe"; exit 1; }
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  out=$(bin/harness update "$probe" 2>&1) || {
    echo "error: update called a fresh install stale"; echo "$out"; exit 1; }'

if [ "$mode" != "--quick" ]; then
  step "cli lists commands" bash -c 'bin/harness | grep -q "^  add"'
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
