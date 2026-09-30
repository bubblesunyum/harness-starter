<!-- tracks:
  .claude/agents/librarian.md
  .claude/agents/reviewer-correctness.md
  .claude/agents/reviewer-design.md
  .claude/agents/reviewer-taste.md
  .claude/skills/workflow/SKILL.md
  scripts/agent.py
  scripts/brief.sh
  scripts/context.py
  scripts/opencode-agents.py
  scripts/review.sh
  scripts/verify.sh
-->

# The harness

This project runs a bespoke agentic development harness: the pieces that let a
session start cold, find the work, prove the work, and leave a trail. This file
is the rationale — why the pieces are shaped this way. The `workflow` skill is
the procedure — how work actually moves through them. Read this before changing
how the pieces fit together.

## The pieces

- **Ledger:** beads (`bd`) in `.beads/`. Bead ids start with the project's
  prefix. Work and
  discoveries go there, not into TodoWrite or markdown TODOs. It is the thing
  that survives a session ending, so a bead that's still `open` mid-implementation
  is a ledger that's lying.
  `scripts/ledger-push.sh` regenerates the tracked `.beads/issues.jsonl` (with
  memories) on every push — the Dolt ref is the primary transport, the JSONL is
  what a fresh clone hydrates from, so the file stays committed, never ignored.
- **Skills:** `.claude/skills/` — `workflow` (the hub), `agentic-review`,
  `beads`, `handoff`. Each costs a description line until invoked; bodies are
  free until then. Add project-specific ones (how to build and drive the app,
  how to add a source file) as you learn what they are.
- **Reviewers:** `.claude/agents/` — `reviewer-taste`,
  `reviewer-correctness` and `reviewer-design`, each on the model its
  frontmatter names, run against a
  packet from `scripts/review.sh`. Design reads screenshots rather than the
  diff, because a diff can't show you clipping. The packet carries untracked
  files too, and stages nothing to do it; its captures are dated from the
  working tree's first edit, so an unrelated session's screenshots stay out.
- **Librarian:** `.claude/agents/librarian` (sonnet) audits the knowledge layer
  from a digest, on a cadence, never on the hot path. It proposes; the calling
  session decides.
- **opencode:** `opencode.json` names the always-loaded files, and
  `.opencode/agent/` holds the reviewers translated into opencode's dialect by
  `scripts/opencode-agents.py`. See below — two of the obvious moves here are
  traps.
- **Gate:** `scripts/verify.sh` — build, tests, optional smoke, plus doc
  staleness. Tiny output on purpose.
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

## Delivering fixes to installs that already exist

`harness add` never overwrites. That is what makes re-running it safe, and it is
also how a fix stops travelling: a project that already has `AGENTS.md` gets
`skip (already there)`, the line scrolls past among thirty other skips, and the
broken copy stays. The failure is silent, and silence on a broken install is the
worst outcome this starter has.

So the skip is split in two. Files the project is meant to edit — anything whose
template carries a `FILL THIS IN` block, plus the data files it accumulates —
skip quietly, because them differing is the harness working. Everything else is
a **contract file**: `AGENTS.md`, `opencode.json`, the skills, the scripts behind
them. Those the project has no reason to touch, so a difference means a starter
fix never arrived, and `add` says so by name instead of skipping. `harness
update` is the same check standing alone, with `--diff` for what actually
changed, `--apply` for the asked-for overwrite, and follow-ups when reviewer
sources are among the flagged files.

Which set a file is in is read off the template's own content rather than kept as
a list. A list goes stale in the direction that produces false alarms, and a
warning nobody believes is worth less than no warning.

Nothing is overwritten unless asked. Half these files have local edits in
them by design, so merging is a judgment call — and an overwrite-by-default
would be a command nobody could afford to run. `harness update --apply` is the
asked-for exception: it writes the rendered template over stale contract files,
never customised ones, and names every file it changed. A file carrying a beads
block is left for a hand merge, and reviewer sources come with follow-ups — the
generated agent copies, the hashes, the gate — because the merge is half the
job.

Some drift is a fork, not a missed fix: a dashboard chip, a widened review
scope, a generator with project hooks. That stays stale forever under the
check above, and a warning nobody can clear is one that stops being read.
`harness/diverged.txt` is the acknowledgment — one path per line, committed,
with the reason after `#`. `harness update` shows acknowledged files for the
record but no longer fails on them, and `--apply` never writes them;
`harness diverge <file>` appends with validation (a real, differing contract
file only). An entry that matches no template file fails loudly instead, so a
typo can't silently un-acknowledge the fork it meant. Delete the line to
un-acknowledge.

