<!-- tracks:
  .claude/agents/librarian.md
  .claude/agents/reflector.md
  .claude/agents/reviewer-correctness.md
  .claude/agents/reviewer-design.md
  .claude/agents/reviewer-taste.md
  .claude/skills/workflow/SKILL.md
  scripts/agent.py
  scripts/brief.sh
  scripts/build-wiki.sh
  scripts/context.py
  scripts/lib/journal.sh
  scripts/opencode-agents.py
  scripts/reflect.sh
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
  `scripts/harness ledger-push` regenerates the tracked `.beads/issues.jsonl` (with
  memories) on every push — the Dolt ref is the primary transport, the JSONL is
  what a fresh clone hydrates from, so the file stays committed, never ignored.
- **Skills:** `.claude/skills/` — `workflow` (the hub), `agentic-review`,
  `beads`, `handoff`. Each costs a description line until invoked; bodies are
  free until then. Add project-specific ones (how to build and drive the app,
  how to add a source file) as you learn what they are.
- **Reviewers:** `.claude/agents/` — `reviewer-taste`,
  `reviewer-correctness` and `reviewer-design`, each on the model its
  frontmatter names, run against a
  packet from `scripts/harness review`. Design reads screenshots rather than the
  diff, because a diff can't show you clipping. The packet carries untracked
  files too, and stages nothing to do it; its captures are dated from the
  working tree's first edit, so an unrelated session's screenshots stay out.
- **Librarian:** `.claude/agents/librarian` (sonnet) audits the knowledge layer
  from a digest, on a cadence, never on the hot path. It proposes; the calling
  session decides.
- **opencode:** `opencode.json` names the always-loaded files, and
  `.opencode/agent/` holds the reviewers translated into opencode's dialect by
  `scripts/harness opencode-agents`. See below — two of the obvious moves here are
  traps.
- **Gate:** `scripts/harness verify` — build, tests, optional smoke, plus doc
  staleness. Tiny output on purpose. The default lane is diff-scoped: only
  ledger paths changed (`.beads/`, `harness/handoffs/`,
  `harness/laurels.jsonl`) runs just the ledger export check and finishes in
  seconds, printing the scope it chose and why; anything else — or `--full`,
  or a scope it cannot determine — runs everything, loudly. Probes run in
  parallel, bounded by CPU count, each in its own throwaway repo copied from
  one golden install per run. The gate compares a fresh ledger export against
  the committed `.beads/issues.jsonl`, both directions: bd's auto-export is a
  timer, not a per-write flush, so without this a session commits a file that
  still lists closed beads and misses new ones. The pre-commit hook regenerates
  the export with memories and stages it on every commit, so the committed
  file is fresh whatever moved the ledger — that hook is the mechanism; the
  manual export before verify is the fast path and the gate's check is the
  backstop. The check runs before every other
  `bd` call in the gate, because several of them auto-import a stale export
  when the ledger looks stale — resurrecting deleted beads — and anything
  earlier would heal the drift under test and report a match on resurrected
  state. The close runs ledger writes, export, verify, commit, push: the push
  goes last, best-effort, never blocking the commit.
- **Dashboard:** `scripts/harness dashboard` serves a live diagram at localhost:7391.
  It never opens a browser itself. It publishes the live port to
  `.claude/launch.json` and prints the link with the instruction to open it in
  Claude Code's browser pane — the one browser the agent can read back and
  screenshot, and the one that doesn't land behind whatever window the human was
  already in. It backgrounds by default — the callers are hooks and
  agents, and a foreground server there is a terminal nobody gets back;
  `scripts/harness dashboard serve` is the form that blocks. If Portside knows the port it
  also prints the alias, matched on the launch directory too so a stale map
  can't name the board after someone else's server.

