---
name: delegate
description: Hand implementation to an opencode agent on another model and review what comes back — brief it, read its diff, send at most two rounds of revisions, then accept, finish it yourself, or re-brief. Use when a bead is specced well enough that the work is typing rather than deciding, or when the user asks to delegate or to spend fewer of this account's tokens on implementation.
---

# Delegating implementation

`scripts/agent.py implement` runs the change in a separate opencode process, on
the model `harness/models.json` gives the `implement` role. You stay the
reviewer: the implementer never sees your context, and you never pay for its
reads. That split only earns its keep when you actually review — a delegated
change you wave through is an unreviewed change with extra steps.

## When it's worth it

Delegate work that is **decided but not done**: the bead says what done looks
like (`--design` and `--acceptance` filled in), the files are known, and nothing
in it sets taste. A rename across twenty files, a new gate step shaped like the
last one, a fix whose cause you already found.

Keep work that is mostly deciding — a design call, a debugging hunt, anything
whose brief you can't write without doing half the thinking. And keep anything
you can finish in a couple of calls; a brief costs more than that.

## The brief is the whole spec

The implementer starts cold, with AGENTS.md and CLAUDE.md and nothing else. Give
it, in one message: the bead id and `bd show <id>` text, the files it should
touch and the ones it must not, the acceptance check, and anything you already
ruled out. `agent.py` wraps it in a contract that keeps the ledger, commits and
the review pass on your side.

```bash
bd update <id> --claim
scripts/agent.py implement "<id>: <the brief>"     # run it in the background
```

One implementer per working tree, and don't edit that tree while it runs — you
would be two writers on one diff with no way to tell whose line is whose.

## Review what came back

Its report is a claim, not evidence. Read `git diff` yourself, run
`scripts/verify.sh` yourself, and check the acceptance criteria against the diff
rather than against the report. Then one of three outcomes:

- **Accept.** It's right. Carry on to the standing review pass and commit as
  usual — you didn't write it either, but the reviewers still read it cold.
- **Revise.** Send every finding in *one* message, each with the file, what's
  wrong, and what done looks like:
  `scripts/agent.py implement --session <id> "<all of it>"`.
  The session id is on stderr from the last run.
- **Take it back.** Below.

## Keep the thread short

A session gets the brief and two revisions; `agent.py` refuses a fourth message
(exit 3). Don't wait to hit it. Stop revising and take the work back when:

- what's left is small — a fix you can make in less time than it takes to
  describe it;
- a round fixed one thing and broke another, or the same point came back
  misunderstood twice;
- the approach itself is wrong. That's a brief problem, not a revision problem:
  discard its changes, say in the bead what the brief missed
  (`bd update <id> --design …`), and either re-brief a fresh session or do it
  yourself.

Revising is for gaps; re-briefing is for misunderstandings. Nudging a wrong
approach one message at a time is the long thread this cap exists to prevent.

## Leave a trace

Note it on the bead — `bd note <id> "delegated: <model>, <rounds> rounds,
<accepted | finished by hand | re-briefed>"`. Over a few dozen of these, that is
the record of which models can carry which work, and it's the only one there is.

<!-- tracks: scripts/agent.py -->
