# Codex harness guidance

Use `AGENTS.md` for the workflow and `CLAUDE.md` for project standards. The
shared procedures live in `.claude/skills/`; use their Beads and handoff steps.

Run `bash scripts/brief.sh` if its output has not arrived through the startup
hook. The brief supplies project state; generic `bd prime` and `bd codex-hook`
instructions are not part of this harness. Changed project hooks require local
trust in Codex before they run; the manual brief works without hooks.

The repository authorizes local commits without another user request. Claim the
bead before implementation and keep its progress current. For each completed
task, run the gate and independent review, commit only your changes with the
bead id, then close the bead with the outcome before reporting completion.
This applies to ordinary task replies as well as explicit handoffs. If paused
or blocked, return the bead to open and note the remaining work. Push code branches only when the user requests it; follow the repository’s
existing ledger-sync policy.