There is one board, run from the starter, and it costs nothing when nobody is
looking — which took deliberate work. Rebuilding state means three `bd`
spawns — each opening the embedded Dolt engine cold — plus git and a read of
every skill and gate log. Doing that every two seconds for an empty room
measured at roughly two thirds of a core across three projects' dashboards,
and it was the largest single consumer of idle CPU on the machine. So the
refresher watches for polls: a browser that asked for state in the last 30s
gets the `REFRESH` cadence, nobody gets `IDLE_REFRESH`, and a poll after a
quiet spell wakes the thread rather than waiting out the rest. Past
`EXIT_AFTER` with no poll at all the server stops itself, and the SessionEnd
hook calls `scripts/harness dashboard down` to stop it properly first — the timeout
is the backstop for a session that dies without running its hooks.

`harness add` also turns bd's telemetry off (`metrics.disabled`). Every `bd`
invocation otherwise forks a detached `bd send-metrics` that POSTs to a
third-party endpoint, and the dashboard runs `bd` several times a poll — on
one machine that came to roughly 150k requests a day. Network wakeups are
weighted heavily in macOS's energy accounting, which is why `bd` and not
`python` was what showed up at the top of Activity Monitor. The setting is
global to the user, so turning it off once covers every project.

## How a project reaches the harness

A project keeps no copy of the harness. It commits one small finder —
`scripts/harness`, a copy of `template/scripts/harness` — and reaches everything else
through it. The finder resolves the harness root — the `template/` tree
holding `.harness-root` — in order: the starter checkout's own `template/`
when run inside it, `$HARNESS_HOME`, `~/.harness`, then a fetched copy it
clones into a gitignored `.harness/`. Resolution itself is silent; every
failure is one line on stderr naming the fix.

`scripts/harness` dispatches the shared scripts with `HARNESS_PROJECT` and
`HARNESS_ROOT` set, so a project never names a path outside itself. `scripts/harness
link` symlinks the shared skills, agents, stacks guidance and contract into
the project, one link per shared entry, each gitignored: a real file or dir
at the same path wins silently. That is how a project keeps its own skills
beside the shared ones, and how a same-name entry shadows the shared one
(same for `.claude/agents/` and `.agents/skills/`).

The stubs in `template/stubs/` are what `harness add` writes in place of the
shared files — `AGENTS.md`, `opencode.json`, the hook configs, the
commit-msg hook — plus `scripts/harness` itself and the seeds. No shared scripts,
no skills, no agents: those stay in the checkout and arrive through the
finder instead.

So the split is by ownership, not by freshness. **Seeds** — the files
`harness add` writes once and the project then owns (`harness/seat.md`,
`AGENTS.local.md`, `scripts/verify.steps.sh`, `scripts/review.scope.sh`,
`dashboard.toml`) — are never touched again. **Overlays**
(`harness/reviewers/<role>.md`, one per reviewer) are never compared at
all: the project's own answers live there while the shared reviewer prompts
stay byte-identical. Everything else is the starter's, reached by link or
dispatch. A same-path project file that differs is a **shadow**: it wins
over the shared one, `scripts/harness doctor` lists it, and nothing ever
converges it — a project-specific change to a shared script stays as a
shadow; anything else moves into `AGENTS.local.md` or upstream to the
starter.

Seeds are one list, and only seeds may carry a fill-in block. Reviewer
prompts are never converged either: a filled-in prompt's answers belong in
its overlay, which is where `harness migrate` puts them.

Links are cheap and writes travel: a tool writing into a linked path edits
the shared harness for every project. `bd init` did exactly this — it wrote
its beads skill into `.agents/skills/beads`, which was already a link into
the checkout. So `harness add` links only after every `bd` command has run,
and the migrate-time link runs last for the same reason. Add links only
after bd.

Some drift is a fork, not a missed fix: a dashboard chip, a widened review
scope, a generator with project hooks. That stays a shadow forever, and a
warning nobody can clear is one that stops being read.
`harness/diverged.txt` is the acknowledgment — one path per line, committed,
with the reason after `#`. Migrate keeps acknowledged files in place whatever
they look like, and a broken entry fails loudly instead, so a typo can't
silently un-acknowledge the fork it meant. There is no command that appends
to it; delete the line to un-acknowledge. An entry that matches the template
again is dead weight — drop it.

