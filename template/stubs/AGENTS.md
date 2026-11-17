# Working on this project

First action every session: `scripts/harness session` (Claude Code and Codex run it
as a start-up hook; opencode: run it yourself). It prints the harness contract,
which lives in the shared harness rather than this repo — `scripts/harness doctor`
shows where. If the harness cannot be found the command says how to fix it; do
not work without it.

Project-specific additions live in AGENTS.local.md — read it alongside this file.