The comparison has to allow for the installer's own post-copy edits, or every
fresh install reads as stale: `bd init` leaves managed blocks in `AGENTS.md`,
and the tidier rewrites `.claude/settings.json` through `json.dumps`, reordering
every key. Both are normalised away on both sides. The gate has a step that
installs into a throwaway repo and asserts the result reads as current, because
that particular false alarm is invisible in the diff that causes it.

## Stack guidance ships only where the stack is

The reviewers' generic checks used to include force unwraps, retain cycles and
`List` rows, because the starter grew up on a Swift project. In a web project
those lines sent reviewers hunting for bugs the code couldn't have. So the
reviewers stay platform-neutral, and the platform checks live in
`harness/stacks/<name>.md`, one file per stack, each with a section per
reviewer. A reviewer reads the sections for the stacks `harness/stacks.txt`
lists.

`harness add` detects the stacks once, from markers that can't mean anything
else, and writes the list. From then on the list belongs to the project. A
wrong guess is fixed by editing it, and `add` never detects over it again,
so a correction stays put. The stack files are contract files: they come from
the starter, `update` keeps them current, and a project's own recurring bugs
go in the reviewers' FILL THIS IN blocks instead. A new stack is one file in
`template/harness/stacks/` plus a marker in `harness_detect_stacks`.

## Codex context

The template supplies `.codex/hooks.json` to run the existing project brief and
`harness/codex.md` for Codex task completion guidance. The installer removes
generated Beads instruction blocks and replaces generic Beads context hooks,
preserving unrelated hooks. Re-running it does not restore `bd prime` policy.
Codex hook trust remains local; run the brief manually until the hook is trusted.
Claude and OpenCode keep their existing startup configuration.

## Why it's shaped this way

One account, not a team of thirteen agents, so the whole design is
token-budgeted: progressive disclosure over always-loaded context, cheap models
for bulk reading, diff-scoped review. The stock beads SessionStart hook
(`bd prime`, ~1900 tokens every session) is replaced by `scripts/brief.sh`
(~500) — see below, because that replacement does not stay done on its own.

## The brief overrides `bd setup claude`, and has to be re-applied

`bd setup claude` installs a `bd prime --hook-json` SessionStart hook. The
harness deliberately does not want it: `bd prime` is a command reference and a
session-close protocol, which is what the `beads` skill holds and loads on
demand. Always-loading it is the exact instinct progressive disclosure exists to
resist, and it is not small — measured at 7,949 bytes against the brief's 2,122.
What a session actually needs at wake-up is ledger *state*, and `brief.sh`
already prints it: the seat and what it's for, the last note, the ready list,
the memory keys.

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

`scripts/context.py` reports what a session pays before it does anything —
both instruction files, the brief, `MEMORY.md`, and skill descriptions. It
counts `AGENTS.md` as well as `CLAUDE.md` because both are always-loaded, and
counting only one would let a session move text into the other and watch the
number fall while nothing changed.

The number is a trend line, not a gate: a cap here only ever measures how long
it has been since someone argued with the layer, and the librarian does that
better. Three things beside it *are* gates, because each is a silent regression
rather than a judgment call — a SessionStart hook the harness didn't install, a
bd managed block outside AGENTS.md, and a doc whose sources moved without it.

That count was also, for a while, quietly reassuring about the wrong number.
It measures what the repo adds, and — measured on one project — reported ~4k
while every real session opened at ~54k: the missing ~50k being Claude Code's
own system prompt, its tool schemas and whatever MCP connectors the app has
enabled. None of that is readable from a file in the checkout, so it was
invisible to a checker that only ever read files. It is readable from the
session transcripts, which record what each turn actually cost, so `context.py`
now measures the floor there and prints the repo's share inside it.
`context.py spend` breaks the same transcripts down per session, because the
two halves of the bill argue for different fixes: a short session is ~80%
floor and wants fewer connectors, a long one is mostly accumulated
conversation and wants its wide reads pushed into subagents.

## opencode gets a config and generated agents, never a symlink

Three things were checked against the installed binary rather than assumed, and
each one rules out a shortcut somebody will otherwise reach for:

**Skills need nothing.** opencode already discovers `.claude/skills/` natively —
`opencode debug skill` finds `workflow`, `beads` and `handoff` with no
`.opencode/` directory present at all, and the binary carries an
`OPENCODE_DISABLE_CLAUDE_CODE_SKILLS` switch, so it is deliberate rather than
incidental. Do not add a skills symlink.

