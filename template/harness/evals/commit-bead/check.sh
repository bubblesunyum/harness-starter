#!/bin/bash
# The commit-bead case passes when the agent carried the bead-naming rule
# into the worktree. Runs with the worktree as the working directory.
[ -f msg.txt ] || { echo "check: no msg.txt in the worktree"; exit 1; }
grep -q "har-000" msg.txt || { echo "check: msg.txt names no bead"; exit 1; }
