#!/bin/bash
# Proves the contract split: seeds own the fill-in answers, the staleness gate
# watches shared docs from the harness checkout, and an installed copy behaves
# exactly as today. Starter-only: every shape below copies template/ into
# throwaway dirs, never the live tree, so parallel edits can't flake it.
#
# One ok/FAIL line per assertion; any FAIL exits nonzero. bash 3.2 clean.
# Usage: bash scripts/test-contract-split.sh
#
# One function per case below; shared fixtures stay at the top level.

here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$here/commands/lib/install.sh"

fail=0
fixtures=""
trap '[ -n "$fixtures" ] && rm -rf $fixtures' EXIT

# mktemp into a global: command substitution would run the append in a
# subshell and the EXIT trap would reap nothing.
fresh_dir() {
  _fresh="$(mktemp -d)" || { echo "FAIL setup: mktemp failed"; exit 1; }
  fixtures="$fixtures $_fresh"
}

# The box-rule marker, built from escapes rather than spelled out: a literal
# here would read as a fill-in block to any scan of this file.
box="$(printf '\342\224\200\342\224\200 FILL THIS IN')"

pass() { echo "ok - $1"; }
oops() { echo "FAIL - $1"; fail=1; }

# (a) Only seeds may carry a fill-in block. The seed list is the one in
# install.sh — derived by calling it, never duplicated here.
case_seeds_only() {
  carriers=0
  bad=""
  while IFS= read -r rel; do
    f="$here/$rel"
    [ -f "$f" ] || continue
    if grep -qIF -- "$box" "$f" 2>/dev/null; then
      carriers=$((carriers + 1))
      harness_is_seed "${rel#template/}" || bad="$bad $rel"
    fi
  done <<< "$(git -C "$here" ls-files --cached --others --exclude-standard -- template | sort)"
  if [ -n "$bad" ]; then
    oops "fill-in block outside the seed list:$bad"
  else
    pass "fill-in blocks live only in seeds ($carriers files carry one, all seeds)"
  fi
}

# (b) Starter shape: a template copy as HARNESS, its parent as ROOT.
case_starter_shape() {
  fresh_dir; root_b="$_fresh"
  fresh_dir; home_b="$_fresh"
  harness_b="$root_b/template"
  mkdir -p "$harness_b" || { oops "starter shape: cannot make the fixture"; exit 1; }
  cp -R "$here/template/." "$harness_b/" || { echo "FAIL setup: cannot copy template"; exit 1; }
  if ! HOME="$home_b" HARNESS_ROOT="$harness_b" HARNESS_PROJECT="$root_b" \
      python3 "$harness_b/scripts/context.py" bless >/dev/null 2>&1; then
    oops "starter shape: bless failed"
    return
  fi
  if [ ! -f "$harness_b/.claude/context.lock" ]; then
    oops "starter shape: bless wrote no harness lock"
    return
  fi
  out_b="$(HOME="$home_b" HARNESS_ROOT="$harness_b" HARNESS_PROJECT="$root_b" \
    python3 "$harness_b/scripts/context.py" check 2>&1)"
  rc_b=$?
  if [ "$rc_b" -ne 0 ]; then
    oops "starter shape: blessed check exits $rc_b, want 0"
  elif ! printf '%s' "$out_b" | grep -q "^  ok "; then
    oops "starter shape: blessed check never said ok"
  else
    pass "starter shape: blessed check passes"
  fi
  # A file named by a shared doc's tracks:, read off the lock itself.
  src_b="$(python3 - "$harness_b/.claude/context.lock" <<'PYEOF'
import json, sys
entry = json.load(open(sys.argv[1])).get(".claude/HARNESS.md", {})
cands = sorted(k for k in entry if k != "doc")
print(cands[0] if cands else "")
PYEOF
)"
  if [ -z "$src_b" ] || [ ! -f "$harness_b/$src_b" ]; then
    oops "starter shape: the lock names no tracked shared source"
    return
  fi
  mv "$harness_b/$src_b" "$harness_b/$src_b.probe-moved" || {
    echo "FAIL setup: cannot move $src_b"; exit 1; }
  out_b2="$(HOME="$home_b" HARNESS_ROOT="$harness_b" HARNESS_PROJECT="$root_b" \
    python3 "$harness_b/scripts/context.py" check 2>&1)"
  rc_b2=$?
  if [ "$rc_b2" -eq 0 ]; then
    oops "starter shape: moving $src_b still passes"
  elif ! printf '%s' "$out_b2" | grep -q "STALE"; then
    oops "starter shape: moving $src_b fails without a STALE line"
  else
    pass "starter shape: moving a tracked shared source ($src_b) fails check"
  fi
}

