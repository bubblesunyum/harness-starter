<!-- tracks:
  .claude/agents/librarian.md
  .claude/agents/reviewer-correctness.md
  .claude/agents/reviewer-design.md
  .claude/agents/reviewer-taste.md
  .claude/skills/workflow/SKILL.md
  scripts/brief.sh
  scripts/context.py
  scripts/review.sh
  scripts/verify.sh
-->

# The harness

harness-starter runs a bespoke agentic development harness: the pieces that let a
session start cold, find the work, prove the work, and leave a trail. This file
is the rationale — why the pieces are shaped this way. The `workflow` skill is
the procedure — how work actually moves through them. Read this before changing
how the pieces fit together.

## The pieces

- **Ledger:** beads (`bd`, prefix `har-`) in `.beads/`. Work and
  discoveries go there, not into TodoWrite or markdown TODOs. It is the thing
  that survives a session ending, so a bead that's still `open` mid-implementation
  is a ledger that's lying.
- **Skills:** `.claude/skills/` — `workflow` (the hub), `agentic-review`,
  `beads`, `handoff`. Each costs a description line until invoked; bodies are
  free until then. Add project-specific ones (how to build and drive the app,
  how to add a source file) as you learn what they are.
- **Reviewers:** `.claude/agents/` — `reviewer-taste` (haiku),
  `reviewer-correctness` (sonnet), and `reviewer-design` (sonnet), run against a
  packet from `scripts/review.sh`. Design reads screenshots rather than the
  diff, because a diff can't show you clipping. The packet carries untracked
  files too, and stages nothing to do it; its captures are dated from the
  working tree's first edit, so an unrelated session's screenshots stay out.
  Its scope carries the docs, `*.html` for the dashboard page, and `bin/*` and
  `commands/*` by path: the two most important files here have no extension, and
  a suffix-only scope left the dispatcher unreviewable long enough for it to keep
  a path-traversal bug through a full pass — then did the same to the dashboard
  page, the largest file in the project, until `*.html` was added.
- **Librarian:** `.claude/agents/librarian` (sonnet) audits the knowledge layer
  from a digest, on a cadence, never on the hot path. It proposes; the calling
  session decides.
- **Gate:** `scripts/verify.sh`, plus doc staleness. Tiny output on purpose.
  There is no compiler in this project, so the gate is what a compiler would
  have caught: every shell and Python file parses, the CLI still lists its own
  commands, and a probe install into a throwaway repo leaves no `{{placeholder}}`
  behind — that last one only ever shows up at the far end, in someone else's
  project, long after anyone would connect it to the change that caused it.
- **Dashboard:** `scripts/dashboard.py` serves a live diagram at localhost:7391.
  It never opens a browser itself. It publishes the live port to
  `.claude/launch.json` and prints the link with the instruction to open it in
  Claude Code's browser pane — the one browser the agent can read back and
  screenshot, and the one that doesn't land behind whatever window the human was
  already in. It backgrounds by default — the callers are hooks and
  agents, and a foreground server there is a terminal nobody gets back;
  `dashboard.py serve` is the form that blocks. If Portside knows the port it
  also prints the alias, matched on the launch directory too so a stale map
  can't name the board after someone else's server.

## Why it's shaped this way

One account, not a team of thirteen agents, so the whole design is
token-budgeted: progressive disclosure over always-loaded context, cheap models
for bulk reading, diff-scoped review. The stock beads SessionStart hook
(`bd prime`, ~1900 tokens every session) is replaced by `scripts/brief.sh`
(~200) — see below, because that replacement does not stay done on its own.

## The brief overrides `bd setup claude`, and has to be re-applied

`bd setup claude` installs a `bd prime --hook-json` SessionStart hook. The
harness deliberately does not want it: `bd prime` is a command reference and a
session-close protocol, which is what the `beads` skill holds and loads on
demand. Always-loading it is the exact instinct progressive disclosure exists to
resist, and it is not small — measured at 7,949 bytes against the brief's 1,072.
What a session actually needs at wake-up is ledger *state*, and `brief.sh`
already prints it: the seat, the last note, the ready list, the memory keys.

The hook is additive, so it does not replace the brief — it runs beside it and
both are paid for. It shipped that way in this starter and in the first project
installed from it, undetected, because the always-loaded cost line counts docs
and cannot see a hook.

**So: after any `bd setup claude`, remove the `bd prime` entry from
`.claude/settings.json` again.** The gate now catches it — `context.py` fails on
any SessionStart hook that isn't the brief or the dashboard — but the gate runs
after the session that already paid for it.

It checks all three files whose hooks fire here: `~/.claude/settings.json`,
`.claude/settings.json`, and `.claude/settings.local.json`. `bd setup claude
--global` writes to the first, and a check that read only the project file would
report a clean session while the hook ran from the user's home directory.

New procedures become skills, new work becomes beads — the instinct to add one
more paragraph to CLAUDE.md is the thing this design exists to resist.

`scripts/context.py` reports what a session pays before it does anything
(CLAUDE.md, the brief, `MEMORY.md`, and skill descriptions). It is a trend line,
not a gate. A cap here only ever measures how long it has been since someone
argued with the layer, and the librarian does that better.

## Staleness is the failure review can't catch

A doc declares what it describes in a `<!-- tracks: … -->` comment; hashes live
in `.claude/context.lock`; the gate fails when a tracked source moves and the
doc doesn't. This exists because the stale file isn't in the diff — the thing it
describes is, so no reviewer looking at the change will see it.

This file is tracked. In the project it came from it went stale as an untracked
note, claiming two reviewers and six skills long after there were four and
seven, and no gate caught it because nothing was watching.

## File the bead as planning begins

The moment a task is real — the user asked for something not already in the
ledger, or a multi-step change is about to start — file it, rather than waiting
until the commit-msg hook demands one. Then move its status honestly: `--claim`
before implementing, the `review` label on while a review is outstanding, `bd
close --reason` at commit.

There's no reliable hook for "planning begins" the way commit-msg hooks the
commit boundary, so this is an explicit rule in CLAUDE.md and in `workflow`
rather than a blocking gate.

## Memories are not repo state

The memory directory lives outside the checkout, under
`~/.claude/projects/<checkout-path>/memory/`. It is machine-local, not version
controlled, and `rm` there has no `git revert` behind it — the only edit in this
project that can't be reviewed after the fact. It is also the record of how the
user wants to be worked with, which is a bad thing to quietly get wrong.

So: anything removed from it is copied to `.claude/memory-archive/` and shown to
the user first. Durable facts belong here in the repo, where the staleness gate
can watch them; the memory file keeps a pointer.
