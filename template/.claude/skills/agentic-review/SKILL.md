---
name: agentic-review
description: Review a change with agents that didn't write it — taste against the project's standards, correctness hunting real defects, and design reading screenshots of what actually rendered. Use before committing a non-trivial change, when asked to review work or a branch, or after finishing a feature.
---

# Reviewing work you just did

The point of this is separation, not ceremony. An agent reviewing its own diff
in the same context mostly agrees with itself. Two fresh agents that never saw
the reasoning behind the code catch what you can't.

## The pass

```bash
scripts/verify.sh            # 1. it has to build and pass tests first
                             # 2. drive the app and capture it — see below
scripts/review.sh            # 3. build the packet, prints its path
```

Then spawn all three reviewers **in parallel, in one message**, each pointed at
the packet path:

- `reviewer-taste` — the project's own standards
- `reviewer-correctness` — real defects
- `reviewer-design` — what it actually renders

`scripts/review.sh` refuses (non-zero) when the packet exceeds the smallest
reviewer budget instead of printing a path — narrow the range and re-run.

Give each one only the packet path and one line on what the change was meant to
do. They read `CLAUDE.md` themselves. Don't paste the diff into the prompt —
that's the packet's job, and pasting it doubles the cost.

**Off the account, when the roster allows.** If `harness/models.json` names a
model for `reviewer-taste` and `reviewer-correctness`, run those two through
opencode instead of spawning them — each as its own background command, so
the two run at once:

```bash
scripts/agent.py reviewer-taste "Review <packet> — <what it was meant to do>"
scripts/agent.py reviewer-correctness "Review <packet> — <what it was meant to do>"
```

Same prompts, same packet, different model and bill. A non-zero exit is a
reviewer that didn't run, not one that found nothing — spawn it natively
instead. `reviewer-design` stays native: it reads screenshots, and a roster
model that can't see pixels would pass every one of them.

Review a change that doesn't build yet and you'll get findings about the
breakage instead of the design, so keep the order.

## Step 2 is not optional for anything on screen

`scripts/review.sh` collects the `/tmp/<prefix>-*.png` captures (the ledger's
prefix, resolved at runtime) and lists them
in the packet, so whatever you shot while verifying is what the design reviewer
looks at. Shoot the screens the change touches, on every surface it ships to.

For an uncommitted tree the window starts at the working tree's first edit, not
at HEAD — HEAD can be days old, and a packet dated against it swept in whole
sessions of unrelated screenshots for the reviewer to read as current. **Build
the packet after you shoot**, or the captures land outside it: a packet built
first and screenshotted second lists nothing.

**Shoot the case that motivated the change, not the tidy one.** A card that
exists to show long values in full has to be photographed holding a long value.
Build the fixtures so that awkward case is the default, and drive the app
against them rather than against the user's real data — it makes the hard case
free to capture, and keeps the review off anything private.

A packet with no captures says so in place of the list, and the design reviewer
is told to report that as its first finding. That's deliberate: a UI change
nobody looked at is the defect.

## Why it's shaped like this

- **Diff-scoped.** Reviewers see the change, not the repo. A review that reads
  the whole tree costs more than writing the feature did. The cost of that is a
  `SCOPE` list in `scripts/review.scope.sh` that has to earn every suffix it carries:
  a file type missing from it is a file no reviewer has ever read.
- **One packet, many readers.** `scripts/review.sh` writes the diff to a file
  once; each reviewer reads that file instead of running its own git commands.
  Three agents, one diff-assembly cost.
- **New files are in the diff too.** A file git doesn't track yet is where a new
  capability usually lands, and `git diff` says nothing about one — the packet
  reads them out with `--no-index` instead. It never stages anything: an
  intent-to-add entry left in the index gets committed in full by the next
  `git commit -a`, which would ride an untracked scratch file into someone
  else's commit.
- **Fit the model to the read.** A native Claude Code spawn runs the model and
  effort in the reviewer's `.claude/agents/` frontmatter. Under opencode — and
  through `scripts/agent.py` from anywhere — each role runs whatever
  `harness/models.json` gives it. Under Codex every role inherits the host
  model.
- **One reviewer looks at pixels.** In the project this came from, both diff
  readers passed a card that clipped every value it existed to show — and were
  right to: nothing in the diff was wrong. The defect lived in the render, in a
  line-limit inherited from a container three levels up. A reviewer that reads
  screenshots is the only one that could have caught it.
- **Findings need a failure.** All three reviewers are told an empty report is
  a good outcome. A reviewer that always finds three things teaches you to
  ignore it.

## Acting on the results

You are the one who decides. The reviewers are fresh but they're also
uninformed — they don't know what the user asked for or what you already ruled
out. Fix what's real, and say plainly what you're not fixing and why.

File anything worth doing but out of scope as a bead (`bd q "…"`) instead of
expanding the change. Don't leave findings only in the conversation; that's the
one place they're guaranteed to be lost.

## Scaling it down

Not every change earns three agents. A one-line fix, a comment, a test tweak —
just `scripts/verify.sh` and commit. Reach for the full pass when the change
introduces a component, alters shared state, touches concurrency or a parser,
or spans more than a couple of files.

Anything that changes what's on screen earns `reviewer-design`, however small —
that's the pass that costs the least to run and catches what nothing else can.

## The heavier option

`/code-review ultra` runs a multi-agent cloud review of the branch and is more
thorough than this. It's user-triggered and billed separately — mention it when
a change genuinely warrants it, but never try to launch it yourself.

<!-- tracks: scripts/review.sh scripts/agent.py .claude/agents/reviewer-taste.md .claude/agents/reviewer-correctness.md .claude/agents/reviewer-design.md -->