**Agents cannot be symlinked.** opencode does not read `.claude/agents/`, and
pointing it at those files is worse than leaving them: the frontmatter loads and
then corrupts. `model: haiku` parses as provider "haiku" with an empty model id,
the comma-separated `tools:` string resolves to invalid, and `mode: all` puts
each reviewer in the primary agent picker beside build and plan. It looks like
it worked and fails at spawn. So the prompt body has one home,
`.claude/agents/`, and `scripts/opencode-agents.py` writes the other dialect's
header around it into `.opencode/agent/`. The gate checks the two match, because
nothing about editing the source makes opencode complain.

The generated agents carry no `model:` line — by design, not omission. The
roster is machine-local and gitignored: it names models this machine happens
to have, so a model line would bake one machine's answers into every clone's
committed files, and a fresh clone with an empty roster would generate
model-free files that fail check against them. Without a line the agent
inherits the session's model, which always resolves — the cost is that
`reviewer-taste` stops being the cheap one under a native opencode spawn. The
roster still picks the model everywhere a model is actually chosen:
`scripts/agent.py` passes it as `-m`.

A role's roster entry may add a `variant` — the provider's reasoning effort,
such as `xhigh` — which agent.py sends as `-m provider/model#variant`. Only there: no
generated file carries one, and `implement` runs opencode's own build agent,
which has no generated file at all.

Three paths to a model: the `.claude/agents/` frontmatter names Claude Code's
reviewers; the roster names `scripts/agent.py`'s; opencode's generated agents
and Codex inherit the session's and the host's. A model named in one path says
nothing about the others.

**`scripts/agent.py` is how every tool except opencode reaches the roster.**

It runs one role through `opencode run` — so Claude Code can put its
reviewers, and delegated implementation, on another provider's bill without
the packet ever entering its own context. Inside opencode itself, reviewers
always run as native subagents on the session model — no reviewer is ever
routed through `agent.py` from an opencode session. (Delegated implementation
is the exception: the `delegate` skill sends it through `agent.py` from any
tool, for the roster model.) Three behaviours of `opencode run` shaped it, all
found by running it:

- `--agent` given a `mode: subagent` agent prints a warning and falls back to
  the default agent, so the reviewer runs without its prompt. The script
  promotes the agent to primary for its own process through
  `OPENCODE_CONFIG_CONTENT`, leaving the generated files — and the picker —
  alone.
- OpenCode's free models answer the built-in agents and refuse every custom one
  (a 403 naming the free tier). A roster pointing a reviewer at a `-free` model
  works for `implement`, which runs `build`, and fails for every reviewer.
- Headless, every permission prompt is answered no and the agent carries on
  without it — including reads outside the project, which is where review.sh
  puts the packet. Reviewers are granted `/tmp`, and any other refusal makes
  the script exit non-zero rather than pass on a reply written blind.
- `reviewer-design` checks its selected model for image input before running:
  the legacy `opencode models --verbose` lookup first, then opencode's cached
  models.dev catalog (v2 dropped the flag). Unknown or text-only models fail,
  leaving the visual pass to the native reviewer instead of accepting a blind reply.

The revision cap lives in the script rather than in the `delegate` skill's prose
because guidance is what a long thread erodes first. It counts the session's
messages back out of `opencode session export`, so there is no counter file to lose.

**There is no session-start hook to write.** opencode's plugin hooks are
`event`, `chat.message`, `chat.params`, `chat.headers`, `chat.completion`,
`tool.execute.before/after`, `auth`, `config`, and `permission.*`. None of them
can inject context at session start — `event` is a notification sink with no
return channel. So the dynamic half of the brief has no automatic path here, and
AGENTS.md's "run `scripts/brief.sh` yourself" line is the fallback that covers
it. Don't build the plugin.

`opencode.json`'s `instructions` list is `AGENTS.md` and `CLAUDE.md` — exactly
what Claude Code always-loads, since `CLAUDE.md` imports `AGENTS.md`. opencode
finds `AGENTS.md` on its own and dedupes by resolved path, so naming it there
costs nothing and says what the harness intends. `HARNESS.md` is deliberately
not in the list: it is the rationale, read when the pieces are being rearranged,
and always-loading it in one tool and not the other would put the two sessions
on different budgets while `context.py` counted neither.

The root `opencode.json` is the single source of truth for both keys —
`instructions` and any `plugin` entries. A `.opencode/opencode.json` shadows
it: opencode reads only the deeper file when both exist, so a copy carrying a
plugin but no `instructions` silently unloads `AGENTS.md`, and a copy
duplicating either key hides drift the contract check never compares, because
it tracks only the root file. `harness update` fails the check on both — a missing
`instructions` list, or a copy duplicating either key — and `harness add` merges the root
instructions into an existing shadow. `.opencode/tui.json` carries UI
overrides only and must not hold plugin entries; plugin configuration lives in
the root file.

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