The comparison behind all of this has to allow for the installer's own
post-copy edits, or every fresh install reads as changed: `bd init` leaves
managed blocks in `AGENTS.md`, and the tidier rewrites `.claude/settings.json`
through `json.dumps`, reordering every key. Both are normalised away on both
sides.

A copied install — one from before reference installs — converts with
`harness migrate`, dry run first: every carried file with its fate, nothing
written. `--apply` runs on a clean tree only. Unedited copies go, at any
starter revision; customised reviewer prompts lift their lines into
`harness/reviewers/`; a file that differs is left in place and named. Its
template must match the finder's root, or it refuses.

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
so a correction stays put. The stack files live in the starter and arrive
through per-entry links, so they are always current, and a project's own
recurring bugs
go in `harness/reviewers/<role>.md` instead. A new stack is one file in
`template/harness/stacks/` plus a marker in `harness_detect_stacks`.

## Where a project's answers go

| Today's customisation | Destination |
|---|---|
| Customised reviewer prompt | Project-specific lines move to `harness/reviewers/<role>.md` (`taste`, `correctness`, or `design`) |
| Own skill | Stays a real directory in `.claude/skills/` beside the per-entry shared links; a same-name entry shadows the shared one |
| `harness/seat.md` | Stays; it is a seed the project owns |
| A `diverged.txt` fork | A shadow file at the same path |

## Codex context

The template's stubs supply `.codex/hooks.json` to run the existing project brief and
`harness/codex.md` for Codex task completion guidance. The installer removes
generated Beads instruction blocks and replaces generic Beads context hooks,
preserving unrelated hooks. Re-running it does not restore `bd prime` policy.
Codex hook trust remains local; run the brief manually until the hook is trusted.
Claude and OpenCode keep their existing startup configuration.

The gate and ledger-only probes share `scripts/harness ledger-export-check`, so a
probe proves export integrity without running unrelated checks. Project gate
lanes live in `scripts/verify.steps.sh`; additive guidance in `AGENTS.local.md`
is never touched after install. Installation disables memory-less auto-export and
refreshes the ledger with memories explicitly. Work commits still need a bead;
session-only handoff and laurel commits use a narrow path-based exception.

## Why it's shaped this way

One account, not a team of thirteen agents, so the whole design is
token-budgeted: progressive disclosure over always-loaded context, cheap
Claude tiers for bulk reading, diff-scoped review. The stock beads SessionStart hook
(`bd prime`, ~1900 tokens every session) is replaced by `scripts/harness brief`
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

`scripts/harness context` reports what a session pays before it does anything —
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
`.claude/agents/`, and `scripts/harness opencode-agents` writes the other dialect's
header around it into `.opencode/agent/`. The gate checks the two match, because
nothing about editing the source makes opencode complain.

**opencode runs on one model at one variant, and the harness enforces it.**
`OPENCODE_MODEL` and `OPENCODE_VARIANT` in `scripts/harness models` are the only
definition. `scripts/harness agent` sends them as `-m model#variant` and refuses to
spawn on anything else; the generator bakes them onto every agent's `model:`
line; `opencode.json` pins the session model and every built-in agent to them;
`scripts/harness opencode-pin` fails the gate on any roster entry, agent file,
config, script or doc example that names another. `harness/models.json` only
records the pin per role plus an optional packet budget, and `ensure` writes
it without prompting.

This used to be a choice, and the choice is what went wrong: on 2026-11-03 a
project's `ensure` couldn't prompt (no terminal in the desktop app), a session
hand-wrote a roster of paid models across every role, and two orchestrate
rounds spawned ~15 sessions on them and exhausted the provider's limit. The
rule had been prose. Now there is nothing to choose, and every path that could
choose is checked.

Two paths to a model: the `.claude/agents/` frontmatter names Claude Code's
reviewers; the pin names everything opencode runs. Codex inherits the host's.

**`scripts/harness agent` is how every tool except opencode reaches opencode.**

It runs one role through `opencode run` — so Claude Code can put its
reviewers, and orchestrated implementation, on another provider's bill without
the packet ever entering its own context. Inside opencode itself, reviewers
always run as native subagents on the pinned model — no reviewer is
ever routed through `agent.py` from an opencode session. (Orchestrated
implementation runs through `agent.py` from any tool.) Three behaviours of
`opencode run` shaped it, all found by running it:

