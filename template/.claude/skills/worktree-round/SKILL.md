---
name: worktree-round
description: Run ANY orchestrated round in an isolated git worktree when a second live session, a reference install, or any symlink client (.harness link, linked skills/template) reads this checkout — also any multi-bead change to shared/template files. If live symlinks might vend the change, use this before orchestrate.
---

# Isolated worktree rounds

Run the round in a git worktree under `./.tmp/`, not in the main tree.
`orchestrate` still governs the round itself — selection, briefing,
gating, review, commits. This skill only changes *where* the round
happens and when its result lands in main.

Run every command below from the main-tree cwd, path-qualified. The
finder resolves the project from its own script path, never from cwd,
so a bare `scripts/harness ...` run from a main-tree cwd operates on
main even when the surrounding prose says "in the worktree". Pin a
worktree invocation by spelling it `./.tmp/<round-name>/scripts/harness ...`;
write bare `scripts/harness ...` only when you mean main. Workers spawn
with a main-tree cwd, so this rule is what keeps their tree pinned.

## The gotcha: collect opens the exposure window

Collecting worktree edits into main vends the change to every live
symlink client from that moment on — reviewed or not, gated or not.
The gate and the review pass therefore happen *before* collect, never
after. A green gate run in main after collect proves the merge, not
the change; by then the unreviewed code is already live for anyone
reading through a link.

Why this is structural rather than procedural: symlinked
skills and template paths resolve to the main checkout at read time.
A second session, a reference install, or any client created by
a main-tree `scripts/harness link` never reads the worktree — it reads main, on
every read. There is no staging state for a symlink. The only
isolation available is to keep the edits out of main until they have
already passed the gate and the reviewers inside the worktree.

Generalize from that: whenever the reader of a path is a live link
into this checkout, treat every write to the link target as a publish,
and do all unreviewed work somewhere the link cannot see.

## When this applies

- A second live session reads this checkout while the round runs.
- The project runs by reference, or any client holds a `.harness`
  link, linked skills, or a linked template into this checkout.
- The round touches shared or template files (`template/`,
  `harness/`, skills, scripts) where more than one bead lands in the
  same linked surface.
- When in doubt, check for links: anything under the client root
  that `is_symlink` and resolves into this checkout counts. A
  one-worker round on unlinked project files does not need this.

## Procedure in order

Do these in this order; each step exists to keep the exposure window shut.

1. Settle the ledger in main before the cut. File the claims, fill in
   designs and acceptance, regen the ledger export — all in main,
   before the worktree exists. The worktree has no live Dolt DB, so
   nothing written there reaches the ledger; ledger work done after
   the cut either vanishes with teardown or, worse, rides back as a
   stale tracked export. Cut only from settled ledger state.
2. Open the worktree on a round branch, under `./.tmp/` (gitignored,
   so scratch never rides along in a commit):
   `git worktree add ./.tmp/<round-name> -b round/<round-name>`.
   One worktree per round, never one per worker — workers share the
   worktree the way they would share the main tree. Cut only from a
   clean main tree — `git status --porcelain` empty — and record
   `git rev-parse HEAD` in the round note at the cut: main may keep
   moving under a second live session, and the pin is what lets the
   collect step tell round edits apart from main-side commits. The
   pin sees committed HEAD only, so a second session's uncommitted
   hotfix is invisible to it — a clean cut is what makes "no
   main-side change" actually true at the start.
3. Link the worktree once, as the orchestrator, before spawning.
   Run `./.tmp/<round-name>/scripts/harness link` from the main cwd
   and confirm it points at the worktree. Do this yourself instead of
   delegating a `link` step to every brief: one pinned link proves
   the tree before any worker starts, while per-worker links multiply
   the chances a worker runs the bare main-tree form and gates the
   wrong tree.
4. Brief workers with worktree paths. Every OWNED/FORBIDDEN path in
   every brief names the worktree copy, never the main-tree original.
   A brief that names a main-tree path invites a main-tree edit, and
   that edit is a publish through every live link.
5. Keep workers to worktree edits only, under the same parallel
   same-tree contract `orchestrate` already states. No `bd`
   commands, no commits, no gate, no reviewers from workers. The
   worktree holds no ledger database, so a worker ledger write is at
   best lost at teardown; keep all ledger writes in main, before the
   cut and after collect.
6. Gate and build the review packet in the worktree. Freeze the
   worktree, run `./.tmp/<round-name>/scripts/harness verify` there,
   run the `reviewer-taste` / `reviewer-correctness` pass (plus
   `reviewer-design` when anything on screen moved) against a packet
   built with `./.tmp/<round-name>/scripts/harness review`.
   Rebuild the packet before each revision round — a packet built
   before a revision describes a tree that no longer exists. State
   the limit plainly: this gate is ledger-blind. With no live Dolt
   DB in the worktree the ledger-export check skips, so this gate
   proves code, not the ledger lane. The main confirming gate in
   step 9 covers the ledger lane.
7. Adjudicate findings in the worktree. Revisions go back out as
   scoped implementer briefs against worktree paths, same as any
   round. Nothing moves toward main while a finding is still open.
