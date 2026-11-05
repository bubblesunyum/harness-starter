# Project additions to the harness contract

Read this alongside `AGENTS.md` and `CLAUDE.md`. Add guidance specific to this
project here, such as which verification lane to run before a release.
The harness installs this file once and never compares or overwrites it.

## Wrap-up: run the script, don't hand-order the steps

`scripts/wrap-up.sh` closes out work in the one order that stays clean —
ledger writes, push, export, verify, commit — because every `bd` write after
the export (including `bd close`) re-dirties it, and the gate's first check
then fails and forces a second full run:

  scripts/wrap-up.sh -m "lowercase terse message" --bead <id> \
    [--close <id> --reason "..."] [--note <id> "..."] [--remember "..."] \
    [--quick|--full] [--no-push] [--note-file harness/handoffs/<ts>.md]

Every bead commit carries a fresh `.beads/issues.jsonl` (`--bead` feeds the
commit hook; closed ids resolve). The push is best-effort, never blocking: on
failure it warns and commits anyway, and `--check` keeps nagging until a later
push lands. A failed gate aborts before any commit — reopen, fix, rerun.
Ledger-only changes after a green gate need just `scripts/ledger-export-check.sh`,
not a full re-gate.
