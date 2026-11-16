#!/bin/bash
# Probe for the scripts/h finder: resolution order, fetching, dispatch,
# shadowing, linking, session, hooks, and every loud failure.
#
# Self-contained: a fake starter checkout (this tree's template/, so it
# carries the marker), a file:// repo of it, and fake projects all live
# under mktemp -d, and HOME points at a temp dir so the real ~/.harness is
# never consulted. One `ok <case>` / `FAIL <case>: why` line per case;
# exits non-zero when any case fails.
#
# Bash 3.2 only: no associative arrays, no mapfile, no `local -n`. Nothing
# after the EXIT trap uses command substitution — a captured $(...) runs the
# trap in its own subshell and would reap the fixtures mid-run — so results
# go through files, `test`, and grep instead.
#
# One function per case below; shared fixtures stay at the top level.

REPO="$(cd "$(dirname "$0")" && cd .. && pwd -P)"
TMP="$(mktemp -d)" || { echo "FAIL setup: mktemp failed"; exit 1; }
# Physical path: mktemp may return a symlinked prefix (/var -> /private/var
# on macOS) while the finder resolves PROJECT with pwd -P.
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" || { echo "FAIL setup: cannot make fake HOME"; exit 1; }

FAILS=0
pass() { printf 'ok %s\n' "$1"; }
failcase() { FAILS=$((FAILS + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

# --- fixtures ---

# A fake project: scripts/h copied from this tree. Sets $PROJ (no output —
# callers never capture, so the EXIT trap stays in this shell).
newproj() {
  PROJ="$TMP/$1"
  mkdir -p "$PROJ/scripts" || return 1
  cp "$REPO/template/scripts/h" "$PROJ/scripts/h" || return 1
  chmod +x "$PROJ/scripts/h" || return 1
}

CHECKOUT="$TMP/checkout"
BARE="$TMP/starter.git"
mkdir -p "$CHECKOUT" || { echo "FAIL setup: mkdir checkout"; exit 1; }
cp -R "$REPO/template" "$CHECKOUT/template" || { echo "FAIL setup: copy template"; exit 1; }
# A stub ROOT brief.sh, so the ROOT half of dispatch never depends on the
# real shared scripts (another worker owns those right now). It understands
# the flags `h session` passes — --prepend (the contract), --append (the
# fresh-link skill note), --hook (one SessionStart JSON object) — and stays
# silent on stderr like a dispatched copy must.
cat > "$CHECKOUT/template/scripts/brief.sh" <<'STUB' || { echo "FAIL setup: stub brief"; exit 1; }
#!/bin/bash
# Mini-brief for finder probes: no bd, no ledger, just the contract in, the
# note on the end, and the same JSON shape with --hook.
hook=0
prepend=""
append=""
while [ $# -gt 0 ]; do
  case "$1" in
    --hook) hook=1; shift ;;
    --prepend)
      if [ -z "${2:-}" ]; then
        echo "brief.sh: --prepend needs a file" >&2
        exit 2
      fi
      prepend="$2"; shift 2 ;;
    --append)
      if [ -z "${2:-}" ]; then
        echo "brief.sh: --append needs a file" >&2
        exit 2
      fi
      append="$2"; shift 2 ;;
    *) break ;;
  esac
done
text=""
if [ -n "$prepend" ] && [ -f "$prepend" ]; then
  text="$(cat "$prepend")"
fi
if [ -n "$text" ]; then
  text="$text
ROOT-BRIEF ${HARNESS_PROJECT}"
else
  text="ROOT-BRIEF ${HARNESS_PROJECT}"
fi
if [ -n "$append" ] && [ -f "$append" ]; then
  text="$text
$(cat "$append")"
fi
if [ "$hook" -eq 1 ]; then
  python3 -c 'import json, sys; print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": sys.stdin.read().strip()}}))' <<< "$text"
else
  echo "$text"
