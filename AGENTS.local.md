# Project additions to the harness contract

Read this alongside `AGENTS.md` and `CLAUDE.md`. Add guidance specific to this
project here, such as which verification lane to run before a release.
The harness installs this file once and never compares or overwrites it.

## Wrap-up: run the script, don't hand-order the steps

`scripts/h wrap-up` closes out work in the one order that stays clean —
ledger writes, push, export, verify, commit — because every `bd` write after
the export (including `bd close`) re-dirties it, and the gate's first check
then fails and forces a second full run:

  scripts/h wrap-up -m "lowercase terse message" --bead <id> \
    [--close <id> --reason "..."] [--note <id> "..."] [--remember "..."] \
    [--quick|--full] [--no-push] [--note-file harness/handoffs/<ts>.md]

Every bead commit carries a fresh `.beads/issues.jsonl` (`--bead` feeds the
commit hook; closed ids resolve). The push is best-effort, never blocking: on
failure it warns and commits anyway, and `--check` keeps nagging until a later
push lands. A failed gate aborts before any commit — reopen, fix, rerun.
Ledger-only changes after a green gate need just the export check
(`scripts/h verify --quick` runs it first), not a full re-gate.

## Working on the starter

This checkout runs the harness exactly as every project does — by reference —
except that `scripts/h` resolves its own `template/` first. So there are no
root copies to keep in step: edit `template/`, and the next `scripts/h <cmd>`
here, and in every project on this machine, runs the edit. That is also the
risk: a half-finished edit to `template/` is live everywhere at once, so keep
`template/` working between commits, and check `git status template/` after
any tool runs in a linked project — a write through a link lands here.

The root keeps only what is the starter's own: `CLAUDE.md`, this file, the
reviewer overlays in `harness/reviewers/`, `scripts/verify.steps.sh` and
`scripts/review.scope.sh`, the starter-only probes in `scripts/test-*`, and
the one dashboard's hooks in `.claude/settings.json` — the board for every
project runs from here.

- **Review scope** (`scripts/review.scope.sh`) carries `bin/*` and
  `commands/*` by path, and `*.html` for the dashboard page: the two most
  important files here have no extension, and a suffix-only scope left the
  dispatcher unreviewable long enough for it to keep a path-traversal bug
  through a full pass — then did the same to the dashboard page, the largest
  file in the project.
- **The gate** is what a compiler would have caught: every shell and Python
  file parses, the CLI lists its own commands, and probe installs into
  throwaway repos prove what lands in someone else's project — stubs, seeds,
  links, the finder's every resolution branch, stack guidance only where the
  stack is used, and that no install writes back into `template/`. Those
  failures only ever show up at the far end, long after anyone would connect
  them to the change that caused them.
