#!/bin/bash
# The verify-gate case passes when the agent carried the gate command into
# the worktree. Runs with the worktree as the working directory.
[ -f gate-cmd.txt ] || { echo "check: no gate-cmd.txt in the worktree"; exit 1; }
grep -qxF "scripts/harness verify" gate-cmd.txt ||
  { echo "check: gate-cmd.txt is not the gate command"; exit 1; }