fi
STUB
chmod +x "$CHECKOUT/template/scripts/brief.sh" || { echo "FAIL setup: chmod stub"; exit 1; }
# A probe entry under .agents/skills, so the link's third path is exercised.
mkdir -p "$CHECKOUT/template/.agents/skills/probe" || { echo "FAIL setup: agents fixture"; exit 1; }
printf 'probe\n' > "$CHECKOUT/template/.agents/skills/probe/SKILL.md" || { echo "FAIL setup: agents file"; exit 1; }
# A probe hook and a generated-agent entry, so `h hook` and the
# .opencode/agent half of `h link` have something to run against.
mkdir -p "$CHECKOUT/template/scripts/hooks" || { echo "FAIL setup: hooks fixture"; exit 1; }
printf '#!/bin/bash\necho "PROBE-HOOK $*"\n' > "$CHECKOUT/template/scripts/hooks/probe-hook" || { echo "FAIL setup: hook file"; exit 1; }
chmod +x "$CHECKOUT/template/scripts/hooks/probe-hook" || { echo "FAIL setup: chmod hook"; exit 1; }
mkdir -p "$CHECKOUT/template/.opencode/agent" || { echo "FAIL setup: opencode fixture"; exit 1; }
printf 'probe agent\n' > "$CHECKOUT/template/.opencode/agent/probe-agent.md" || { echo "FAIL setup: opencode file"; exit 1; }
# Probe stack guidance, so the stacks half of `h link` has stable names
# whatever the starter ships: probe (listed) and probe-extra (unlisted).
mkdir -p "$CHECKOUT/template/harness/stacks" || { echo "FAIL setup: stacks fixture"; exit 1; }
printf '# probe stack\n' > "$CHECKOUT/template/harness/stacks/probe.md" || { echo "FAIL setup: stacks file"; exit 1; }
printf '# probe extra stack\n' > "$CHECKOUT/template/harness/stacks/probe-extra.md" || { echo "FAIL setup: stacks extra"; exit 1; }
# One extra dispatch command only the shared finder knows: the hand-off case
# below proves the project's committed finder reached it.
python3 - "$CHECKOUT/template/scripts/h" <<'PYEOF' || { echo "FAIL setup: probe-only patch"; exit 1; }
import sys
path = sys.argv[1]
text = open(path).read()
old = '    opencode-pin) file="opencode-pin.py" ;;'
assert text.count(old) == 1, "shared finder dispatch shape changed"
open(path, "w").write(text.replace(old, old + '\n    probe-only) file="probe-only.sh" ;;'))
PYEOF
cat > "$CHECKOUT/template/scripts/probe-only.sh" <<'STUB' || { echo "FAIL setup: probe-only script"; exit 1; }
#!/bin/bash
# Probe-only dispatch for the hand-off case: only the shared finder knows this
# command, so its marker proves the project's committed finder handed over —
# and no HARNESS_FINDER_* variable may leak into it or its children.
echo "PROBE-HANDOVER-MARKER"
leaked="$(env | grep '^HARNESS_FINDER_' || true)"
if [ -n "$leaked" ]; then
  echo "LEAKED into the dispatched command: $leaked"
  exit 1
fi
if bash -c 'env' | grep -q '^HARNESS_FINDER_'; then
  echo "LEAKED into a child of the dispatched command"
  exit 1
fi
STUB
chmod +x "$CHECKOUT/template/scripts/probe-only.sh" || { echo "FAIL setup: chmod probe-only"; exit 1; }
(cd "$CHECKOUT" && git init -q .) >/dev/null || { echo "FAIL setup: git init"; exit 1; }
(cd "$CHECKOUT" && git add -A) >/dev/null || { echo "FAIL setup: git add"; exit 1; }
(cd "$CHECKOUT" && git -c user.email=probe@t -c user.name=probe -c commit.gpgsign=false commit -qm probe) >/dev/null || { echo "FAIL setup: git commit"; exit 1; }
git clone -q --bare "$CHECKOUT" "$BARE" >/dev/null || { echo "FAIL setup: bare clone"; exit 1; }
URL="file://$BARE"
DEAD="file://$TMP/no-such-repo"

# --- one function per case ---

case_harness_home_wins() {
  newproj p1 || { echo "FAIL setup: p1"; exit 1; }
  if ! HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" root >"$TMP/got" 2>"$TMP/err"; then
    failcase "env HARNESS_HOME resolves" "non-zero exit"
    return
  fi
  printf '%s\n' "$CHECKOUT/template" > "$TMP/want"
  if cmp -s "$TMP/want" "$TMP/got" && [ ! -s "$TMP/err" ]; then
    pass "env HARNESS_HOME resolves"
  else
    failcase "env HARNESS_HOME resolves" "wrong root on stdout or stderr noisy"
  fi
}

case_home_no_clone() {
  ln -s "$CHECKOUT" "$HOME/.harness" || { echo "FAIL setup: home link"; exit 1; }
  newproj p2 || { echo "FAIL setup: p2"; exit 1; }
  if ! env -u HARNESS_HOME HARNESS_URL="$DEAD" "$PROJ/scripts/h" root >"$TMP/got" 2>"$TMP/err"; then
    failcase "home resolves without cloning" "non-zero exit"
    rm -f "$HOME/.harness"
    return
  fi
  printf '%s\n' "$CHECKOUT/template" > "$TMP/want"
  if ! cmp -s "$TMP/want" "$TMP/got" || [ -s "$TMP/err" ]; then
    failcase "home resolves without cloning" "wrong root on stdout or stderr noisy"
    rm -f "$HOME/.harness"
    return
  fi
  if [ -e "$PROJ/.harness" ]; then
    failcase "home resolves without cloning" ".harness appeared in the project"
  else
    pass "home resolves without cloning"
  fi
  rm -f "$HOME/.harness"
}

case_fetch_reuse() {
  newproj p3 || { echo "FAIL setup: p3"; exit 1; }
  if ! env -u HARNESS_HOME HARNESS_URL="$URL" "$PROJ/scripts/h" root >"$TMP/got" 2>"$TMP/err"; then
    failcase "fetch clones once and reuses" "non-zero exit"
    return
  fi
  printf '%s\n' "$PROJ/.harness/template" > "$TMP/want"
  if ! cmp -s "$TMP/want" "$TMP/got"; then
    failcase "fetch clones once and reuses" "wrong root on stdout"
    return
  fi
  if ! grep -qxF '.harness/' "$PROJ/.gitignore" 2>/dev/null; then
    failcase "fetch clones once and reuses" ".gitignore lacks .harness/"
    return
  fi
  if ! env -u HARNESS_HOME HARNESS_URL="$DEAD" "$PROJ/scripts/h" root >"$TMP/got2" 2>"$TMP/err"; then
    failcase "fetch clones once and reuses" "second run failed with a dead URL"
    return
  fi
  if cmp -s "$TMP/want" "$TMP/got2"; then
    pass "fetch clones once and reuses"
  else
    failcase "fetch clones once and reuses" "second run moved root"
  fi
}

