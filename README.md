# harness-starter

An agentic development harness for a project worked on by one person and one
Claude account. It exists so a session can start cold, find the work, prove the
work, and leave a trail — without a human reading a screen at every step, and
without spending the day's tokens on ceremony.

Extracted from a working project, with that project's language, platform, and
build system taken back out. What's left is the part that transfers.

```bash
ln -sf "$PWD/bin/harness" ~/.local/bin/harness    # once
cd ../my-project && harness add               # per project
```

The symlink resolves back to this checkout every time it runs, so an install
always uses whatever the starter says today — edit the template and the next
install picks it up, no reinstall step.

That's the whole invocation. The project's name and its bead prefix are inferred
from the directory, and a project that already has a ledger keeps the prefix it
already has. Pass a path as the one optional argument to install somewhere other
than the current directory.

Requires `bash`, `python3`, `git`, and [beads](https://github.com/steveyegge/beads)
(`bd`) on PATH, and a git repository to install into. The installer never
overwrites an existing file, so re-running it is a safe way to pick up pieces
added later.

## What you get

| | |
|---|---|
| **Ledger** | beads in `.beads/` — work and discoveries survive the session that found them |
| **Brief** | `scripts/brief.sh`, a SessionStart hook: the seat, the last note, the ready list, the memory keys, in ~100 tokens |
| **Gate** | `scripts/verify.sh` — build, tests, and doc staleness behind one exit code and about six lines of output |
| **Review** | `scripts/review.sh` builds one packet; three subagents read it — taste on Haiku, correctness on Sonnet, design on Sonnet reading screenshots |
| **Librarian** | audits the knowledge layer from a digest, on a cadence, and proposes what to delete |
| **Dashboard** | `scripts/dashboard.py` — a live diagram of all of it at localhost:7391, backgrounded, opened in Claude Code's browser pane |
| **Skills** | `workflow` (the hub), `agentic-review`, `beads`, `handoff` — each costs a description line until invoked |
| **Contract** | `AGENTS.md` — how work is found, proved and left behind, written for any agent in any tool; `CLAUDE.md` imports it and keeps only what's project-specific |

## The four ideas worth keeping

**Everything is token-budgeted.** One account means progressive disclosure over
always-loaded context, cheap models for bulk reading, and review scoped to the
diff rather than the tree. The brief replaces `bd prime` (~1900 tokens every
session, whether or not the ledger gets touched) with ~200.

That replacement is an override, not a default, and it does not stay done:
`bd setup claude` reinstalls the `bd prime` hook every time it runs, beside the
brief rather than instead of it. Remove it again afterwards — `scripts/context.py`
fails the gate on any SessionStart hook that isn't the brief or the dashboard.
`.claude/HARNESS.md` has the reasoning.

**A reviewer that reads pixels.** Two diff-reading reviewers will both pass a
card that clips every value it exists to show, because nothing in the diff is
wrong. `reviewer-design` reads the screenshots instead. It is the cheapest pass
to run and it catches what nothing else can.

**Staleness is the failure review can't catch.** A doc declares what it
describes in a `<!-- tracks: … -->` comment, hashes go in `.claude/context.lock`,
and the gate fails when a tracked source moves and the doc doesn't. The stale
file is never in the diff — the thing it describes is.

**The seat outlives the session.** `harness/seat.md` is the role, not the run,
and what it has shipped is derived from the ledger rather than written by hand.
The agent chooses its own name there at install — it is greeted by it at the top
of every session afterwards.
Alongside it: `harness/handoffs/` (one note per closing session, never
overwritten) and `harness/laurels.jsonl` (praise the user offered unprompted,
replayed one at a time, carrying no work and no priority by design).

## After installing

The installer closes with instructions addressed to the agent that ran it. Four
things are left, because no script can infer them.

1. **`harness/seat.md`** — the agent names the seat and writes what it's for.
   The Name field ships blank on purpose: until it's filled in the brief greets
   you as "unnamed", which is the file saying it isn't done.
2. **`CLAUDE.md`** — this project's own standards: architecture, naming,
   testing, the traps this codebase keeps hitting. The harness contract is
   already installed as `AGENTS.md` and `CLAUDE.md` imports it, so don't repeat
   any of it here — everything else about the harness lives behind the
   `workflow` skill, and should stay there.
3. **`scripts/verify.sh`** — the `PROJECT STEPS` block. Everything around it is
   scaffolding that works as-is.
4. **The reviewers** — each of `.claude/agents/reviewer-*.md` has a `FILL THIS
   IN` block for this project's language, framework, and *actual recurring
   bugs*. The specific traps are worth ten generic ones; add them as you find
   them.

Two more worth adding early, as project skills, once you know their shape: how
to build and drive the real app for a screenshot, and whatever step a new source
file needs before it's actually in the binary.

`.claude/HARNESS.md` is the rationale for why the pieces are shaped this way.
Read it before rearranging them.

## Working on the starter

`harness add` runs inside this repo too — that's how the harness gets worked on
with the harness: a ledger, the review packet, the gate, the dashboard.

**One trap comes with it.** What `add` writes to `scripts/` is a *copy* of
`template/scripts/`, with the placeholders filled in. They are separate files
from that moment on. Edit `template/scripts/brief.sh` and the `scripts/brief.sh`
that actually runs here does not change; fix a bug in the running copy and the
template still ships it.

So: **`template/` is the product, and the root is a working install of it.** Make
every real change in `template/`, and re-copy into the root when you want to run
what you just wrote. Nothing automates that yet — deleting the root copy and
re-running `harness add` picks up the new version, but it will not touch a file
that already exists, which is the whole reason it's safe everywhere else.

## Adding a command

`harness` is a dispatcher over `commands/`. A new command is a new file — no
case statement to edit, nothing to register:

```bash
commands/<name>.sh        # harness <name>
```

Line 2 of the file is its one-line description, and that's what the command
listing prints, so the listing can't drift away from the command it describes.

A command works out where it lives from its own path (`dirname "${BASH_SOURCE[0]}"/..`),
not from an inherited variable — the dispatcher hands it an already-resolved
absolute path, and a root taken from the environment would silently point at
whichever checkout last exported one.

## Portability

Developed on macOS. The scripts avoid BSD-only `stat` and `date` where it
mattered, but the dashboard and the capture-collection path have had the least
exercise elsewhere — if you run this on Linux, that's where to look first.