8. Collect to main only after green gate plus clean reviews. Enumerate
   the worktree result first — `git -C ./.tmp/<round-name> status --short`
   plus `git -C ./.tmp/<round-name> diff --stat` — and collect from that
   enumeration, not from memory. Propagate each deletion explicitly
   into main (`git rm` the corresponding main path): a copy of
   created/modified paths alone leaves a worktree deletion live in the
   worktree and resurrected in main, and the copy never fails on the
   missing file so nothing flags it. Compare `git rev-parse HEAD`
   against the cut pin and re-check `git status --porcelain` in main
   before copying. On pin mismatch main moved mid-round via commits;
   on main-side dirt main moved mid-round without committing — a second
   session's uncommitted hotfix to the same path is overwritten by the
   blind copy with a green pin and no committed copy to recover from.
   Treat either as an abort the same way: reconcile the main-side
   change into the worktree result first (re-apply round edits atop it,
   never copy over it), then record the new `git rev-parse HEAD` as the
   pin before re-running the worktree gate and the review pass on the
   reconciled tree — without a fresh pin the retry compares the moved
   HEAD against the stale cut pin and aborts again, burning a full gate
   plus review per loop forever. When the abort came from main-side
   dirt rather than a pin mismatch, do not retry in a loop: the dirt is
   another session's uncommitted work, which you must neither commit nor
   stash, so retrying procures nothing — stop and coordinate with the
   owning session instead. Copy is
   blind — a merge would have conflicted on the same drift, but a
   copy silently reverts the other session's commit as an
   unexplained revert inside an unrelated bead commit, so the pin
   and status checks are what make the drift visible. Copy
   the worktree result into main deliberately, as the orchestrator,
   with the worktree frozen — this is the publish moment, so say
   plainly in the round note what was collected and when. When the
   round adds a shared skill, include the link-converged landings in
   the collect: re-run the main-tree link after copying if needed, and
   collect the resulting ignore lines plus the `.agents/skills/<name>`
   mirror link alongside the round files — the worktree link converged
   its own tree, but the main-tree landings exist in neither the
   worktree result nor any brief, so a copy from enumeration alone
   ships a tree the gate rejects. Collect the `.agents/skills/<name>`
   mirror only: it is the relative `../../.claude/skills/<name>` form
   tracked alongside its siblings. Never collect the root
   `.claude/skills/<name>` link — it is machine-absolute, gitignored
   regeneration output, and copying it plants a dangling absolute
   symlink in every other clone, so never `git add -f` it either. Copy only:
   nothing ever commits in the worktree, so the round branch tip
   still equals its base and a merge would be a silent no-op that
   could precede deleting the only copy of the edits. Never collect
   `.beads/` or any other ledger state — the worktree's tracked
   export went stale the moment main moved past the cut, and copying
   it back regresses main's ledger. Ledger writes happen in main
   before the cut and after collect, never from the worktree.
9. Run the confirming gate in main, then commit per bead. Run bare
   `scripts/harness verify` from the main cwd: this gate proves the
   copy landed cleanly, including the ledger lane the worktree gate
   could not check. It does not replace the worktree gate that
   already passed. One commit per bead, each naming its bead, per
   the `orchestrate` commit policy.
10. Close the ledger after the confirming gate and the code commits.
    Record bead notes, close each bead with its reason, regen the
    ledger export, commit that export, and run wrap-up plus
    ledger-push. The round is not done when the code lands; it is
    done when the ledger says what landed and the next session can
    find it.
11. Tear down last, after the close. Prove the copy first by
    diffing each collected path between `./.tmp/<round-name>/` and
    main, then run the final sweep before the remove:
    `git -C ./.tmp/<round-name> status --short` plus
    `git -C ./.tmp/<round-name> diff --stat`. This sweep must come
    back empty apart from entries already decided in the step-8
    enumeration — the collect-time enumeration is what gives each entry
    its fate (collect it, `git rm` its main counterpart, or record in
    the round note why it stays behind), and this sweep only catches
    what appeared after the freeze. Account for any straggler before running
    `git worktree remove --force ./.tmp/<round-name>` and
    `git branch -d round/<round-name>`. Collected-path diffs prove
    only what was collected; an untracked file a worker created but
    the orchestrator never collected appears in neither diff, and
    `--force` destroys it unrecoverably — nothing ever commits in
    the worktree by design, so there is no backup copy. The `--force`
    is required because a round that produced edits always leaves the
    worktree modified, which a bare remove refuses. Teardown moves
    only worktree metadata and the gitignored scratch dir, never
    tracked tree content, so it is not a tree move after the close.

## What not to do

- Do not invoke a bare `scripts/harness ...` and mean the worktree.
  Cwd never steers the finder; only the script path does. Spell the
  worktree form `./.tmp/<round-name>/scripts/harness ...` every time.
- Do not gate only in main and call the worktree a formality. The
  worktree gate is the one that holds the exposure window shut; the
  main gate only confirms the copy — and only the main gate sees the
  ledger lane.
- Do not let workers link, commit, gate, review, or collect. The
  orchestrator owns the link, the tree, the gate, the reviews, and
  every commit — in the worktree exactly as in main.
- Do not merge the round branch. With no worktree commits the tip
  equals its base, so a merge proves nothing and risks deleting the
  only copy of the edits. Copy the files instead.
- Do not collect `.beads/` or any ledger state from the worktree.
  Its export is stale from the cut onward; copying it back
  regresses main.
- Do not run ledger writes from the worktree. Claims, notes,
  closes, and export regens happen in main before the cut and after
  collect, never between.
- Do not tear down before proving the copy and closing the ledger.
  Diff first, close the beads and push the ledger, and only then
  remove with `--force` and delete the branch.
- Do not re-link the worktree back toward main mid-round to "fix" a
  resolution problem. A worktree whose links point at main is main
  with extra steps.
- Do not leave the worktree around "in case". Teardown is part of
  the round, not cleanup for later.
