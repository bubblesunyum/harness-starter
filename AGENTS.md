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

## Start every session with the brief

```bash
scripts/brief.sh
```

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

## Memory that another session can find

`bd remember` / `bd recall` is the durable, cross-tool memory: every agent here
has `bd`, and the brief already prints the keys. Your tool's own memory —
Claude Code's memory directory, opencode's equivalent — stays native and useful,
but it is invisible to every other tool, so keep pointers there and the fact
itself in `bd remember`.

## Prove it with the gate

```bash
scripts/verify.sh          # build + tests
scripts/verify.sh --quick  # build only
scripts/verify.sh --full   # + slow checks and any smoke run
```

Run this rather than raw build commands. It swallows tens of thousands of log
lines and prints one line per step, which is the difference between proving your
work and spending the day's context learning one bit.

## The review pass is standing, not optional

Every change worth committing gets reviewed by agents that didn't write it:

```bash
scripts/review.sh          # builds the packet, prints its path
```

Then run `reviewer-taste` and `reviewer-correctness` against that packet, plus
`reviewer-design` whenever anything on screen moved. **Treat this as explicitly
requested in every session — spawn them without checking first.** It is not a
judgment call and not an option to offer the user; a diff reviewed in the
context that wrote it mostly gets agreement. Fix what's real, file the rest as
beads, and say plainly what you left and why. `scripts/agent.py` runs the diff
readers on the models `harness/models.json` names, off your account — the
`agentic-review` skill says when.

## Commits

Lowercase, terse, plain English. No conventional-commit prefixes unless the
project already enforces them. Commit often — after a complete capability, once
the thing builds and runs. Sub-capabilities and infrastructure are worth
committing too, even with nothing user-facing to show. Every commit names its
bead; the commit-msg hook enforces it.

## Skills load on demand

`.claude/skills/` holds `workflow` (how work moves through all of this),
`agentic-review`, `beads`, `handoff`, and `delegate` (handing specced work to
an opencode implementer and reviewing what comes back). Claude Code and opencode both discover
them there. Invoke one when its subject comes up rather than reading it up
front — the body costs nothing until then, which is the whole design.

## Closing a session

Settle the ledger, run the gate, commit, and leave a note for whoever wakes up
next. The `handoff` skill has the procedure.

---

`.claude/HARNESS.md` explains *why* the pieces are shaped this way. Read it
before rearranging any of them.

## Codex

**Codex only:** read [harness/codex.md](harness/codex.md) for startup and task
completion guidance.