case_bad_home_loud() {
  mkdir -p "$TMP/badhome" || { echo "FAIL setup: badhome"; exit 1; }
  ln -s "$CHECKOUT" "$HOME/.harness" || { echo "FAIL setup: home link"; exit 1; }
  newproj p4 || { echo "FAIL setup: p4"; exit 1; }
  if HARNESS_HOME="$TMP/badhome" HARNESS_URL="$URL" "$PROJ/scripts/h" root >"$TMP/got" 2>"$TMP/err"; then
    failcase "bad HARNESS_HOME fails loudly" "exit 0 despite invalid HARNESS_HOME"
  else
    if grep -q "HARNESS_HOME" "$TMP/err"; then
      pass "bad HARNESS_HOME fails loudly"
    else
      failcase "bad HARNESS_HOME fails loudly" "stderr never names HARNESS_HOME"
    fi
  fi
  rm -f "$HOME/.harness"
}

case_unreachable_clean() {
  newproj p5 || { echo "FAIL setup: p5"; exit 1; }
  if env -u HARNESS_HOME HARNESS_URL="$DEAD" "$PROJ/scripts/h" root >"$TMP/got" 2>"$TMP/err"; then
    failcase "unreachable URL fails clean" "exit 0 despite a dead URL"
    return
  fi
  if [ -e "$PROJ/.harness" ]; then
    failcase "unreachable URL fails clean" ".harness left behind"
    return
  fi
  leftover=""
  for f in "$PROJ"/.harness-tmp.*; do
    if [ -e "$f" ]; then
      leftover="$f"
    fi
  done
  if [ -n "$leftover" ]; then
    failcase "unreachable URL fails clean" "temp dir left behind"
  else
    pass "unreachable URL fails clean"
  fi
}

case_stale_loud() {
  newproj p6 || { echo "FAIL setup: p6"; exit 1; }
  mkdir -p "$PROJ/.harness/junk" || { echo "FAIL setup: stale dir"; exit 1; }
  if env -u HARNESS_HOME HARNESS_URL="$URL" "$PROJ/scripts/h" root >"$TMP/got" 2>"$TMP/err"; then
    failcase "stale fetch fails loudly" "exit 0 despite a markerless .harness"
    return
  fi
  if grep -q "rm -rf .harness" "$TMP/err"; then
    pass "stale fetch fails loudly"
  else
    failcase "stale fetch fails loudly" "stderr never names the fix"
  fi
}

case_dispatch_shadow() {
  newproj p7 || { echo "FAIL setup: p7"; exit 1; }
  printf '#!/bin/bash\necho "PROBE-SHADOW ${HARNESS_PROJECT}"\n' > "$PROJ/scripts/brief.sh" || { echo "FAIL setup: p7 stub"; exit 1; }
  chmod +x "$PROJ/scripts/brief.sh" || { echo "FAIL setup: p7 chmod"; exit 1; }
  if ! HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" brief >"$TMP/got" 2>"$TMP/err"; then
    failcase "dispatch shadows and stays quiet" "dispatch exited non-zero"
    return
  fi
  if ! grep -q "PROBE-SHADOW" "$TMP/got" || ! grep -qF "$PROJ" "$TMP/got" || [ -s "$TMP/err" ]; then
    failcase "dispatch shadows and stays quiet" "project stub output wrong or stderr noisy"
    return
  fi
  if grep -q "harness:" "$TMP/got"; then
    failcase "dispatch shadows and stays quiet" "finder chatter leaked onto stdout"
    return
  fi
  rm -f "$PROJ/scripts/brief.sh" || { echo "FAIL setup: unstub p7"; exit 1; }
  if ! HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" brief >"$TMP/got" 2>"$TMP/err"; then
    failcase "dispatch shadows and stays quiet" "ROOT copy exited non-zero"
    return
  fi
  if grep -q "ROOT-BRIEF" "$TMP/got" && grep -qF "$PROJ" "$TMP/got" && [ ! -s "$TMP/err" ]; then
    pass "dispatch shadows and stays quiet"
  else
    failcase "dispatch shadows and stays quiet" "ROOT copy output wrong or stderr noisy"
  fi
}

case_doctor_shadow() {
  newproj p8 || { echo "FAIL setup: p8"; exit 1; }
  printf '#!/bin/bash\necho probe\n' > "$PROJ/scripts/brief.sh" || { echo "FAIL setup: p8 stub"; exit 1; }
  if ! HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" doctor >"$TMP/got" 2>"$TMP/err"; then
    failcase "doctor reports root source shadow" "non-zero exit"
    return
  fi
  if grep -qF "$CHECKOUT/template" "$TMP/got" && grep -q "HARNESS_HOME" "$TMP/got" && grep -q "shadow.*brief.sh" "$TMP/got"; then
    pass "doctor reports root source shadow"
  else
    failcase "doctor reports root source shadow" "root, source, or shadow line missing"
  fi
}

