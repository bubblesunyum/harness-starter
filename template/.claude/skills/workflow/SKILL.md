---
name: workflow
description: How work moves through this project — the beads ledger, the verify gate, the review pass, and the token budget that keeps them affordable on one account. Use when starting a work session, deciding where a note or a discovery belongs, planning a multi-step change, handing off at the end of a session, or wondering which skill or script to reach for.
---

# How work moves here

One person, one Claude account. The system is built so a session can start cold,
find the work, prove the work, and leave a trail — without a human reading a
screen at every step, and without spending the account's tokens on ceremony.

## The loop

```
bd ready → claim → build → scripts/verify.sh → review → commit → close → capture
     ↑                                                                       │
     └──────────── bd q "<discovery>" ·  bd remember "<trap>" ───────────────┘
```

1. **Find work.** `bd ready` lists what's claimable — open, nothing blocking it.
   The SessionStart brief already showed you the top of that list; don't re-run
   it unless you need the rest.

   **Work that isn't in the ledger yet still starts here.** The moment the user
   hands you something new, or you're about to plan a multi-step change, file
   it with `bd q "<title>"` before you touch a file — not later, and not only
   when the commit-msg hook forces the issue. A bead filed after the work is
   done is a ledger that only looks complete.

   **Only `ready` is workable.** Two labels are excluded from it, for the same
   reason: someone else's decision is pending. `backlog` is work deliberately
   kept rather than done next, and `needs-human` is work a session already
   declined to guess at. The brief and the board both filter them
   (`bd ready --exclude-label backlog --exclude-label needs-human`) — if you go
   looking with a bare `bd list`, filter them yourself. Either comes back only
   when the user says so, via `bd label remove <id> <label>`.
2. **Claim it.** `bd update <id> --claim`. This is what makes the dashboard and
   the next session show the work as live rather than available.
3. **Build it.** Normal work, under the taste in CLAUDE.md.
4. **Prove it.** `scripts/verify.sh` — the build and the tests behind one exit
   code; `scripts/verify.steps.sh` defines any `--full`-only checks. Don't ask the user to look at
   something you can check yourself: if the project has a way to drive the real
   app and screenshot it, that is the step, and it belongs in its own skill.