# (c) Reference shape: ROOT a separate project dir, shared lock stale.
case_reference_shape() {
  fresh_dir; harness_c="$_fresh"
  fresh_dir; proj_c="$_fresh"
  fresh_dir; home_c="$_fresh"
  mkdir -p "$harness_c" "$proj_c" || { echo "FAIL setup: cannot make fixtures"; exit 1; }
  cp -R "$here/template/." "$harness_c/" || { echo "FAIL setup: cannot copy template"; exit 1; }
  HOME="$home_c" HARNESS_ROOT="$harness_c" HARNESS_PROJECT="$harness_c" \
    python3 "$harness_c/scripts/context.py" bless >/dev/null 2>&1 || {
    echo "FAIL setup: reference fixture bless failed"; exit 1; }
  mv "$harness_c/scripts/verify.sh" "$harness_c/scripts/verify.sh.probe-moved" || {
    echo "FAIL setup: cannot stale the fixture"; exit 1; }
  # The lock really is stale: as an installed copy this fixture must now fail.
  if HOME="$home_c" HARNESS_ROOT="$harness_c" HARNESS_PROJECT="$harness_c" \
      python3 "$harness_c/scripts/context.py" check >/dev/null 2>&1; then
    oops "reference shape: stale fixture passes as an installed copy"
    return
  fi
  out_c="$(HOME="$home_c" HARNESS_ROOT="$harness_c" HARNESS_PROJECT="$proj_c" \
    python3 "$harness_c/scripts/context.py" check 2>&1)"
  rc_c=$?
  if [ "$rc_c" -ne 0 ]; then
    oops "reference shape: stale shared lock fails a by-reference check"
  elif ! printf '%s' "$out_c" | grep -q "shared docs skipped"; then
    oops "reference shape: check passes but never says it skipped shared docs"
  else
    pass "reference shape: stale shared lock passes with a skip line"
  fi
}