case_link_entries() {
  newproj p9 || { echo "FAIL setup: p9"; exit 1; }
  mkdir -p "$PROJ/.claude/skills/mine" || { echo "FAIL setup: p9 own skill"; exit 1; }
  printf 'mine\n' > "$PROJ/.claude/skills/mine/SKILL.md" || { echo "FAIL setup: p9 own file"; exit 1; }
  before9=$FAILS
  if HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" link >"$TMP/got" 2>"$TMP/err"; then
    for e in "$CHECKOUT"/template/.claude/skills/*; do
      n="${e##*/}"
      if [ -L "$PROJ/.claude/skills/$n" ]; then
        readlink "$PROJ/.claude/skills/$n" > "$TMP/gotlink" || { echo "FAIL setup: readlink"; exit 1; }
        printf '%s\n' "$e" > "$TMP/want"
        if ! cmp -s "$TMP/want" "$TMP/gotlink"; then
          failcase "link links per entry" "$n points elsewhere"
        fi
      else
        failcase "link links per entry" "$n is not a symlink"
      fi
      if ! grep -qxF ".claude/skills/$n" "$PROJ/.gitignore" 2>/dev/null; then
        failcase "link links per entry" "$n missing from .gitignore"
      fi
    done
    for e in "$CHECKOUT"/template/.claude/agents/*.md; do
      [ -e "$e" ] || [ -L "$e" ] || continue
      n="${e##*/}"
      if [ -L "$PROJ/.claude/agents/$n" ]; then
        readlink "$PROJ/.claude/agents/$n" > "$TMP/gotlink" || { echo "FAIL setup: readlink"; exit 1; }
        printf '%s\n' "$e" > "$TMP/want"
        if ! cmp -s "$TMP/want" "$TMP/gotlink"; then
          failcase "link links per entry" "agent $n points elsewhere"
        fi
      else
        failcase "link links per entry" "agent $n is not a symlink"
      fi
      if ! grep -qxF ".claude/agents/$n" "$PROJ/.gitignore" 2>/dev/null; then
        failcase "link links per entry" "agent $n missing from .gitignore"
      fi
    done
    if [ ! -L "$PROJ/.agents/skills/probe" ]; then
      failcase "link links per entry" ".agents skill not linked"
    fi
    if [ -L "$PROJ/.claude/skills/mine" ]; then
      failcase "link links per entry" "project skill replaced by a link"
    elif [ ! -f "$PROJ/.claude/skills/mine/SKILL.md" ]; then
      failcase "link links per entry" "project skill file lost"
    elif grep -qxF ".claude/skills/mine" "$PROJ/.gitignore" 2>/dev/null; then
      failcase "link links per entry" "project skill wrongly gitignored"
    fi
    ln -s "$CHECKOUT/template/.claude/skills/no-such-skill" "$PROJ/.claude/skills/no-such-skill" || { echo "FAIL setup: p9 dangling"; exit 1; }
    ln -s "$TMP/definitely-not-here" "$PROJ/.claude/skills/stray" || { echo "FAIL setup: p9 stray"; exit 1; }
    if HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" link >"$TMP/got" 2>"$TMP/err"; then
      if [ -e "$PROJ/.claude/skills/no-such-skill" ] || [ -L "$PROJ/.claude/skills/no-such-skill" ]; then
        failcase "link links per entry" "dangling shared link not pruned"
      fi
      if [ ! -L "$PROJ/.claude/skills/stray" ]; then
        failcase "link links per entry" "project stray link removed"
      fi
    else
      failcase "link links per entry" "relink exited non-zero"
    fi
  else
    failcase "link links per entry" "non-zero exit"
  fi
  if [ "$FAILS" -eq "$before9" ]; then
    pass "link links per entry"
  fi
}

case_link_whole_dir() {
  newproj p9b || { echo "FAIL setup: p9b"; exit 1; }
  mkdir -p "$TMP/decoy" || { echo "FAIL setup: p9b decoy"; exit 1; }
  mkdir -p "$PROJ/.claude" || { echo "FAIL setup: p9b parent"; exit 1; }
  ln -s "$TMP/decoy" "$PROJ/.claude/skills" || { echo "FAIL setup: p9b link"; exit 1; }
  printf '%s\n' ".claude/skills" "node_modules/" > "$PROJ/.gitignore" || { echo "FAIL setup: p9b ignore"; exit 1; }
  before9b=$FAILS
  if HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" link >"$TMP/got" 2>"$TMP/err"; then
    if [ -L "$PROJ/.claude/skills" ]; then
      failcase "link converts a whole-dir symlink" "still a symlink"
    elif [ ! -d "$PROJ/.claude/skills" ]; then
      failcase "link converts a whole-dir symlink" "not a real dir"
    else
      for e in "$CHECKOUT"/template/.claude/skills/*; do
        n="${e##*/}"
        if [ ! -L "$PROJ/.claude/skills/$n" ]; then
          failcase "link converts a whole-dir symlink" "$n not linked after conversion"
        fi
      done
      if grep -qxF ".claude/skills" "$PROJ/.gitignore" 2>/dev/null; then
        failcase "link converts a whole-dir symlink" "stale whole-dir gitignore line hides the real dir"
      fi
      if ! grep -qxF "node_modules/" "$PROJ/.gitignore" 2>/dev/null; then
        failcase "link converts a whole-dir symlink" "unrelated gitignore line lost"
      fi
    fi
  else
    failcase "link converts a whole-dir symlink" "non-zero exit"
  fi
  if [ "$FAILS" -eq "$before9b" ]; then
    pass "link converts a whole-dir symlink"
  fi
}