- `--agent` given a `mode: subagent` agent prints a warning and falls back to
  the default agent, so the reviewer runs without its prompt. The script
  promotes the agent to primary for its own process through
  `OPENCODE_CONFIG_CONTENT`, leaving the generated files — and the picker —
  alone.
- Headless, every permission prompt is answered no and the agent carries on
  without it — including reads outside the project, which is where review.sh
  puts the packet. Reviewers are granted `/tmp`, and any other refusal makes
  the script exit non-zero rather than pass on a reply written blind.
- `reviewer-design` checks its selected model for image input before running:
  the legacy `opencode models --verbose` lookup first, then opencode's cached
  models.dev catalog (v2 dropped the flag). Unknown or text-only models fail,
  leaving the visual pass to the native reviewer instead of accepting a blind reply.

The revision cap lives in the script rather than in a skill's prose
because guidance is what a long thread erodes first. It counts the session's
messages back out of `opencode session export`, so there is no counter file to lose.

**There is no session-start hook to write.** opencode's plugin hooks are
`event`, `chat.message`, `chat.params`, `chat.headers`, `chat.completion`,
`tool.execute.before/after`, `auth`, `config`, and `permission.*`. None of them
can inject context at session start — `event` is a notification sink with no
return channel. So the dynamic half of the brief has no automatic path here, and
AGENTS.md's "run `scripts/harness session` yourself" line is the fallback that covers
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
duplicating either key silently wins. `harness add` merges the root
instructions into an existing shadow, keeping the shadow's own entries;
afterwards the shadow is the project's to keep correct. `.opencode/tui.json` carries UI
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

## A session leaves a journal, and its findings stay searchable

Loop boundaries write machine lines to a per-session live journal —
`harness/handoffs/.live-<session-id>.md`, gitignored — so a failed gate, the
pass that followed, the packet built for review, and the commit carrying its
bead are all on record with zero model tokens. The session id comes from the
tool first (`HARNESS_SESSION_ID` to override, else the tool's own session
id); when none can be derived the scripts say so and write nothing rather
than sharing one file. Committed handoff notes stay one immutable file per
close; the close removes only its own live file, and the brief names another
session's unclosed journal in one line.

Review findings the session accepts or rejects land in
`harness/learning.jsonl` as `{"kind":"finding","category":…}` — one object
per line, category a short slug the session chose. The agentic-review skill
says how; readers skip `#` and blank lines, which is what the seed's schema
comment is.

## Reflect reads the close back

Every close ends with one reflector pass over what the session did — the
diff, the live journal, the beads it settled, recent findings, the note
draft — and at most three proposed lessons back. The packet is
`scripts/reflect.sh`, the prompt `.claude/agents/reflector.md`, and the close
runs them in `scripts/wrap-up.sh` before the ledger writes: default on,
`--no-reflect` to skip, and a clean tree with an empty journal skips itself
out loud. The reflector runs through `scripts/harness agent` on the pinned
model, natively inside opencode, and a failed run warns and never blocks the
close — an unrecorded lesson is cheaper than an unrecorded session. Zero
candidates is the normal outcome; a pass that always finds three things
teaches the session to ignore it, the same way a reviewer that always finds
three things does.

What it may propose is bounded by tier — a memory, one line for a reviewer's
overlay, a delta to a skill or to `CLAUDE.md` — and every candidate lands in
`harness/learning.jsonl` with its outcome, kept or dropped, and why. A close
passes `--candidates-file` when it keeps from a reviewed list, so the indices
mean what the session saw; without one a fresh run renumbers them. The
calling session decides; the script never rewrites prose on its own. Memory
deletions stay user-gated with an archive copy; lessons only add.
Orchestrated rounds reflect once per round, at the orchestrator's close, not
per worker.

## Consolidation is one librarian pass on a due signal

