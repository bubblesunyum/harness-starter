# Working on this project

First action every session: `scripts/harness session` — run it before anything
else, and do not work without it. (Claude Code and Codex run it as a start-up
hook; opencode runs it through .opencode/plugins/harness-session.js — if you do
not see the brief above, run it yourself.) It prints the harness contract from
the shared harness, not this repo.

Work lives in the `bd` ledger, not TODO lists. Prove it with
`scripts/harness verify` before committing — one commit per bead, naming it.
Project-specific additions live in AGENTS.local.md — read it alongside this file.