case_unknown_cmd() {
  newproj p10 || { echo "FAIL setup: p10"; exit 1; }
  if HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" bogus-probe-cmd >"$TMP/got" 2>"$TMP/err"; then
    failcase "unknown command exits 2" "exit 0 on a bogus command"
  else
    rc=$?
    if [ "$rc" -eq 2 ]; then
      pass "unknown command exits 2"
    else
      failcase "unknown command exits 2" "wrong exit code"
    fi
  fi
}

case_relative_home() {
  newproj p11 || { echo "FAIL setup: p11"; exit 1; }
  cd "$PROJ" || { echo "FAIL setup: cd p11"; exit 1; }
  if ! HARNESS_HOME="../checkout" HARNESS_URL="$URL" ./scripts/h root >"$TMP/got" 2>"$TMP/err"; then
    failcase "relative HARNESS_HOME resolves and dispatches" "root exited non-zero"
    cd "$REPO" || { echo "FAIL setup: cd back"; exit 1; }
    return
  fi
  printf '%s\n' "$CHECKOUT/template" > "$TMP/want"
  if ! cmp -s "$TMP/want" "$TMP/got" || [ -s "$TMP/err" ]; then
    failcase "relative HARNESS_HOME resolves and dispatches" "root not absolute physical or stderr noisy"
    cd "$REPO" || { echo "FAIL setup: cd back"; exit 1; }
    return
  fi
  if ! HARNESS_HOME="../checkout" HARNESS_URL="$URL" ./scripts/h brief >"$TMP/got" 2>"$TMP/err"; then
    failcase "relative HARNESS_HOME resolves and dispatches" "dispatch exited non-zero"
    cd "$REPO" || { echo "FAIL setup: cd back"; exit 1; }
    return
  fi
  if grep -q "ROOT-BRIEF" "$TMP/got" && grep -qF "$PROJ" "$TMP/got" && [ ! -s "$TMP/err" ]; then
    pass "relative HARNESS_HOME resolves and dispatches"
  else
    failcase "relative HARNESS_HOME resolves and dispatches" "dispatch output wrong or stderr noisy"
  fi
  cd "$REPO" || { echo "FAIL setup: cd back"; exit 1; }
}

case_session_contract() {
  newproj p12 || { echo "FAIL setup: p12"; exit 1; }
  if ! HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" session >"$TMP/got" 2>"$TMP/err"; then
    failcase "session prints contract then brief" "non-zero exit"
    return
  fi
  if ! grep -q "Working on this project" "$TMP/got" || ! grep -q "ROOT-BRIEF" "$TMP/got" || ! grep -qF "$PROJ" "$TMP/got"; then
    failcase "session prints contract then brief" "contract or brief text missing"
    return
  fi
  if awk '/Working on this project/{c=NR} /ROOT-BRIEF/{if(!b)b=NR} END{exit !(c && b && c<b)}' "$TMP/got"; then
    pass "session prints contract then brief"
  else
    failcase "session prints contract then brief" "contract does not come before the brief"
  fi
}

case_session_hook_json() {
  newproj p13 || { echo "FAIL setup: p13"; exit 1; }
  if ! HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" session --hook >"$TMP/got" 2>"$TMP/err"; then
    failcase "session --hook emits one JSON holding both" "non-zero exit"
    return
  fi
  if ! python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$TMP/got"; then
    failcase "session --hook emits one JSON holding both" "stdout is not valid JSON"
    return
  fi
  if grep -q "Working on this project" "$TMP/got" && grep -q "ROOT-BRIEF" "$TMP/got"; then
    pass "session --hook emits one JSON holding both"
  else
    failcase "session --hook emits one JSON holding both" "JSON lacks contract or brief text"
  fi
}

case_fresh_skill_once() {
  newproj p14 || { echo "FAIL setup: p14"; exit 1; }
  if ! HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" session >"$TMP/got" 2>"$TMP/err"; then
    failcase "fresh skill links named once" "first run exited non-zero"
    return
  fi
  if ! grep -q "directly this session" "$TMP/got" || ! grep "SKILL.md" "$TMP/got" | grep -qF "$CHECKOUT"; then
    failcase "fresh skill links named once" "first run never named the skill paths"
    return
  fi
  if ! HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" session >"$TMP/got2" 2>"$TMP/err"; then
    failcase "fresh skill links named once" "second run exited non-zero"
    return
  fi
  if grep -q "directly this session" "$TMP/got2"; then
    failcase "fresh skill links named once" "second run repeated the skill note"
  else
    pass "fresh skill links named once"
  fi
}

case_session_no_harness() {
  newproj p15 || { echo "FAIL setup: p15"; exit 1; }
  if ! env -u HARNESS_HOME HARNESS_URL="$DEAD" "$PROJ/scripts/h" session >"$TMP/got" 2>"$TMP/err"; then
    failcase "session without harness stays loud and zero" "non-zero exit"
    return
  fi
  if grep -q "cannot fetch" "$TMP/got" && grep -q "cannot fetch" "$TMP/err"; then
    pass "session without harness stays loud and zero"
  else
    failcase "session without harness stays loud and zero" "loud line missing from stdout or stderr"
  fi
}

case_hooked_no_harness() {
  newproj p16 || { echo "FAIL setup: p16"; exit 1; }
  if ! env -u HARNESS_HOME HARNESS_URL="$DEAD" "$PROJ/scripts/h" session --hook >"$TMP/got" 2>"$TMP/err"; then
    failcase "hooked session without harness stays JSON and zero" "non-zero exit"
    return
  fi
  if ! python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$TMP/got"; then
    failcase "hooked session without harness stays JSON and zero" "stdout is not valid JSON"
    return
  fi
  if grep -q "cannot fetch" "$TMP/got" && grep -q "cannot fetch" "$TMP/err"; then
    pass "hooked session without harness stays JSON and zero"
  else
    failcase "hooked session without harness stays JSON and zero" "loud line missing from JSON or stderr"
  fi
}

