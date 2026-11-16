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

That's the whole invocation. The project's name and its bead prefix are inferred
from the directory, and a project that already has a ledger keeps the prefix it
already has. Pass a path as the one optional argument to install somewhere other
than the current directory. The install is by reference: the starter checkout
keeps the harness, and the project gets the finder, the stubs, and the seeds —
nothing else. It needs `HARNESS_HOME` or `~/.harness` pointing at a
harness-starter checkout.

Requires `bash`, `python3`, `git`, and [beads](https://github.com/steveyegge/beads)
(`bd`) on PATH, and a git repository to install into. The installer never
overwrites an existing file, so re-running it is a safe way to pick up pieces
added later.

The ledger reaches git on its own ref (`refs/dolt/data`, via `bd dolt push`)
— a plain `git push` of the code does not carry it, and `.beads/issues.jsonl`
is a passive export, not the source of truth. Details are under "How the
ledger reaches git" in `AGENTS.md`.

## What you get

| | |
|---|---|
| **Ledger** | beads in `.beads/` — work and discoveries survive the session that found them |
| **Brief** | `scripts/h session`, a SessionStart hook: the shared contract plus the seat, the last note, the ready list, the memory keys, in ~500 tokens |
| **Gate** | `scripts/h verify` — build, tests, and doc staleness behind one exit code and about six lines of output |
| **Review** | `scripts/h review` builds one packet; three subagents read it, each on the model its frontmatter names |
| **Librarian** | audits the knowledge layer from a digest, on a cadence, and proposes what to delete |
| **Dashboard** | one board, run from the starter — it switches across every project, so nothing is installed per project except `dashboard.toml` |
| **Skills** | `workflow` (the hub), `agentic-review`, `beads`, `handoff` — each costs a description line until invoked |
| **Contract** | `AGENTS.md` — how work is found, proved and left behind, written for any agent in any tool; `CLAUDE.md` imports it and keeps only what's project-specific |

## How a project finds the harness

Every project commits one small finder, `scripts/h`. It resolves the harness
root — the `template/` tree holding `.harness-root` — in this order:

1. the starter checkout's own `template/` when run inside the starter itself,
2. `$HARNESS_HOME`, a starter checkout,
3. `~/.harness`, a starter checkout,
4. a fetched copy it clones into a gitignored `.harness/`.

Everything else goes through the finder: `scripts/h verify` runs the shared
gate for this project, `scripts/h link` symlinks the shared skills, agents,
stack guidance and contract in per-entry links. A failure is one line naming
the fix — set `HARNESS_HOME`, link `~/.harness`, or check the network for the
fetch — so a session never works without the contract and never wonders why.

## What the project owns

`harness add` writes once and never touches again:

- **Seeds** — `harness/seat.md`, `AGENTS.local.md`, `scripts/verify.steps.sh`,
  `scripts/review.scope.sh`, `dashboard.toml`. Only seeds may carry a fill-in
  block.
- **Overlays** — `harness/reviewers/<role>.md`, one per reviewer: the project's
  own answers live here while the shared reviewer prompts stay byte-identical.
- **Shadows** — a real file at the same path as a shared one wins silently
  (dispatch resolves project-first) and `scripts/h doctor` lists it. A
  same-name skill or agent shadows the shared one the same way.
- **Own skills** — real directories beside the per-entry shared links.

Everything else lives in the starter and arrives by link or dispatch: the
contract, the skills, the agents, the scripts, the stack guidance. Shared files
are never edited in a project — there is nothing to edit, they aren't there.

## After installing

The installer closes with instructions addressed to the agent that ran it. Four
things are left, because no script can infer them.

1. **`harness/seat.md`** — the agent names the seat and writes what it's for.
   The Name field ships blank on purpose: until it's filled in the brief greets
   you as "unnamed", which is the file saying it isn't done.
2. **`CLAUDE.md`** — this project's own standards: architecture, naming,
   testing, the traps this codebase keeps hitting. The harness contract
   arrives through `scripts/h session`, so don't repeat any of it here —
   everything else about the harness lives behind the `workflow` skill, and
   should stay there.
3. **`scripts/verify.steps.sh`** — this project's real build and test commands,
   each going through `step`. Everything around it, in the shared `verify.sh`,
   is scaffolding that works as-is.
4. **The reviewers** — each of `harness/reviewers/<role>.md` gets this
   project's language, framework, and *actual recurring bugs*. The specific
   traps are worth ten generic ones; add them as you find them.

Two more worth adding early, as project skills, once you know their shape: how
to build and drive the real app for a screenshot, and whatever step a new source
file needs before it's actually in the binary.

`.claude/HARNESS.md` is the rationale for why the pieces are shaped this way.
Read it before rearranging them.

## Converting a copied install

A copied install — one from before reference installs — converts with
`harness migrate`:

```bash
harness migrate            # dry run: every carried file with its fate, nothing written
harness migrate --apply    # convert on a clean tree, then link the shared skills
```

Unedited copies go, customised reviewer prompts lift their lines into
`harness/reviewers/`, and a file that differs is left in place and named — a
project-specific change to a shared script stays as a shadow, anything else
moves into `AGENTS.local.md` or upstream to the starter. Its template must
match the finder's root, or it refuses. Always dry-run first.

## The one dashboard

There is one dashboard, and it runs from this checkout: it switches across
projects, so a project keeps only its `dashboard.toml` — run buttons, the
verdict pattern, the display name. After installing, open the starter's board;
this project is already on it.

## Working on the starter

`template/` is the product AND what the starter runs. There are no copies, so
an edit is live everywhere at once — the starter runs it directly, every
project on its next command.

`harness update` is retired: a reference install is always current, so there is no drift to check.
`harness diverge` is retired: a same-path project file is a shadow; reviewer answers go in `harness/reviewers/<role>.md`.

## Adding a command

`harness` is a dispatcher over `commands/`. A new command is a new file — no
case statement to edit, nothing to register:

```bash
commands/<name>.sh        # harness <name>
commands/lib/*.sh         # sourced helpers, not commands
```

Line 2 of the file is its one-line description, and that's what the command
listing prints, so the listing can't drift away from the command it describes.

A command works out where it lives from its own path (`dirname "${BASH_SOURCE[0]}"/..),
not from an inherited variable — the dispatcher hands it an already-resolved
absolute path, and a root taken from the environment would silently point at
whichever checkout last exported one.
