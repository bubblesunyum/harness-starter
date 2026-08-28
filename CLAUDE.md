# CLAUDE.md

harness-starter is the agentic development harness itself, packaged so it can be
installed into any project. `template/` is the product; the root is a working
install of it, put there by `harness add`.

**Every real change goes in `template/`.** The root `scripts/` are substituted
copies made at install time — editing one does not change the other, and the
running harness here is the copy. See "Working on the starter" in README.md.

## Taste

Shell and Python read by someone at 2am when something has broken: the usage
comment at the top and the error message on the way out are part of the
interface, not decoration. Small single-purpose functions. Comments explain a
*why* — a workaround, a platform gotcha — never what the line below already says.
Names read as documentation.

A starter is judged on what it does when its assumptions are wrong: a bad path,
a half-initialised ledger, a name with no usable characters, a symlink pointing
somewhere surprising. Failing loudly beats failing silently every time, and
silent success on a broken install is the worst outcome available.

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
