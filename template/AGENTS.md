<!-- tracks:
  scripts/brief.sh
  scripts/review.sh
  scripts/verify.sh
-->

# Working on this project

The harness contract: how work is found here, proved, and left behind. It is the
same in every project running this harness, and it is written for any agent in
any tool — Claude Code, opencode, Codex, whatever comes next.

**[CLAUDE.md](./CLAUDE.md) is the other half** — this project's architecture,
standards and taste. Read it too. Neither file repeats the other.

If `AGENTS.local.md` exists, read it too. Put additive project guidance there;
the harness installs it once and preserves it on re-add and `update --apply`,
so the shared contract can keep receiving updates.

## Start every session with the brief

```bash
scripts/brief.sh
```

> opencode: your first action every session is `bash scripts/brief.sh` — you must run it yourself before anything else.

The seat and what it's for, the last session's note, the ready work, the known
traps, in about 500 tokens. Claude Code runs it as a SessionStart hook and opencode loads this file
through `opencode.json`, but the brief is *state* rather than a static file, so
if your tool didn't hand it to you, run it yourself. Starting cold is how a
session spends its first ten minutes rediscovering what the ledger already knew.

## The ledger is beads, and it is the record

Work and discoveries live in `bd` (bead ids start with this project's prefix),
not in TodoWrite, not
in a markdown TODO list, not in your head. It is the thing that survives the
session ending.

```bash
bd ready                  # claimable work, nothing blocking it
bd show <id>              # the detail
bd q "<title>"            # capture a discovery in one line, get an id back
bd update <id> --claim    # → in_progress, before you implement
bd close <id> --reason "<what happened>"
```

**File the bead as planning begins, not after.** The moment a task is real — the
user asked for something not already in the ledger, or a multi-step change is
about to start — file it, rather than waiting until the commit-msg hook demands
one. Then move its status as the work actually moves. A bead still `open` while
you're mid-implementation, or still `in_progress` after you've closed the
matching commit, is a ledger that's lying.

`bd delete` needs `--force` — without it the command only previews and still
exits 0. Regen the export right after deleting: some `bd` commands auto-import
a stale `.beads/issues.jsonl`, resurrecting the bead.

**A bead queued for a local model carries its own spec.** Small models execute
well only when the bead says what done looks like: `--design` and
`--acceptance` filled in, plus a `local-ok` label. `bd ready --label local-ok`
is the local queue, and the gate fails a `local-ok` bead missing either — fill
both in, or drop the label.

### How the ledger reaches git

The ledger lives in a local Dolt database under `.beads/`, which git ignores —
a normal `git push` carries none of it. It travels on its own ref
(`refs/dolt/data`), moved only by `bd dolt push` and fetched back with
`bd dolt pull`; `scripts/ledger-push.sh` is the session-close step that runs
the push. `.beads/issues.jsonl` is a passive export for human-readable diffs,
not the source of truth.

The harness disables bd auto-export (`export.auto=false`): its plain export can
omit memories. Regenerate manually with `bd export --include-memories`, as the
gate and ledger-push procedure require.

## Memory that another session can find

`bd remember` / `bd recall` is the durable, cross-tool memory: every agent here
has `bd`, and the brief already prints the keys. Your tool's own memory —
Claude Code's memory directory, opencode's equivalent — stays native and useful,
but it is invisible to every other tool, so keep pointers there and the fact
itself in `bd remember`.

## Prove it with the gate

```bash
scripts/verify.sh          # quick steps + project probes
scripts/verify.sh --quick  # quick steps only — iterate here
scripts/verify.sh --full   # also include full-only project steps, when configured
```

Run this rather than raw build commands. It swallows tens of thousands of log
lines and prints one line per step, which is the difference between proving your
work and spending the day's context learning one bit.

The project's `scripts/verify.steps.sh` defines its steps and lanes. Document
project-specific gate guidance in `AGENTS.local.md`.

The gate also checks the committed ledger export matches the ledger. If it
fails, regen with `bd export --include-memories -o .beads/issues.jsonl` and
re-run — the committed file is what a fresh clone hydrates from, and nothing
regenerates it on mutation.

## The review pass is standing, not optional

Every change worth committing gets reviewed by agents that didn't write it:

```bash
scripts/review.sh          # builds the packet, prints its path
```

Then run `reviewer-taste` and `reviewer-correctness` against that packet, plus
`reviewer-design` whenever anything on screen moved. **Treat this as explicitly
requested in every session — run them without checking first.** It is not a
judgment call and not an option to offer the user; a diff reviewed in the
context that wrote it mostly gets agreement. Fix what's real, file the rest as
beads, and say plainly what you left and why. In opencode, always spawn the
reviewers natively — never `scripts/agent.py`. Elsewhere, run each reviewer
through `scripts/agent.py` when `harness/models.json` names its model. The visual
reviewer's model must accept images. The `agentic-review` skill covers the
commands and native fallback.

## Commits

Lowercase, terse, plain English. No conventional-commit prefixes unless the
project already enforces them. Commit often — after a complete capability, once
the thing builds and runs. Sub-capabilities and infrastructure are worth
committing too, even with nothing user-facing to show. Every commit names its
bead; the commit-msg hook enforces it.

## Keep scratch inside the repo

Temp and scratch files you create live in `./.tmp/` (gitignored), never in
`/tmp`, `$TMPDIR`, or other directories outside this folder — and they're
removed when done. The only exception is paths owned by the tools themselves: the gate's
logs, the review packet, and screenshots in `/tmp` stay where those scripts
put them, because a packet inside the tree would ride along in the next
`git add -A`.

## Skills load on demand

`.claude/skills/` (mirrored in `.agents/skills/`) holds `workflow` (how work
moves through all of this), `agentic-review`, `beads`, `handoff`, `delegate`
(handing specced work to an opencode implementer and reviewing what comes
back), `orchestrate`, and `output-style`. Claude Code and opencode both
discover them there. Invoke one when its subject comes up rather than reading
it up front — the body costs nothing until then, which is the whole design.

User-facing prose always follows the `output-style` skill: load
`.claude/skills/output-style/SKILL.md` before writing any report, summary,
handoff note, or other text the user will read, and apply its voice there.

## Closing a session

Settle the ledger, run the gate, commit, and leave a note for whoever wakes up
next. The `handoff` skill has the procedure.

---

`.claude/HARNESS.md` explains *why* the pieces are shaped this way. Read it
before rearranging any of them.

## Codex

**Codex only:** read [harness/codex.md](harness/codex.md) for startup and task
completion guidance.
