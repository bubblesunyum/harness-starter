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

1. **Settle the ledger.** Claimed beads are closed with a reason, or returned to
   open with `bd update <id> --status open`, followed by
   `bd note <id> "<where it stands>"`. Discoveries filed with `bd q`.
   Anything that surprised you written with `bd remember`.
2. **Prove the tree.** `scripts/verify.sh` passes and the work is committed.
3. **Push the ledger.** `scripts/ledger-push.sh`. The beads are not in the commit
   you just made — they ride their own git ref, and nothing moves it for you. A
   session that skips this leaves the whole ledger on one disk.
4. **Write the note.** Below.
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

`scripts/brief.sh` reads **the newest note's first three lines** at wake-up, so
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

<!-- tracks: scripts/brief.sh -->
