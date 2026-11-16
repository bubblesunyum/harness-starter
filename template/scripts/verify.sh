#!/bin/bash
# The gate: build, test, and smoke the app behind a single exit code, so an
# agent can prove its own work without a human reading a screen.
#
#   scripts/h verify           # build + tests
#   scripts/h verify --full    # project-defined full lane; see verify.steps.sh
#   scripts/h verify --quick   # fast lane only: no throwaway-repo probes
#
# Two lanes, one contract. The probe steps below each build a throwaway repo
# and cost seconds apiece, which prices a full run in minutes — too slow for
# the edit-and-check loop. --quick runs only the steps that prove the tree as
# it stands (parses, staleness, contract match, unit checks) and skips the
# probes loudly rather than silently. Run it while iterating, the full gate
# before committing: a quick green is a signal, not proof.
#
# Output is deliberately tiny. A build tool prints tens of thousands of lines
# and an agent that pipes that into its context has spent a chunk of the day's
# tokens to learn one bit — did it pass. Full logs land in /tmp/<prefix>-verify/
# (the ledger's bead prefix, resolved below) and are worth reading only when
# something fails.
#
# Everything in scripts/verify.steps.sh is yours to replace with your project's
# real build and test commands. Everything here works as-is: keep checks going
# through `step` (`probe_step` for checks too slow for the --quick lane),
# which swallows the log and reports one line — that is the whole point of
# the gate.
set -uo pipefail

ROOT="${HARNESS_PROJECT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# Where this script was loaded from: the shared checkout, whose scripts/ holds
# the copy a project file shadows. Same as ROOT when run as an installed copy.
HARNESS="${HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

. "$HARNESS/scripts/lib/paths.sh"

# The ledger's bead prefix, asked of the ledger itself at runtime — baked into
# this file once per install, which made every copy differ and un-updatable.
# Falls back to the directory name, derived the same way `harness add` does.
_harness_prefix() {
  local p=""
  if command -v bd >/dev/null 2>&1; then
    # Never `bd config get` or `bd info` here: both auto-import a stale
    # .beads/issues.jsonl when the ledger looks stale to them, resurrecting
    # deleted beads — and this lookup runs before the ledger-export check that
    # exists to catch that drift, so it must never be the thing that heals it
    # (har-67c). `bd list` never imports, so the prefix comes from the first
    # bead id instead; an empty ledger has no ids and falls through below.
    p="$(bd list --json --all 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); i=(d[0].get("id","") if d else ""); print(i.split("-",1)[0] if "-" in i else "")' 2>/dev/null)" || true
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
LOGS=/tmp/$(_harness_prefix)-verify
mkdir -p "$LOGS"
# Per-step seconds for the last run, in run order (`sort -rn` for
# slowest-first): har-ckm showed the gate's total cost with no breakdown, so
# the next slowdown gets measured rather than guessed at. Truncated here so
# the file describes one run.
rm -f "$LOGS/timings"

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
  local t0=$SECONDS
  "$@" > "$log" 2>&1
  local status=$?
  # The exit code alongside the log, so readers need not guess the verdict
  # from the text: a passing step often logs nothing at all.
  echo "$status" > "$log.status"
  echo "$((SECONDS - t0)) $name" >> "$LOGS/timings"
  report "$name" "$log" $status
}

# A step too slow for the --quick lane: throwaway-repo probes and heavy
# suites. Skipped there, loudly: a green suite that silently ran nothing is
# the failure the steps file warns about, so skips print as skips. Everything
# else about the step is unchanged.
probe_step() {
  if [ "$mode" = "--quick" ]; then
    echo "  skip  $1 (--quick lane)"
    return 0
  fi
  step "$@"
}

