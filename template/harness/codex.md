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

## Shared skills and reviewers

Read shared skills through `.agents/skills/`, whose relative directory links
point to `.claude/skills/`. Edit the shared source when changing the procedure.
`python3 scripts/codex-support.py write` refreshes links and reviewer TOML from
`.claude/agents/`; `check` detects drift. The writer leaves project hooks alone
and refuses to replace a copied skill until its contents have been reconciled.

For the review pass, use Codex subagents with the named reviewer roles. Inherit
the host model; Claude model aliases in the shared instructions apply to Claude.
If a role is unavailable in the current session, give a default subagent its
`.claude/agents/<role>.md` prompt and the review packet. Use Codex's browser
panel for dashboard URLs. Shared cost measurements describe Claude sessions.
Keep the shared `.claude/memory-archive/` path. For handoffs, use Codex task tools
only when the user requests a separate task; `claude --bg` is Claude-only.

Skill links follow the [official Codex skill guidance](https://learn.chatgpt.com/docs/build-skills).