5. **Review it.** `bd label add <id> review`, then `scripts/review.sh` builds
   the packet and the `agentic-review` skill runs it past agents that didn't
   write it.
   `bd label remove <id> review` when the findings are dealt with.
   Batch before you gate: collect every reviewer's findings first, apply them
   in one revision, then run the gate once on a frozen tree — no edits until
   it reports. A gate per revision round multiplies slow probe runs for no new
   signal, and editing mid-run manufactures phantom failures (a probe split
   across an edit reads as drift that isn't there).
6. **Close it.** `bd close <id> --reason "<what actually happened>"`, and commit.
   Commit often — CLAUDE.md means it. The reason is where the outcome lives when
   it differs from the plan, which is most of the time.
7. **Capture it.** Below.

**Name the bead in the commit message** — `Closes <bead-id>`, or just the id in the
body. A `commit-msg` hook enforces it for work commits, and the id has to
resolve. Commits containing only handoff notes or laurels may omit the bead;
the `handoff` skill covers that narrow exception. That link is what lets a later session ask why a line looks the way it
does and get an answer, and it's how the staging lane knows what's sitting
unpushed. Nothing filed yet? `bd q "…"` takes one line and hands back an id.

The board at `scripts/dashboard.py` (localhost:7391) shows all of this live, and
its buttons run the gate and the push. It opens in Claude Code's browser pane
and nowhere else — `preview_start harness-dashboard`, or navigate to the URL the
hook printed. The pane is the only browser you can read back, so a board you
opened is a board you can check your own work against. Starting it is
`scripts/dashboard.py`, which backgrounds and returns; `serve` is the form that
blocks, and you almost never want it.

## Capture — the step that pays for the next session

The thing that cost an hour to work out is worth thirty seconds to write down.
Every finished piece of work ends by asking where its residue goes:

| What you ended up with | Where it goes |
|---|---|
| A trap that will catch the next person | `bd remember "<it>" --key <slug>` |
| Why this turned out differently than planned | `bd close <id> --reason "<why>"` |
| A decision someone will second-guess | `bd update <id> --design "<the call and the alternative>"` |
| Something you noticed but didn't do | `bd q "<it>"` |
| Something worth keeping but not doing next | `bd q` + `bd label add <id> backlog` |
| Something that isn't yours to decide | `bd q "<it>"` + `bd label add <id> needs-human` |
| A repeatable procedure | a new skill, or a section in an existing one |
| Praise the user offered unprompted | a line in `harness/laurels.jsonl` |

**Write a memory when a fact surprised you** — a tool behaving differently than
its docs suggest, a platform trap, a number worth knowing. Not for what the code
already says, and not for what happened once; for the fact that outlives the
session.

**Read before you debug.** The session brief lists every memory key you have, so
you already know what's known. `bd recall <key>` fetches one; `bd memories
<keyword>` searches when you're not sure. The keys cost a few tokens at startup
and exist to solve the thing search alone can't: you cannot look up a trap you
don't know exists.

**Escalating is a real option, not a failure.** Some things aren't a session's
call: a destructive step, a decision that sets taste rather than follows it, a
scope that turns out to be a different project. File it, label it `needs-human`,
and move to the next thing — the brief counts them for the user at wake-up. A
guess dressed as a decision costs more than the wait.

Don't use `bd edit` — it opens `$EDITOR` and hangs. `bd update --notes/--design`
does the same job without blocking.

## Upkeep — the part that keeps capture from becoming a liability

Capture only adds. Without something that subtracts, the knowledge layer grows
until it's expensive and, worse, until some of it is quietly false.

```bash
scripts/context.py          # is it still true, is it still small
scripts/context.py bless    # after updating a doc, re-record what it tracks
```

**Staleness is checked by the gate.** A doc declares what it describes with a
`<!-- tracks: … -->` comment; when a tracked source changes and the doc doesn't,
`scripts/verify.sh` fails. This catches the one thing review can't: the stale
file isn't in the diff, the thing it describes is. When you change a doc on
purpose, `bless` it.

**Always-loaded cost is reported, not capped.** `scripts/verify.sh` prints what
a session pays before it does anything. Nothing fails on the number — it's a
trend line. When it climbs, the fix is still to move something behind a skill
rather than to let the preamble grow, but that's a judgment call for the
librarian, not a threshold.

**The librarian runs on a cadence, never on the hot path.** Spawn the
`librarian` agent when the always-loaded cost climbs, when memories pass twenty,
or every month or so. It reads a digest, not the repo, and proposes what to
delete, merge, move between tiers, or shorten. It proposes; you decide.

**Memory deletions go through the user, and through the archive.** Memories live
outside the repo, so removing one is the only edit here with no `git revert`
behind it — and it's the record of how the user wants to be worked with, which
is a bad thing to quietly get wrong. Copy the file to `.claude/memory-archive/`
first, then show the user what's going and why. Everything else in a librarian
pass can be applied and reviewed later; this can't.

**Old closed beads decay when they're actually old.** `bd admin compact
--analyze` lists what's eligible (30 days closed) and `bd compact --days 30`
squashes ancient Dolt history. Compaction is enabled but deliberately not
automatic: it discards original content permanently, so it happens when someone
is looking, usually as part of a librarian pass.

## Where a thing belongs

The most expensive mistake in this system is writing knowledge into a place
that loads every session when it only matters occasionally.

| The thing | Where it goes | What it costs |
|---|---|---|
| Taste, philosophy, naming, architecture | `CLAUDE.md` | every session — keep it short |
| A repeatable procedure | a skill in `.claude/skills/` | a description line, until invoked |
| Work: todo, bug, plan, discovery | beads (`bd`) | only what you query |
| A durable project insight | `bd remember "<insight>"` | its key in the brief; text on recall |
| Who the user is, cross-project habits | the harness memory directory | outside the repo |

**Discoveries become beads, not TODOs.** Noticing something out of scope mid-task
is the normal case, and the answer is always the same: `bd q "the thing"` takes
one line, returns an id, and costs nothing to carry. A `// TODO` in the source
is invisible to `bd ready` and will still be there in a year.

## Token discipline

The whole harness is shaped by having one account. `scripts/context.py spend`
prints what recent sessions actually cost, and the shape it shows is the reason
for every rule below: measured on one project, a session opens at ~54k tokens
before it has done anything, and that opening context is re-sent on every
single turn. In a 60-turn session it *is* 80% of the bill.

Only ~4k of that floor is the repo, and almost none of the rest is worth
hunting. Deferred tool schemas already do the heavy lifting: a connector with
~40 tools costs ~230 tokens as bare names, not the thousands a loaded schema
would. What is left that anyone controls is about 5k — the skill listing
(~3.4k; most of it global and plugin skills a session here never invokes), the
agent listing (~1k), and MCP instruction blocks (~0.8k). The other ~44k is
Claude Code's own system prompt and built-in tool schemas, and no amount of
editing the repo touches it.

So the floor is worth *measuring* and mostly not worth fighting. The lever that
actually moves is the second half of the bill.

Past a hundred turns the floor stops dominating and accumulated conversation
takes over: measured on one project, the worst session reached 300k and paid
roughly four times per turn what it paid at the start. Everything read into the
main window is paid for again on every turn that follows it, so *where* a read
lands matters more than how big it is.

The rules that follow from that:

- **The session brief is capped.** `scripts/brief.sh` prints ~500 tokens: the
  seat and what it's for, the ready list and the memory keys. Don't run
  `bd prime` — it prints the whole command reference and every memory in full.
  For the full `bd` surface, the `beads` skill has it, on demand.
- **Query narrowly.** `bd show <id>` for one issue beats `bd list` for forty.
  Use `--json` only when you are actually parsing it.
- **Read the diff, not the repo.** Review and verification are scoped to what
  changed. `git diff` is the unit of work, not the file tree.
- **Spend effort where it pays.** Review passes run through subagents, each on
  the model and effort in its frontmatter. Log triage and screenshot checks stay at low effort; reserve full
  effort for code you actually intend to keep.
- **Subagents are for fan-out, not for delegation theater.** A subagent starts
  cold and re-derives context you already have. Use one when the work is a wide
  read you don't want in your own window (a review pass, a search), not to hand
  off something you could do in two calls.

  Handing *implementation* to another model is a different trade, and it pays
  when the work is specced: the `delegate` skill runs it on opencode, off this
  account, with you as its reviewer.

  The asymmetry is the whole argument. A search that opens eight files costs the
  main window ~30k tokens *for the rest of the session*; the same search in an
  `Explore` subagent costs its summary, once. The review pass is the proof that
  this is affordable — measured across 16 sessions on one project, every
  reviewer ever run returned about 15k tokens in total, roughly one percent of
  what a single working session spends. Reviewers are the cheapest thing in the
  harness; the expensive habit is reading the repo into your own window.

## Waking up and handing off

The brief is the wake-up: who the seat is and what it has shipped, one thing the
user said about the work, the last session's note, then the ledger. It's built
that way on purpose — a session that starts knowing where it is and that the
work was seen does better work than one that starts from nothing. See
`harness/seat.md`; the shipped count is derived from the ledger, never written
by hand.

A session ends clean when: claimed beads are closed with a reason or returned to
open with a note (`bd note <id> "<where it stands>"`), discoveries are filed,
anything that surprised you is remembered, the tree is committed, and
`scripts/verify.sh` passed. Then leave the note that structured fields can't
hold — the `handoff` skill has the shape of it. The next session's brief then
reads as the truth instead of a guess.

`bd stats` and `bd stale` are the two-second version of "is the ledger still
honest" — nothing ready means the next session has nothing to pick up, and
something stale means work is rotting rather than moving.

<!-- tracks: scripts/brief.sh scripts/verify.sh scripts/dashboard.py scripts/hooks/commit-msg scripts/context.py -->
