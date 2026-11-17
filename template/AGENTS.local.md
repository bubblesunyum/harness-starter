# Project additions to the harness contract

Read this alongside `AGENTS.md` and `CLAUDE.md`. Add guidance specific to this
project here, such as which verification lane to run before a release.
The harness installs this file once and never compares or overwrites it.

## Wrap-up: run the script, don't hand-order the steps

`scripts/harness wrap-up` closes out work — ledger writes, push, export, verify,
commit. The pre-commit hook stages a fresh `.beads/issues.jsonl` on every
commit, so the committed export stays fresh whatever moved the ledger; the
manual export is the fast path and the gate's first check the backstop:

  scripts/harness wrap-up -m "lowercase terse message" --bead <id> \
    [--close <id> --reason "..."] [--note <id> "..."] [--remember "..."] \
    [--quick|--full] [--no-push] [--note-file harness/handoffs/<ts>.md]

Every bead commit carries a fresh `.beads/issues.jsonl` (`--bead` feeds the
commit hook; closed ids resolve). The push is best-effort, never blocking: on
failure it warns and commits anyway, and `--check` keeps nagging until a later
push lands. A failed gate aborts before any commit — reopen, fix, rerun.
Ledger-only changes after a green gate need just `scripts/harness ledger-export-check`,
not a full re-gate.
