#!/bin/bash
# push the ledger to git, so the beads outlive this machine
#
#   scripts/ledger-push.sh
#
# The issue graph lives in .beads/embeddeddolt/, which is gitignored — a normal
# `git push` carries no part of it. bd keeps it on its own ref on the same
# remote (refs/dolt/data), and that ref moves only when something runs
# `bd dolt push`. Nothing does automatically. That is why this script exists and
# why the handoff procedure calls it: an unpushed ledger is one dead laptop away
# from every close reason, every dependency and every memory being gone, and it
# looks perfectly healthy right up until it isn't.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

command -v bd >/dev/null 2>&1 || {
  echo "✗ bd is not installed — there is no ledger to push." >&2
  exit 1
}

# Checked before pushing rather than letting `bd dolt push` fail, because its
# own message for this case names a remote that isn't configured, which reads
# like a network problem and sends you looking in the wrong place.
if ! bd dolt remote list 2>/dev/null | grep -q '^origin'; then
  echo "✗ no Dolt remote — the ledger has never left this machine." >&2
  echo "  Wire it to the repo's own origin, then re-run:" >&2
  echo "      bd dolt remote add origin git+\$(git remote get-url origin)" >&2
  echo "  'harness add' does this at install time; a ledger that predates that" >&2
  echo "  step, or a repo whose origin arrived later, needs it once by hand." >&2
  exit 1
fi

# Auto-commit is on for normal writes, so this is usually a no-op and says
# "Nothing to commit." Run anyway: the batch auto-commit policy defers commits,
# and under it an uncommitted working set pushes as an empty change silently.
bd dolt commit -m "ledger" >/dev/null 2>&1 || true

if push_out="$(bd dolt push 2>&1)"; then
  echo "✓ ledger pushed"
else
  echo "$push_out" >&2
  echo "✗ the ledger did not reach git — the beads are still only on this machine." >&2
  exit 1
fi