case_hook_args() {
  newproj p17 || { echo "FAIL setup: p17"; exit 1; }
  if ! HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" hook probe-hook alpha beta >"$TMP/got" 2>"$TMP/err"; then
    failcase "hook runs with args" "non-zero exit"
    return
  fi
  printf 'PROBE-HOOK alpha beta\n' > "$TMP/want"
  if cmp -s "$TMP/want" "$TMP/got"; then
    pass "hook runs with args"
  else
    failcase "hook runs with args" "hook output wrong"
  fi
}

case_hook_no_harness() {
  newproj p18 || { echo "FAIL setup: p18"; exit 1; }
  if env -u HARNESS_HOME HARNESS_URL="$DEAD" "$PROJ/scripts/h" hook probe-hook >"$TMP/got" 2>"$TMP/err"; then
    failcase "hook without harness fails closed" "exit 0 despite a dead URL"
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then
      pass "hook without harness fails closed"
    else
      failcase "hook without harness fails closed" "wrong exit code"
    fi
  fi
}

case_link_contract_agents() {
  newproj p19 || { echo "FAIL setup: p19"; exit 1; }
  before19=$FAILS
  if HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" link >"$TMP/got" 2>"$TMP/err"; then
    if [ -L "$PROJ/.harness-contract.md" ]; then
      readlink "$PROJ/.harness-contract.md" > "$TMP/gotlink" || { echo "FAIL setup: readlink"; exit 1; }
      printf '%s\n' "$CHECKOUT/template/AGENTS.md" > "$TMP/want"
      if ! cmp -s "$TMP/want" "$TMP/gotlink"; then
        failcase "link makes contract and opencode links" ".harness-contract.md points elsewhere"
      fi
    else
      failcase "link makes contract and opencode links" ".harness-contract.md is not a symlink"
    fi
    if ! grep -qxF ".harness-contract.md" "$PROJ/.gitignore" 2>/dev/null; then
      failcase "link makes contract and opencode links" ".harness-contract.md missing from .gitignore"
    fi
    if [ -L "$PROJ/.opencode/agent/probe-agent.md" ]; then
      readlink "$PROJ/.opencode/agent/probe-agent.md" > "$TMP/gotlink" || { echo "FAIL setup: readlink"; exit 1; }
      printf '%s\n' "$CHECKOUT/template/.opencode/agent/probe-agent.md" > "$TMP/want"
      if ! cmp -s "$TMP/want" "$TMP/gotlink"; then
        failcase "link makes contract and opencode links" "opencode agent points elsewhere"
      fi
    else
      failcase "link makes contract and opencode links" "opencode agent is not a symlink"
    fi
    if ! grep -qxF ".opencode/agent/probe-agent.md" "$PROJ/.gitignore" 2>/dev/null; then
      failcase "link makes contract and opencode links" "opencode agent missing from .gitignore"
    fi
  else
    failcase "link makes contract and opencode links" "non-zero exit"
  fi
  if [ "$FAILS" -eq "$before19" ]; then
    pass "link makes contract and opencode links"
  fi
}

case_link_skip_agents() {
  mkdir -p "$TMP/noagents" || { echo "FAIL setup: noagents"; exit 1; }
  cp -R "$CHECKOUT/template" "$TMP/noagents/template" || { echo "FAIL setup: copy noagents"; exit 1; }
  rm -rf "$TMP/noagents/template/.opencode" || { echo "FAIL setup: strip opencode"; exit 1; }
  newproj p20 || { echo "FAIL setup: p20"; exit 1; }
  if ! HARNESS_HOME="$TMP/noagents" HARNESS_URL="$URL" "$PROJ/scripts/h" link >"$TMP/got" 2>"$TMP/err"; then
    failcase "link skips missing opencode agents" "non-zero exit"
    return
  fi
  if [ -e "$PROJ/.opencode" ] || [ -L "$PROJ/.opencode" ]; then
    failcase "link skips missing opencode agents" ".opencode appeared with no shared source"
  elif [ -L "$PROJ/.harness-contract.md" ]; then
    pass "link skips missing opencode agents"
  else
    failcase "link skips missing opencode agents" "contract link missing alongside the skip"
  fi
}

case_missing_contract() {
  mkdir -p "$TMP/nocontract" || { echo "FAIL setup: nocontract"; exit 1; }
  cp -R "$CHECKOUT/template" "$TMP/nocontract/template" || { echo "FAIL setup: copy nocontract"; exit 1; }
  rm -f "$TMP/nocontract/template/AGENTS.md" || { echo "FAIL setup: strip contract"; exit 1; }
  newproj p21 || { echo "FAIL setup: p21"; exit 1; }
  if ! HARNESS_HOME="$TMP/nocontract" HARNESS_URL="$URL" "$PROJ/scripts/h" session --hook >"$TMP/got" 2>"$TMP/err"; then
    failcase "missing contract stays loud JSON and zero" "non-zero exit"
    return
  fi
  if ! python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$TMP/got"; then
    failcase "missing contract stays loud JSON and zero" "stdout is not valid JSON"
    return
  fi
  if grep -q "no AGENTS.md" "$TMP/got" && grep -q "directly this session" "$TMP/got"; then
    pass "missing contract stays loud JSON and zero"
  else
    failcase "missing contract stays loud JSON and zero" "JSON names neither the problem nor the fresh skill note"
  fi
}