Capture and reflect only add knowledge; nothing removes it, so the layer only
grows. The librarian runs one consolidation pass — no second sweep.
`scripts/harness brief` prints at most one
`consolidation due: ...` line when the pass is due and nothing otherwise, and
it never runs the pass itself; the calling session runs the librarian through
`scripts/harness agent` on the pinned model (natively inside opencode),
applies what it keeps, and resets the marker by writing the current UTC time
into `harness/.last-consolidation`.

Due means (>=5 handoff notes newer than the marker AND the marker older than
24h) OR pressure: more known traps than the brief's budget, >=3 lessons on one
target in `harness/learning.jsonl`, or one finding category 3 times. Pressure
counts only rows with a ts newer than the marker timestamp, and the reset
writes the current UTC time — a pass clears the count until new rows land. The
five numbers live in the one Tune here block at the top of `scripts/brief.sh`;
the logic below them stays untouched. A missing or empty marker means no pass has
run — cadence has nothing to measure from, pressure still applies, and a fresh
install stays silent because it carries no pressure.

The pass scopes to what changed since the marker plus the likely-to-change
entries (anything naming a command, path, flag, or number), never a re-audit
of everything. Beside delete/merge/move/shorten it carries three duties:
promote (a lesson logged 2+ times, or a memory the sessions keep needing,
moves up a tier), correct (memories naming commands, paths, flags, and numbers
checked against the repo, the handoffs, and the closed beads — false claims
first), and prune. A finding category seen 3 times becomes a reviewer-trap
proposal by rule. The librarian proposes only, exactly like the reflector;
memory deletions stay user-gated with an archive copy. If the project logs
`bd recall` keys, later passes weight by access; otherwise they skip that —
never new instrumentation on the hot path.

## The wiki is derived, never primary

The brief's memory-key line grows with every trap the sessions keep, and a flat
list of fifty keys abstracts nothing — nobody can hold it, so nobody reads it.
Past a threshold (`WIKI_MAX_KEYS` in `scripts/brief.sh`, beside the
consolidation numbers) the brief prints topic names from
`harness/wiki/index.md` instead, and the pages load on demand. A stale index
(counts not matching the live ledger) is ignored for the current capped key list. Below the
threshold nothing changes: the brief reads exactly as before and the directory
may not exist.

`harness/wiki/` holds the index plus one page per topic, generated from bd
memories, closed-bead reasons and committed handoff notes by
`scripts/build-wiki.sh` — the pattern is the managed-agents knowledge wiki
(extract, resolve gaps, consolidate; provenance on every fact, conflicts kept
as conflicts), reimplemented with local files and bd instead of a hosted
store. The topic of a key is the first slug segment before `-` or `_`, which
keeps the grouping mechanical: there is no judgment in it to drift. Distinct topics
sanitizing to one filename share it by suffix (first wins, case-insensitively). Pages link
to bead ids and memory keys and quote facts verbatim with their source; they
never copy bodies. The generator is the only writer, and it checks its own
links as a second pass before publishing — every key on exactly one page,
every index entry backed by a page and vice versa. The librarian proposes the
build (and the merges or renames that would make the grouping land better); the
session runs it and reviews the diff.

Deleting the directory and rebuilding diffs empty, because everything in it is
re-derivable — that is also why generated pages are project-owned data, like
`harness/learning.jsonl`: installed never (the script creates the directory),
compared never, converged never. Hand-editing a page is pointless; the next
rebuild overwrites it.

Two caps keep the summary smaller than what it summarises: the index may not
exceed half the source bytes, the whole wiki may not exceed them. Over the
total cap the build prunes excerpt and bead quotes first — key links always survive,
because reachability is load-bearing — and a breach past that fails loudly,
removes any published wiki, and publishes nothing (swapped atomically when it does publish). `context.py` counts the index in the always-loaded budget,
includes the wiki in the librarian's digest, and watches pages carrying
`tracks:` through the staleness gate like any other doc, reporting a blessed-but-deleted page as missing and pruning a lock entry whose page lost its tracks.

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

## Reference install: what each tool can load from outside the repo

Spike har-b5n8.1, run against Claude Code 2.1.251, opencode 2.0.19 and
codex-cli 0.163 on macOS. Each row was proved by a canary run unless marked
unverified; re-test a row before leaning on it after a tool upgrade.