# (d) Plain copy, no env: lock path and content, and check output, match today.
case_plain_copy() {
  fresh_dir; plain_d="$_fresh"
  fresh_dir; home_d="$_fresh"
  mkdir -p "$plain_d" || { echo "FAIL setup: cannot make the fixture"; exit 1; }
  cp -R "$here/template/." "$plain_d/" || { echo "FAIL setup: cannot copy template"; exit 1; }
  # Installed copies always carry CLAUDE.md (harness add writes the stock text);
  # the template ships none because the starter's own lives at the root.
  printf '# probe project\n' > "$plain_d/CLAUDE.md" || { echo "FAIL setup: cannot plant CLAUDE.md"; exit 1; }
  # The baseline is the last context.py before the project/shared split
  # (har-b5n8.3), pinned by commit: HEAD stopped being "before" the moment the
  # split was committed. A shallow clone lacks it, so say that rather than guess.
  PRE_SPLIT=34e0a13
  git -C "$here" show "$PRE_SPLIT:template/scripts/context.py" > "$plain_d/scripts/context-old.py" 2>/dev/null || {
    echo "FAIL setup: cannot read context.py at $PRE_SPLIT — this probe needs full history (git fetch --unshallow)"; exit 1; }
  # Checks run from inside the fixture: from the starter's cwd the check's
  # ledger-push probe asks the starter's own ledger about its remote.
  old_bless="$(HOME="$home_d" python3 "$plain_d/scripts/context-old.py" bless 2>&1)" || {
    echo "FAIL setup: today's bless failed"; exit 1; }
  old_out="$(cd "$plain_d" && HOME="$home_d" python3 "$plain_d/scripts/context-old.py" check 2>&1)"
  old_rc=$?
  cp "$plain_d/.claude/context.lock" "$plain_d/.claude/context.lock.old-probe" || {
    echo "FAIL setup: cannot snapshot the old lock"; exit 1; }
  # Docs deliberately deleted since the baseline legitimately shrink the
  # lock: filter them from the old snapshot and its bless count before
  # comparing, so only unexpected drift fails. The lock is JSON written
  # with sort_keys, so filtering must drop the whole entry, not the line.
  for gone in .claude/skills/delegate/SKILL.md; do
    if grep -qF "$gone" "$plain_d/.claude/context.lock.old-probe"; then
      python3 -c 'import json,sys; p,g=sys.argv[1],sys.argv[2]; l=json.load(open(p)); l.pop(g,None); open(p,"w").write(json.dumps(l,indent=2,sort_keys=True)+"\n")' \
        "$plain_d/.claude/context.lock.old-probe" "$gone" || {
        echo "FAIL setup: cannot filter $gone from the old lock"; exit 1; }
      n="$(printf '%s' "$old_bless" | sed -n 's/.*blessed \([0-9][0-9]*\) docs.*/\1/p')"
      old_bless="$(printf '%s' "$old_bless" | sed "s/blessed $n docs/blessed $((n - 1)) docs/")"
    fi
  done
  rm "$plain_d/.claude/context.lock" || { echo "FAIL setup: cannot clear the lock"; exit 1; }
  new_bless="$(HOME="$home_d" python3 "$plain_d/scripts/context.py" bless 2>&1)" || {
    echo "FAIL setup: new bless failed"; exit 1; }
  if [ "$old_bless" != "$new_bless" ]; then
    oops "plain copy: bless reports '$new_bless', today said '$old_bless'"
  elif ! cmp -s "$plain_d/.claude/context.lock.old-probe" "$plain_d/.claude/context.lock"; then
    oops "plain copy: lock content differs from today's"
  else
    pass "plain copy: lock path and content match the old script"
  fi
  new_out="$(cd "$plain_d" && HOME="$home_d" python3 "$plain_d/scripts/context.py" check 2>&1)"
  new_rc=$?
  if [ "$old_rc" -ne "$new_rc" ]; then
    oops "plain copy: check exits $new_rc, today exited $old_rc"
    return
  fi
  if ! printf '%s' "$old_out" | grep -v "^  ok " | diff - <(printf '%s' "$new_out" | grep -v "^  ok ") >/dev/null; then
    oops "plain copy: check output differs from today's outside the ok-count line"
    return
  fi
  # The ok-count line grows by construction: the brief puts AGENTS.local.md
  # and tracks-carrying agents in the doc lists, so prove it grew by exactly
  # that, and nothing else.
  old_n="$(printf '%s' "$old_out" | sed -n 's/^  ok    \([0-9]*\) docs.*/\1/p')"
  new_n="$(printf '%s' "$new_out" | sed -n 's/^  ok    \([0-9]*\) docs.*/\1/p')"
  want_growth=0
  [ -f "$plain_d/AGENTS.local.md" ] && want_growth=$((want_growth + 1))
  want_growth=$((want_growth + $(grep -l "tracks:" "$plain_d"/.claude/agents/*.md 2>/dev/null | grep -c . || true)))
  if [ -z "$old_n" ] || [ -z "$new_n" ]; then
    oops "plain copy: no ok-count line to compare"
  elif [ "$new_n" -ne "$((old_n + want_growth))" ]; then
    oops "plain copy: ok count $new_n, want $old_n + $want_growth for the wider lists"
  else
    pass "plain copy: check output matches today's (ok $old_n -> $new_n for the wider lists)"
  fi
}

case_seeds_only
case_starter_shape
case_reference_shape
case_plain_copy

[ "$fail" -eq 0 ] || exit 1
