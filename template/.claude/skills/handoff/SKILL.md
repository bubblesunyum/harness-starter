---
name: handoff
description: Close out a session on purpose — settle the ledger, leave a note for whoever wakes up next, and optionally hand straight off to a fresh agent. Use when work is wrapping up, when the context window is getting long, or when the user says to hand off, wrap up, or take a beat.
---

# Ending a session

A session that stops mid-sentence leaves the next one to reconstruct what it was
thinking from a diff. The reconstruction is never as good as the note would have
been, and the note takes thirty seconds.

Handoff is a request, not an event that happens to you. If the work isn't at a
place where it can be put down — a half-applied refactor, a failing gate — say so
and finish the piece first.

## The close

The close ends on the commit, period: after the capture lands, zero `bd`
writes and zero file edits. Anything that moves afterwards is not finishing
the round — it is starting a new one, and it gets its own bead and its own
gate.

Prefer `scripts/harness wrap-up` over hand-ordering the steps below — it runs them
in the order that stays clean (ledger writes, export, verify, commit, push).
The pre-commit hook stages a fresh export on every commit, so the order is
belt and braces; the manual export is the fast path and the gate check the
backstop. The script proves the promise itself (wrap-up's step 7 fails a dirty
tree), so a green run already means the rule held:

```bash
scripts/harness wrap-up -m "lowercase terse message" --bead <id> \
  [--close <id> --reason "..."] [--note <id> "..."] [--remember "..."] \
  [--quick|--full] [--no-push] [--note-file harness/handoffs/<ts>.md]
```

Reflect runs at every close, before the ledger writes: wrap-up builds the
packet and runs the reflector on the pinned model — natively inside opencode,
where the session spawns the reflector itself against the printed packet.
`--no-reflect` skips it; a clean tree with an empty journal skips itself and
says so; a failed reflector warns and never blocks the close. Zero candidates
is normal. Preview with `scripts/harness reflect` (builds the packet, runs
the reflector, prints the candidates and the candidates file path, writes
nothing to learning.jsonl), then keep with `wrap-up --candidates-file
<path> --keep-lesson N` for what to keep (memory-tier keeps land via `bd
remember`; other tiers you apply as small deltas by hand) — without the same
`--candidates-file` a fresh run renumbers the candidates under you.
Log anything decided outside wrap-up with
`bash "$(scripts/harness root)/scripts/lib/journal.sh" lesson --tier <tier>
--target <target> --text <text>
--evidence <evidence> --outcome kept|dropped [--why <why>]`.

Write the note first and pass it as `--note-file`: the run commits the work
first (the note file excluded), then lands the note in its own capture commit
— that capture commit is the one the close ends on. Append any laurel before
the run so it rides the work commit. All closes, notes, and remembers go
through the flags — never a `bd` call after the capture lands. Push is the
only thing that runs after (it moves the Dolt ref, not the tree). The numbered
steps are the manual fallback when the script doesn't fit — same shape, same
proof at the end:

1. **Settle the ledger.** Claimed beads are closed with a reason, or returned to
   open with `bd update <id> --status open`, followed by
   `bd note <id> "<where it stands>"`. Discoveries filed with `bd q`.
   Anything that surprised you written with `bd remember`. Write the handoff
   note file now, before anything commits.
2. **Prove the tree and commit.** `scripts/harness verify` passes; commit the work
   (leaving the note file out), then commit the note file on its own as the
   capture — that capture commit is the ending commit, and nothing moves
   after it.
3. **Push the ledger, after the commit.** `scripts/harness ledger-push`, best-effort:
   a failed push warns and the commit stands. The beads are not in the commit
   you just made — they ride their own git ref, and nothing moves it for you. A
   session that skips this leaves the whole ledger on one disk.
4. **Prove the promise.** `git status --porcelain` empty and the ledger export
   check green. A red proof means the close is still in progress — not over —
   so fixes here are still the same round, not a new one. What would break the
   rule is writing after a green proof.
5. **Say what you'd pick up next**, in the note. The next session's brief shows
   this before it shows the ready list.

## The note

Let the shell name the file. The brief picks the newest note by filename, so a
stamp typed from memory silently reorders history — an invented one has already
buried a real note under a timestamp an hour in the future.

```bash
echo "harness/handoffs/$(date +%Y%m%d-%H%M%S).md"    # write to this path
```

One file per closing session, never overwritten — two sessions running at once
would otherwise clobber each other, and the point of a note is that it survives.

`scripts/harness brief` reads **the newest note's first three lines** at wake-up, so
put what matters first and keep it to a few lines. What belongs here is what the
structured fields can't hold: what you were mid-thought on, the approach you
rejected and why it still tempts you, the thing that felt wrong but that you
couldn't pin down. Not a summary of the diff — git has that — and not a restated
close reason.

Reference beads and commits by id rather than re-explaining them. Redact
anything sensitive; this file is committed.

```markdown
# handoff 2026-08-11

Closed abc-1a2b — the inset really was a no-op, not a sign error.
Was mid-thought on whether the same double-inset exists in the calendar layout;
didn't check. If it does, it's the same fix.
```

## Laurels

If the user said something genuinely appreciative this session, append it to
`harness/laurels.jsonl` before you go — one JSON object per line:

```json
{"date": "2026-08-11", "quote": "the magazine layout is gorgeous", "context": "abc-1a2b"}
```

Real praise only, in the user's own words. Not politeness, not "thanks" at the
end of a request, and never something you inferred from a task being accepted.
A laurel carries no work and no priority by design; the moment it's attached to
one it stops being recognition and turns into a score worth farming. Padding
this file corrupts the one signal in the harness that isn't a metric.

## Commit the capture

The capture commit is the close's ending commit: wrap-up lands it itself
(step 5, note file only, after the work commit), and the manual fallback does
the same by hand. It is the last mutation either way — nothing moves after it.
The standalone form below is only for a note-only close, where no work commit
exists to precede it.

Stage the handoff note and laurel entry, then commit them as session artifacts:

```bash
git add harness/handoffs/<timestamp>.md harness/laurels.jsonl
git commit -m "record session handoff"
```

The commit hook allows a commit with no bead only when every staged path is one
of those capture files. A commit that also contains source or other project
changes still needs a real bead, as does source work committed separately.

## Handing off to a live successor

When the user wants the work continued **now** rather than at the next session,
write the note first, then launch a seeded agent:

```bash
claude --bg --name "<short descriptive name>" "<the handoff summary>"
```

It starts in the working directory and returns immediately; the user manages it
with `claude agents`. Include a "suggested skills" line in the summary. Don't
duplicate what's already in beads, commits, or a plan file — reference those by
id or path.

<!-- tracks: scripts/brief.sh scripts/wrap-up.sh scripts/reflect.sh -->