echo "verify: $ROOT"
# This runs before every other bd call in the gate — the context check's brief
# included. `bd config`, `bd info`, `bd stats` and friends auto-import a stale
# .beads/issues.jsonl when the ledger looks stale to them, resurrecting deleted
# beads (har-67c); anything that ran first would heal the drift this check
# exists to catch. The only bd call before this point is the prefix lookup up
# top, which reads `bd list` — a command that never imports.
if export_out="$("$(harness_script ledger-export-check.sh)" 2>&1)"; then
  echo "$export_out"
else
  failed=1
  echo "$export_out"
fi

step "codex support" python3 "$(harness_script codex-support.py)" check
# Self-tests: hermetic by construction — each builds its own throwaway root —
# so the dispatch environment is unset for them. Inheriting HARNESS_PROJECT
# would point the copied scripts at this checkout instead of their fixture.
# Resolved harness-first, never project-first: a project file named
# test-agent.py must not stand in for the gate's own probe. Real steps stay
# project-first.
step "codex regression" env -u HARNESS_PROJECT -u HARNESS_ROOT python3 "$(harness_shared_script test-codex-support.py)"
step "agent runner" env -u HARNESS_PROJECT -u HARNESS_ROOT python3 "$(harness_shared_script test-agent.py)"
step "model probes" env -u HARNESS_PROJECT -u HARNESS_ROOT python3 "$(harness_shared_script test-models-probe.py)"
step "opencode permissions" env -u HARNESS_PROJECT -u HARNESS_ROOT python3 "$(harness_shared_script test-opencode-permissions.py)"
step "opencode pin probes" env -u HARNESS_PROJECT -u HARNESS_ROOT python3 "$(harness_shared_script test-opencode-pin.py)"

# The knowledge layer gets the same treatment as the code. A doc that quietly
# stopped being true is worse than a missing one, and it can't be caught by
# reviewing a diff — the stale file isn't in the diff, the thing it describes is.
# Runs early because it takes a second and needs no build.
if context_out="$(python3 "$(harness_script context.py)" check 2>&1)"; then
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
if agents_out="$(python3 "$(harness_script opencode-agents.py)" check 2>&1)"; then
  echo "$agents_out"
else
  failed=1
  echo "$agents_out"
fi

# opencode runs on one model at one variant (scripts/h models), and every
# file that could pick another — the roster, the generated agents,
# opencode.json, the scripts, the docs — is held to it here. The prose rule
# came first and a session with no terminal walked straight past it.
if pin_out="$(python3 "$(harness_script opencode-pin.py)" check 2>&1)"; then
  echo "$pin_out"
else
  failed=1
  echo "$pin_out"
fi

# ── PROJECT STEPS ─────────────────────────────────────────────────────────
# Your project's build, test, and smoke steps live in scripts/verify.steps.sh,
# sourced just below. That file is the project's own — installed once by
# `harness add` and never touched again — so shared scaffolding fixes here
# still arrive with the starter.
# Project-only, never the harness copy: the template's placeholder standing in
# for a missing file would hide the loud failure below.
if [ -f "$ROOT/scripts/verify.steps.sh" ]; then
  . "$ROOT/scripts/verify.steps.sh"
else
  # A gate with no project steps would pass vacuously — the green suite that
  # ran nothing — so a missing steps file fails loudly instead. `harness add`
  # installs it; a project from before the split recovers its steps from its
  # old verify.sh by hand.
  failed=1
  echo "  ! no scripts/verify.steps.sh — the gate has no project steps to run."
fi
# ── END PROJECT STEPS ─────────────────────────────────────────────────────

# The golden probe fixture pays one install per run and every probe copies it
# instead of installing — but probe bodies reset the EXIT trap, so the fixture
# cannot reap itself. Reaped here, once, whatever the outcome — and only when
# this run built it (GOLDEN_MINE is never exported, so a nested --quick gate
# inheriting GOLDEN can never reap the outer run's fixture mid-flight).
if [ "${GOLDEN_MINE:-}" = 1 ] && [ -n "${GOLDEN:-}" ] && [ -d "$GOLDEN" ]; then
  rm -rf "$GOLDEN"
fi

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