case_unreadable_contract() {
  mkdir -p "$TMP/badcontract" || { echo "FAIL setup: badcontract"; exit 1; }
  cp -R "$CHECKOUT/template" "$TMP/badcontract/template" || { echo "FAIL setup: copy badcontract"; exit 1; }
  chmod 000 "$TMP/badcontract/template/AGENTS.md" || { echo "FAIL setup: chmod badcontract"; exit 1; }
  newproj p22 || { echo "FAIL setup: p22"; exit 1; }
  if ! HARNESS_HOME="$TMP/badcontract" HARNESS_URL="$URL" "$PROJ/scripts/h" session --hook >"$TMP/got" 2>"$TMP/err"; then
    failcase "unreadable contract stays loud JSON and zero" "non-zero exit"
    chmod 644 "$TMP/badcontract/template/AGENTS.md" || { echo "FAIL setup: restore badcontract"; exit 1; }
    return
  fi
  if ! python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$TMP/got"; then
    failcase "unreadable contract stays loud JSON and zero" "stdout is not valid JSON"
    chmod 644 "$TMP/badcontract/template/AGENTS.md" || { echo "FAIL setup: restore badcontract"; exit 1; }
    return
  fi
  if grep -q "AGENTS.md" "$TMP/got" && grep -qi "unreadable\|damaged" "$TMP/got"; then
    pass "unreadable contract stays loud JSON and zero"
  else
    failcase "unreadable contract stays loud JSON and zero" "JSON never names the unreadable contract"
  fi
  chmod 644 "$TMP/badcontract/template/AGENTS.md" || { echo "FAIL setup: restore badcontract"; exit 1; }
}

case_link_stacks() {
  newproj p23 || { echo "FAIL setup: p23"; exit 1; }
  mkdir -p "$PROJ/harness/stacks" || { echo "FAIL setup: p23 stacks dir"; exit 1; }
  printf 'mine\n' > "$PROJ/harness/stacks/mine.md" || { echo "FAIL setup: p23 own file"; exit 1; }
  printf '# the stacks this project uses\nprobe\n\nno-such-stack\n' > "$PROJ/harness/stacks.txt" || { echo "FAIL setup: p23 list"; exit 1; }
  before23=$FAILS
  if HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" link >"$TMP/got" 2>"$TMP/err"; then
    if [ -L "$PROJ/harness/stacks/probe.md" ]; then
      readlink "$PROJ/harness/stacks/probe.md" > "$TMP/gotlink" || { echo "FAIL setup: readlink"; exit 1; }
      printf '%s\n' "$CHECKOUT/template/harness/stacks/probe.md" > "$TMP/want"
      if ! cmp -s "$TMP/want" "$TMP/gotlink"; then
        failcase "link links listed stacks" "probe.md points elsewhere"
      fi
    else
      failcase "link links listed stacks" "probe.md is not a symlink"
    fi
    if ! grep -qxF "harness/stacks/probe.md" "$PROJ/.gitignore" 2>/dev/null; then
      failcase "link links listed stacks" "probe.md missing from .gitignore"
    fi
    if [ -L "$PROJ/harness/stacks/mine.md" ]; then
      failcase "link links listed stacks" "project-owned mine.md replaced by a link"
    elif [ ! -f "$PROJ/harness/stacks/mine.md" ]; then
      failcase "link links listed stacks" "project-owned mine.md lost"
    fi
    if grep -q "no-such-stack" "$TMP/err" && grep -q "harness/stacks.txt" "$TMP/err"; then
      :
    else
      failcase "link links listed stacks" "unknown stack never named loudly on stderr"
    fi
    if grep -q "known:" "$TMP/err"; then
      :
    else
      failcase "link links listed stacks" "stderr never names the known stacks"
    fi
  else
    failcase "link links listed stacks" "non-zero exit on an unknown stack"
  fi
  if [ "$FAILS" -eq "$before23" ]; then
    pass "link links listed stacks"
  fi
}

