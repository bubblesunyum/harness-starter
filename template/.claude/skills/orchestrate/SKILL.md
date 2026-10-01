---
name: orchestrate
description: Run a multi-bead implementation round as PM — select and partition beads, spawn parallel implementers, gate once, review, and land follow-ups. Use when the user asks to orchestrate a batch of beads, run a wrap-up round, or fan work out to parallel implementers while keeping ledger, commits, gate, and reviews on one owner.
---

# Orchestrating an implementation round

One orchestrator, many implementers, one tree. The orchestrator owns the
ledger, the gate, the review pass, and every commit. Implementers own only
file edits inside their partition. That split is the whole design — it is
what lets N workers share a tree without merge conflicts, double commits,
or a gate run per worker.

Proven shape: N beads, N background implementers, one gate run, one
review packet round, per-bead commits. Provenance for a specific round
lives in its beads and commits, not here.

## Inputs

Every round starts with three answers, from the user or your judgment:

- **Bead count.** How many beads this round carries. More than ~9
  and the collect/adjudicate steps stop fitting in one window —
  split into two rounds.
- **Focus / exclude areas.** Which epics or paths are in scope, which are
  explicitly out. Excluded work is not reconsidered mid-round; it is the
  next round's input.
- **Token budget (real, not decorative).** A per-worker spend cap and a
  round cap, plus the stop/continue rule before spawning anything. See
  "Budget" below.

## Phase 1 — Select and claim

1. `scripts/brief.sh` first. It is the state: ready work, memory keys,
   last session's note. Do not re-derive it by hand.
2. Select from `bd ready` inside the focus areas, minus the excludes.
   Prefer beads whose acceptance is already written; the next step specs
   the rest before anything is briefed.
3. Auto-spec each selected bead before briefing. For every candidate
   missing design or acceptance, write them back with `bd update <id>
   --design "<...>" --acceptance "<...>"`, then re-read with `bd show
   <id>` and brief only from what the re-read confirms. A bead you
   cannot spec is a bead you cannot brief — it waits for the next round,
   it does not ride along unspecced.
4. Check overlap with `grep` across the candidate beads' files: two
   workers on overlapping paths is a merge conflict you scheduled. If
   two beads overlap, they go sequential (same worker, ordered briefs)
   or one of them waits for the next round.
5. **Claim all selected beads upfront** (`bd update <id> --claim`).
   The ledger then shows the round as live, and no other session picks
   up the same work mid-round.

## Phase 2 — Partition and brief

Each implementer gets a self-contained brief. The brief is the whole
spec — the worker starts cold, with AGENTS.md and CLAUDE.md and nothing
else. One message per worker:

- the bead id and `bd show <id>` text;
- OWNED paths vs FORBIDDEN paths (its partition, and everything outside it);
- known traps (from memory keys and the bead);
- acceptance criteria and only the scoped checks that prove them —
  never `scripts/verify.sh` (the gate runs once, on the frozen tree,
  by the orchestrator);
- the fix-as-you-go rule (below).

## Phase 3 — Spawn implementers

Spawn one implementer per partition, in parallel, all on opencode — the same
rule reviewers already follow. Inside opencode, spawn native background
subagents. From Claude Code or Codex, run them through the opencode CLI
(`scripts/agent.py` with the `harness/models.json` roster — never the
host-native Task/agent mechanism for a round). The parallel same-tree
contract below travels in every brief regardless of tool. (The roster needs
an implement role carrying that contract; until it has one, the CLI call
must pass the brief through as-is — do not duplicate the contract
here — this skill *is* it.)

**Parallel same-tree contract** (in every brief, no exceptions):

- edit only OWNED paths; read anything, touch nothing else;
- no `bd` commands, no commits, no `scripts/verify.sh`,
  no `scripts/review.sh`, no reviewers;
- **fix things as you go** rather than filing beads — a broken import
  on the path to done gets fixed, not filed. File a bead only for
  something significant enough to be its own bead: out of scope,
  undecided, or bigger than the fix it rode in with.