| Artefact | Claude Code | opencode | Codex |
|---|---|---|---|
| Always-loaded contract | `CLAUDE.md` `@`-import of a path outside the project is **silently skipped** (absolute, `~`, and a symlink whose target is outside all failed in a live session; an in-project import loaded). Use a SessionStart hook that prints the contract as context. | A project `AGENTS.md` symlinked to the checkout loads. `instructions[]` entries pointing outside did not load in the worker's runs (not independently confirmed). A plugin `context` hook also injects text. | `AGENTS.md` `@`-import loads for absolute, `~` and `$VAR` paths; `$CODEX_HOME/AGENTS.md` loads alongside. |
| Skills | Symlinked `.claude/skills` loads. `--plugin-dir` loads but is a per-run flag. Project-scope `extraKnownMarketplaces` is silently ignored; a user-scope marketplace works but writes global config. `--add-dir` exposes nothing. | `skills: ["<path>"]` in config, or a symlinked `.claude/skills` / `.agents/skills`. | `<repo>/.codex/skills`, `$CODEX_HOME/skills`, `~/.agents/skills`. |
| Agents | Symlinked `.claude/agents` loads; plugin `agents/` loads. | File and directory symlinks under `.opencode/agent(s)/` now load (the older "cannot be symlinked" finding no longer holds on 2.0.19). `.claude/agents` is still ignored. Inline `{file:…}` loads but a missing target returns 500 for every run in the project. | not tested |
| Session start | Project SessionStart hook runs an outside script; `~` and `$HOME` expand; it fires headless even in a never-trusted folder. | No hook. A plugin loaded from an outside path runs `setup()` at load; otherwise the "run the brief yourself" line. | `.codex/hooks.json` SessionStart did **not** fire under `codex exec` in four configurations; interactive unverified. Keep the manual-brief line. |
| Running shared scripts | Denied headless by default ("requires approval"); an allow rule naming the script lets it run. Project `permissions.allow` rules are dropped in a never-trusted folder until the trust dialog is accepted. | Denied headless without a grant (exit 1); `permission.external_directory` with an absolute or `~` path allows it. | not tested |
| Harness absent | Missing import, marketplace, `--add-dir`: silent. Missing hook script: exit 127, session continues. | Missing instruction, skills path, dangling agent symlink: silent. Missing plugin: warning only. | Missing import: silent. |

Also proved: a commit-msg shim that `exec`s the shared hook fails closed when
the checkout is absent; `core.hooksPath` pointed at the checkout fails **open**
(commit passes, no hooks) and would displace the beads hooks that already own
`core.hooksPath`. `.opencode/opencode.json` now merges with the root config
rather than shadowing it. The starter repo clones anonymously in under a
second (3.6 MB shallow).

What this decides:

- **Almost every missing-path case is silent**, so no stub may name the shared
  checkout directly. Each project commits one small resolver; hooks, the git
  shim and every command go through it, and it is the only place that fails
  loudly.
- **The resolver's order is `$HARNESS_HOME`, then `~/.harness`, then a
  gitignored in-project `.harness/` it clones itself** (cloud, CI). No tool
  needs a fixed home path once the resolver exists.
- **Skills and agents arrive as gitignored symlinks the resolver creates**,
  the one mechanism proved on both Claude Code and opencode with no global
  config. Pointing them at whichever root was resolved covers the fetched case.
- **The contract arrives by injection, not import**: SessionStart hook on
  Claude Code, symlinked `AGENTS.md` or plugin on opencode, `@`-import plus the
  brief line on Codex.
- **Agent-run commands use an in-project path** (the resolver), so permission
  rules never name a path outside the repo.

A skill reached through a symlinked `.claude/skills` invokes end to end, and a
headless Claude Code session confirms the outside `@`-import is not loaded.

Unverified and owed to har-b5n8.4: whether skills
symlinked by a SessionStart hook are discovered in that same first session;
Codex interactive hooks; opencode `instructions[]` outside an ancestor
`AGENTS.md`.