case_link_prune_stacks() {
  newproj p24 || { echo "FAIL setup: p24"; exit 1; }
  mkdir -p "$PROJ/harness/stacks" || { echo "FAIL setup: p24 stacks dir"; exit 1; }
  printf 'probe\ndangling-listed\n' > "$PROJ/harness/stacks.txt" || { echo "FAIL setup: p24 list"; exit 1; }
  ln -s "$CHECKOUT/template/harness/stacks/probe-extra.md" "$PROJ/harness/stacks/probe-extra.md" || { echo "FAIL setup: p24 extra link"; exit 1; }
  ln -s "$CHECKOUT/template/harness/stacks/no-such.md" "$PROJ/harness/stacks/stale.md" || { echo "FAIL setup: p24 dangling"; exit 1; }
  ln -s "$CHECKOUT/template/harness/stacks/no-such.md" "$PROJ/harness/stacks/dangling-listed.md" || { echo "FAIL setup: p24 listed dangling"; exit 1; }
  ln -s "$TMP/definitely-not-here" "$PROJ/harness/stacks/stray.md" || { echo "FAIL setup: p24 stray"; exit 1; }
  before24=$FAILS
  if HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" link >"$TMP/got" 2>"$TMP/err"; then
    if [ ! -L "$PROJ/harness/stacks/probe.md" ]; then
      failcase "link prunes unlisted stack links" "listed probe.md not linked"
    fi
    if [ -e "$PROJ/harness/stacks/probe-extra.md" ] || [ -L "$PROJ/harness/stacks/probe-extra.md" ]; then
      failcase "link prunes unlisted stack links" "unlisted probe-extra.md not pruned"
    fi
    if [ -e "$PROJ/harness/stacks/stale.md" ] || [ -L "$PROJ/harness/stacks/stale.md" ]; then
      failcase "link prunes unlisted stack links" "dangling stale.md not pruned"
    fi
    if [ -e "$PROJ/harness/stacks/dangling-listed.md" ] || [ -L "$PROJ/harness/stacks/dangling-listed.md" ]; then
      failcase "link prunes unlisted stack links" "dangling listed link not pruned"
    fi
    if grep -q "dangling-listed" "$TMP/err"; then
      :
    else
      failcase "link prunes unlisted stack links" "missing shared guidance never named loudly"
    fi
    if [ ! -L "$PROJ/harness/stacks/stray.md" ]; then
      failcase "link prunes unlisted stack links" "project stray link removed"
    fi
  else
    failcase "link prunes unlisted stack links" "non-zero exit"
  fi
  if [ "$FAILS" -eq "$before24" ]; then
    pass "link prunes unlisted stack links"
  fi
}

case_link_no_stacks() {
  newproj p25 || { echo "FAIL setup: p25"; exit 1; }
  before25=$FAILS
  if HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" link >"$TMP/got" 2>"$TMP/err"; then
    if [ -e "$PROJ/harness/stacks" ] || [ -L "$PROJ/harness/stacks" ]; then
      failcase "link without stacks.txt stays quiet" "harness/stacks appeared with no list"
    fi
  else
    failcase "link without stacks.txt stays quiet" "non-zero exit"
  fi
  if [ "$FAILS" -eq "$before25" ]; then
    pass "link without stacks.txt stays quiet"
  fi
}

case_starter_self() {
  newproj p26 || { echo "FAIL setup: p26"; exit 1; }
  mkdir -p "$PROJ/template" || { echo "FAIL setup: p26 template"; exit 1; }
  cp -R "$CHECKOUT/template/." "$PROJ/template/" || { echo "FAIL setup: p26 copy"; exit 1; }
  mkdir -p "$TMP/other" || { echo "FAIL setup: other"; exit 1; }
  cp -R "$CHECKOUT/template" "$TMP/other/template" || { echo "FAIL setup: other copy"; exit 1; }
  rm -f "$HOME/.harness" || { echo "FAIL setup: home clean"; exit 1; }
  before26=$FAILS
  if HARNESS_HOME="$TMP/other" HARNESS_URL="$DEAD" "$PROJ/scripts/h" root >"$TMP/got" 2>"$TMP/err"; then
    printf '%s\n' "$PROJ/template" > "$TMP/want"
    if cmp -s "$TMP/want" "$TMP/got" && [ ! -s "$TMP/err" ]; then
      if HARNESS_HOME="$TMP/other" HARNESS_URL="$DEAD" "$PROJ/scripts/h" doctor >"$TMP/got" 2>"$TMP/err"; then
        if grep -q "source: starter" "$TMP/got" && grep -qF "$PROJ/template" "$TMP/got"; then
          :
        else
          failcase "starter resolves to its own template first" "doctor never said starter with the project root"
        fi
      else
        failcase "starter resolves to its own template first" "doctor exited non-zero"
      fi
    else
      failcase "starter resolves to its own template first" "wrong root on stdout or stderr noisy"
    fi
  else
    failcase "starter resolves to its own template first" "non-zero exit"
  fi
  if [ "$FAILS" -eq "$before26" ]; then
    pass "starter resolves to its own template first"
  fi
}

case_handover_shared() {
  newproj p27 || { echo "FAIL setup: p27"; exit 1; }
  if ! HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" probe-only >"$TMP/got" 2>"$TMP/err"; then
    failcase "committed finder hands off to the shared finder" "non-zero exit — the shared finder never ran, or a HARNESS_FINDER_* variable leaked"
    return
  fi
  if grep -q "PROBE-HANDOVER-MARKER" "$TMP/got" && [ ! -s "$TMP/err" ]; then
    pass "committed finder hands off to the shared finder"
  else
    failcase "committed finder hands off to the shared finder" "marker missing from stdout or stderr noisy"
  fi
}

# --- run all cases in order ---
case_harness_home_wins
case_home_no_clone
case_fetch_reuse
case_bad_home_loud
case_unreachable_clean
case_stale_loud
case_dispatch_shadow
case_doctor_shadow
case_link_entries
case_link_whole_dir
case_unknown_cmd
case_relative_home
case_session_contract
case_session_hook_json
case_fresh_skill_once
case_session_no_harness
case_hooked_no_harness
case_hook_args
case_hook_no_harness
case_link_contract_agents
case_link_skip_agents
case_missing_contract
case_unreadable_contract
case_link_stacks
case_link_prune_stacks
case_link_no_stacks
case_starter_self
case_handover_shared

if [ "$FAILS" -eq 0 ]; then
  exit 0
else
  exit 1
fi
