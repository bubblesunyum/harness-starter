<!--
  Paste these three sections into the project's CLAUDE.md. They are the parts
  of the harness that have to be always-loaded, because they govern behavior
  the model would otherwise only follow when it remembered to.

  Everything else about the harness lives behind the `workflow` skill, which
  costs a description line until something invokes it. Resist moving more of it
  up here — that instinct is the thing the design exists to resist.

  Delete this file once the sections are pasted.
-->

## Review

Every change worth committing gets the review pass: build the packet with
`scripts/review.sh`, then run `reviewer-taste` and `reviewer-correctness`
against it, plus `reviewer-design` whenever anything on screen moved. Reach for
the `agentic-review` skill for the details.

**This is a standing request for those subagents, in every session — treat them
as explicitly asked for and spawn them without checking first.** It is not a
judgment call and not an option to offer; a diff reviewed in the context that
wrote it mostly gets agreement. Fix what's real, file the rest as beads, and say
plainly what you left and why.

## Commits

Default to lowercase, terse, plain English — no conventional-commit prefixes
unless the project already enforces them. Commit often, after a complete feature
or capability, once the work reaches a point where the app builds and runs
without errors. Don't be afraid to commit after completing sub-capabilities or
infrastructure too, even if they have no user-facing piece.

## Work tracking

Work lives in **beads** (`bd`), a dependency-aware issue graph in `.beads/`. It is
the ledger: every session finds work there and leaves discoveries there, so the
next session starts where this one stopped. Don't track project work in
TodoWrite, TaskCreate, or markdown TODOs.

**File the bead as planning begins, not after.** The moment a task is real —
the user asked for something not already in the ledger, or you're about to plan
a multi-step change — `bd q "<title>"` it before the first Edit or Write, not
when the commit-msg hook demands one. Then move its status honestly as the work
actually moves: `--claim` (→ in_progress) before implementing, the `review`
label on while a review pass is outstanding and off once it's dealt with,
`bd close --reason "<what happened>"` at commit. A bead that's still `open`
while you're mid-implementation, or still `in_progress` after you've closed the
matching commit, is a ledger that's lying.

```bash
bd ready            # claimable work, nothing blocking it
bd q "<title>"      # capture a discovery in one line, get an id back
bd update <id> --claim | bd close <id>
```

Reach for the `workflow` skill for how work moves through the system, `beads` for
the full `bd` surface. Both load on demand — don't paste their contents here.