## Phase 4 — Collect and gate

1. Collect reports. **A report is a claim, not evidence**: re-read
   every diff yourself before believing any of it.
2. Freeze the tree — no edits until the gate reports — and run
   `scripts/verify.sh` once. One gate per round: a gate per worker
   multiplies slow probe runs for no new signal, and editing mid-run
   manufactures phantom failures (a probe split across an edit reads
   as drift that isn't there).
3. Fix gate failures directly only when super small (a lint line, an
   import); anything larger goes back out as a revision brief.

## Phase 5 — Review

1. `scripts/review.sh` builds the packet; run `reviewer-taste` and
   `reviewer-correctness` against it in parallel, plus
   `reviewer-design` whenever anything on screen moved.
2. **Packets are static — rebuild before each round.** A packet built
   before a revision is evidence about a tree that no longer exists.
3. Captures are cheap when the app has an e2e scene spec: include
   capture-on-demand in reviewer briefs (which scenes, which states)
   rather than treating screenshots as a separate expedition.

## Phase 6 — Adjudicate and follow up

Batch all findings first, then apply in one revision: fix what's real,
file the rest as beads, and say plainly what you left and why.

- **Review follow-ups are planned and re-spawned as implementers** —
  same contract as Phase 3, scoped briefs, one finding cluster per
  worker. The round structure exists for revisions too, not just the
  first pass.
- The orchestrator fixes directly **only when super small**: the test
  is whether describing it costs more than doing it. Anything that
  needs a decision goes back out rather than in by hand.

## Phase 7 — Commit and close

- Commit policy: **split commits by bead by default** — one commit per
  bead, each naming its bead. Batch into a single round commit only when
  the beads are super tightly coupled (one story that reads as nonsense
  split apart). Either way every commit names its bead — the commit-msg
  hook enforces it.
- Attribute multi-author work in the commit body (which beads, which
  workers) so a later session can ask why a line looks the way it does
  and get an answer.
- Close each bead with the reason (`bd close <id> --reason "<what
  actually happened>"`), and note ledger identity for subagent work
  on the bead (`bd note <id> "round: <worker-model>, <rounds> rounds,
  <accepted | revised | finished by hand>"`) — over a few dozen
  rounds that is the only record of what parallel implementation
  actually costs and carries.
- Round accounting: per-worker spend vs cap, round total vs budget,
  filed in the same note or a memory so the next round's budget is a
  measurement, not a guess.

## Budget

No cost accounting means no budget, so the budget is enforced, not
aspirational. Before spawning: record each worker's cap (from the
brief size and the bead's scope — a rename costs less than a design
call) and the round cap (sum of workers plus gate plus reviewers;
reviewers are the cheapest line — ~15k tokens total across a full
pass is normal). Default when the user names no budget: 30k tokens per
worker, 100k for the round. Only do something different when explicitly
asked. During the round: track spend per worker; a worker
past its cap stops and reports, and the orchestrator decides —
continue (raise the cap deliberately), re-scope (split the bead), or
take back (finish by hand). A cap raised without the note is a cap
that never existed.

## Decisions this skill already makes

| Question | Answer |
|---|---|
| Who owns ledger, commits, gate, reviews? | Orchestrator, always. |
| One implementer per tree (`delegate`) vs parallel? | `delegate` for single decided work; this skill for parallel same-tree rounds under the contract above. |
| Fix or file mid-task? | Fix, unless significant enough for its own bead. |
| Who fixes review findings? | Re-spawned implementers; orchestrator only when super small. |
| Batched or per-bead commits? | Per-bead by default; batched only when super tightly coupled. |
| Who is the ledger identity for subagent work? | The orchestrator's note on each bead, per Phase 7. |

<!-- tracks: scripts/brief.sh scripts/verify.sh scripts/review.sh scripts/agent.py -->
