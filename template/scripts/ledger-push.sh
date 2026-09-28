#!/bin/bash
# push the ledger to git, so the beads outlive this machine
#
#   scripts/ledger-push.sh          # push now
#   scripts/ledger-push.sh --check  # one line when a push is needed, silence otherwise
#
# --check is what the brief and the gate run: a session cannot end with an
# unpushed ledger without being told, and pushing on its behalf stays opt-in.
# It never fails and never touches the network — it compares against the
# last-known remote tracking, which always shows an unpushed local ledger (the
# failure this exists for). A remote that moved elsewhere is caught on fetch.
# The issue graph lives in .beads/embeddeddolt/, which is gitignored — a normal
# `git push` carries no part of it. bd keeps it on its own ref on the same
# remote (refs/dolt/data), and that ref moves only when something runs
# `bd dolt push`. Nothing does automatically. That is why this script exists and
# why the handoff procedure calls it: an unpushed ledger is one dead laptop away
# from every close reason, every dependency and every memory being gone, and it
# looks perfectly healthy right up until it isn't.
set -euo pipefail

# The Dolt data directory holding this repo's ledger, or nothing when there is
# no ledger here to push.
ledger_datadir() {
  for d in "$PWD/.beads/embeddeddolt/"*/.dolt; do
    [ -d "$d" ] && { printf '%s\n' "$(dirname "$d")"; return 0; }
  done
  return 1
}

ledger_check() {
  cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || return 0
  command -v bd >/dev/null 2>&1 || return 0
  [ -d .beads/embeddeddolt ] || return 0
  if ! bd dolt remote list 2>/dev/null | grep -q '^origin'; then
    if [ -z "$(git remote get-url origin 2>/dev/null)" ]; then
      echo "push the ledger: no git origin, so no Dolt remote — the beads have never left this machine. Once the repo has an origin, wire it (bd dolt remote add origin git+<the origin URL>), then run scripts/ledger-push.sh."
    else
      echo "push the ledger: no Dolt remote — the beads have never left this machine. Wire it to the repo's origin (bd dolt remote add origin git+<the origin URL>), then run scripts/ledger-push.sh."
    fi
    return 0
  fi
  # Ahead needs the dolt CLI; bd alone cannot say it. Quiet without it rather
  # than wrong — the no-remote line above is the one that must always fire.
  command -v dolt >/dev/null 2>&1 || return 0
  dir="$(ledger_datadir)" || return 0
  if ! dolt --data-dir "$dir" status 2>/dev/null | grep -q "nothing to commit, working tree clean"; then
    echo "push the ledger: uncommitted bead changes — run bd dolt commit, then scripts/ledger-push.sh."
  fi
  branch="$(dolt --data-dir "$dir" branch 2>/dev/null | awk '/^\*/ { print $2 }')"
  [ -n "${branch:-}" ] || return 0
  # Exact match on the last field: a substring test calls origin/main present
  # when only origin/main2 exists, and the ledger that was never pushed reads
  # as silent — the one outcome this check exists to prevent.
  if ! dolt --data-dir "$dir" branch -a 2>/dev/null | awk '{ print $NF }' | grep -q -x -F "remotes/origin/$branch"; then
    echo "push the ledger: never pushed to origin — the beads are still only on this machine. Run scripts/ledger-push.sh."
    return 0
  fi
  ahead="$(dolt --data-dir "$dir" log "origin/$branch..$branch" --oneline 2>/dev/null | wc -l | tr -d ' ')"
  if [ -n "$ahead" ] && [ "$ahead" -gt 0 ] 2>/dev/null; then
    echo "push the ledger: $ahead commit(s) ahead of origin — run scripts/ledger-push.sh."
  fi
}

if [ "${1:-}" = "--check" ]; then
  # Never fails: the brief and the gate print whatever comes back, and neither
  # may change its own verdict over a ledger it couldn't read.
  ledger_check || true
  exit 0
fi

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

# The git-committed copy: .beads/issues.jsonl is what a fresh clone hydrates
# from, and a plain `bd export` omits memories — the store the harness tells
# every project to keep its knowledge in. Regenerate with them, so both
# transports carry the whole ledger. A regen failure warns and continues: the
# Dolt ref above is the primary transport, and a stale JSONL must never block
# it — the gate's export probe keeps the staleness visible instead.
if ! bd export --include-memories -o .beads/issues.jsonl >/dev/null 2>&1; then
  echo "  ! ledger export failed — .beads/issues.jsonl stays stale; continuing to the Dolt push, which still carries everything." >&2
fi

if push_out="$(bd dolt push 2>&1)"; then
  echo "✓ ledger pushed"
else
  echo "$push_out" >&2
  echo "✗ the ledger did not reach git — the beads are still only on this machine." >&2
  exit 1
fi
