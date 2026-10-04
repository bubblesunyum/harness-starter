#!/bin/bash
# Check that the committed beads export matches the live ledger. This is
# callable on its own so ledger probes do not need to run the rest of the gate.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ledger_export_check() {
  if ! command -v bd >/dev/null 2>&1 || [ ! -d .beads/embeddeddolt ]; then
    # No live ledger: bd missing, or a fresh clone carrying the committed
    # export without the gitignored Dolt working set behind it — the
    # directory-without-a-database shape add.sh warns about. Nothing to carry,
    # so nothing to prove, but said out loud.
    echo "  ok    ledger export: no live ledger, skipping"
    return 0
  fi
  local tmp bd_out
  tmp="$(mktemp)" || { echo "  FAIL  ledger export"; echo "        error: mktemp failed"; return 1; }
  if ! bd_out="$(bd export --include-memories -o "$tmp" 2>&1)"; then
    echo "  FAIL  ledger export"
    if [ -n "$bd_out" ]; then
      printf '%s\n' "$bd_out" | head -5 | sed -e 's/^/        /'
    fi
    echo "        run it yourself for the whole error:"
    echo "        bd export --include-memories -o .beads/issues.jsonl"
    rm -f "$tmp"
    return 1
  fi
  if [ ! -f .beads/issues.jsonl ]; then
    if [ -s "$tmp" ]; then
      echo "  FAIL  ledger export"
      echo "        error: the ledger has beads but no committed export — nothing reaches a fresh clone:"
      echo "        bd export --include-memories -o .beads/issues.jsonl"
      rm -f "$tmp"
      return 1
    fi
    rm -f "$tmp"
    echo "  ok    ledger export: ledger empty, nothing to carry"
    return 0
  fi
  # Present is not enough — the export only reaches a fresh clone when it is
  # tracked. An untracked file matches content yet carries nothing, and every
  # session then rediscovers the `??` in git status (har-l5a).
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git check-ignore -q .beads/issues.jsonl 2>/dev/null; then
      echo "  FAIL  ledger export"
      echo "        error: .beads/issues.jsonl is gitignored — nothing reaches a fresh clone:"
      echo "        un-ignore it, then git add .beads/issues.jsonl"
      rm -f "$tmp"
      return 1
    fi
    if ! git ls-files --error-unmatch .beads/issues.jsonl >/dev/null 2>&1; then
      echo "  FAIL  ledger export"
      echo "        error: .beads/issues.jsonl exists but is untracked — nothing reaches a fresh clone:"
      echo "        git add .beads/issues.jsonl"
      rm -f "$tmp"
      return 1
    fi
  fi
  if ! python3 - "$tmp" .beads/issues.jsonl <<'PYEOF'; then
import re, sys
export_path, committed_path = sys.argv[1], sys.argv[2]
def lines(path):
    with open(path, errors="replace") as f:
        return {l.rstrip("\n") for l in f if l.rstrip("\n")}
fresh, committed = lines(export_path), lines(committed_path)
def label(line):
    m = re.search(r'"id"\s*:\s*"([^"]+)"', line)
    if m:
        return m.group(1)
    m = re.search(r'"key"\s*:\s*"([^"]+)"', line)
    if m:
        return "memory:%s" % m.group(1)
    return line[:60]
missing = sorted(fresh - committed)
gone = sorted(committed - fresh)
if not (missing or gone):
    sys.exit(0)
print("  FAIL  ledger export")
# har-dp5: bd's pre-commit hook rewrites the file as a plain issues-only
# export when export.auto=true and .beads paths are staged, dropping every
# memory from the working copy. A stale file is usually missing a bead or
# two; a file holding zero memories while the ledger has them is that hook.
fresh_mem = {l for l in fresh if re.search(r'"_type"\s*:\s*"memory"', l)}
committed_mem = {l for l in committed if re.search(r'"_type"\s*:\s*"memory"', l)}
if fresh_mem and not committed_mem:
    print("        note: the ledger holds %d memories and the file holds none —" % len(fresh_mem))
    print("        that is the shape of bd's pre-commit plain rewrite, not ordinary drift.")
    print("        regen with --include-memories, and consider export.auto=false,")
    print("        which disarms the hook's export (proven on bd 1.1.2).")
if missing:
    print("        error: %d line(s) not in the committed export — created or updated since:" % len(missing))
    for l in missing[:8]:
        print("        - %s" % label(l))
    if len(missing) > 8:
        print("        …and %d more" % (len(missing) - 8))
if gone:
    print("        error: %d line(s) still in the committed export — deleted or updated since:" % len(gone))
    for l in gone[:8]:
        print("        - %s" % label(l))
    if len(gone) > 8:
        print("        …and %d more" % (len(gone) - 8))
print("        regen it before committing:")
print("        bd export --include-memories -o .beads/issues.jsonl")
sys.exit(1)
PYEOF
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  echo "  ok    ledger export matches the committed file"
  return 0
}


ledger_export_check
