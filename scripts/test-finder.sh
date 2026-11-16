#!/bin/bash
# Probe for the scripts/h finder: resolution order, fetching, dispatch,
# shadowing, linking, and every loud failure.
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
# real shared scripts (another worker owns those right now).
printf '#!/bin/bash\necho "ROOT-BRIEF ${HARNESS_PROJECT}"\n' > "$CHECKOUT/template/scripts/brief.sh" || { echo "FAIL setup: stub brief"; exit 1; }
chmod +x "$CHECKOUT/template/scripts/brief.sh" || { echo "FAIL setup: chmod stub"; exit 1; }
# A probe entry under .agents/skills, so the link's third path is exercised.
mkdir -p "$CHECKOUT/template/.agents/skills/probe" || { echo "FAIL setup: agents fixture"; exit 1; }
printf 'probe\n' > "$CHECKOUT/template/.agents/skills/probe/SKILL.md" || { echo "FAIL setup: agents file"; exit 1; }
(cd "$CHECKOUT" && git init -q .) >/dev/null || { echo "FAIL setup: git init"; exit 1; }
(cd "$CHECKOUT" && git add -A) >/dev/null || { echo "FAIL setup: git add"; exit 1; }
(cd "$CHECKOUT" && git -c user.email=probe@t -c user.name=probe -c commit.gpgsign=false commit -qm probe) >/dev/null || { echo "FAIL setup: git commit"; exit 1; }
git clone -q --bare "$CHECKOUT" "$BARE" >/dev/null || { echo "FAIL setup: bare clone"; exit 1; }
URL="file://$BARE"
DEAD="file://$TMP/no-such-repo"

# --- 1: HARNESS_HOME wins ---
newproj p1 || { echo "FAIL setup: p1"; exit 1; }
if HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" root >"$TMP/got" 2>"$TMP/err"; then
  printf '%s\n' "$CHECKOUT/template" > "$TMP/want"
  if cmp -s "$TMP/want" "$TMP/got" && [ ! -s "$TMP/err" ]; then
    pass "env HARNESS_HOME resolves"
  else
    failcase "env HARNESS_HOME resolves" "wrong root on stdout or stderr noisy"
  fi
else
  failcase "env HARNESS_HOME resolves" "non-zero exit"
fi

# --- 2: ~/.harness, and it never clones ---
ln -s "$CHECKOUT" "$HOME/.harness" || { echo "FAIL setup: home link"; exit 1; }
newproj p2 || { echo "FAIL setup: p2"; exit 1; }
if env -u HARNESS_HOME HARNESS_URL="$DEAD" "$PROJ/scripts/h" root >"$TMP/got" 2>"$TMP/err"; then
  printf '%s\n' "$CHECKOUT/template" > "$TMP/want"
  if cmp -s "$TMP/want" "$TMP/got" && [ ! -s "$TMP/err" ]; then
    if [ -e "$PROJ/.harness" ]; then
      failcase "home resolves without cloning" ".harness appeared in the project"
    else
      pass "home resolves without cloning"
    fi
  else
    failcase "home resolves without cloning" "wrong root on stdout or stderr noisy"
  fi
else
  failcase "home resolves without cloning" "non-zero exit"
fi
rm -f "$HOME/.harness"

# --- 3: fetch, gitignore, and the second run reuses ---
newproj p3 || { echo "FAIL setup: p3"; exit 1; }
if env -u HARNESS_HOME HARNESS_URL="$URL" "$PROJ/scripts/h" root >"$TMP/got" 2>"$TMP/err"; then
  printf '%s\n' "$PROJ/.harness/template" > "$TMP/want"
  if cmp -s "$TMP/want" "$TMP/got"; then
    if grep -qxF '.harness/' "$PROJ/.gitignore" 2>/dev/null; then
      if env -u HARNESS_HOME HARNESS_URL="$DEAD" "$PROJ/scripts/h" root >"$TMP/got2" 2>"$TMP/err"; then
        if cmp -s "$TMP/want" "$TMP/got2"; then
          pass "fetch clones once and reuses"
        else
          failcase "fetch clones once and reuses" "second run moved root"
        fi
      else
        failcase "fetch clones once and reuses" "second run failed with a dead URL"
      fi
    else
      failcase "fetch clones once and reuses" ".gitignore lacks .harness/"
    fi
  else
    failcase "fetch clones once and reuses" "wrong root on stdout"
  fi
else
  failcase "fetch clones once and reuses" "non-zero exit"
fi

# --- 4: a bad HARNESS_HOME fails and never falls through ---
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

# --- 5: an unreachable URL leaves nothing behind ---
newproj p5 || { echo "FAIL setup: p5"; exit 1; }
if env -u HARNESS_HOME HARNESS_URL="$DEAD" "$PROJ/scripts/h" root >"$TMP/got" 2>"$TMP/err"; then
  failcase "unreachable URL fails clean" "exit 0 despite a dead URL"
else
  if [ -e "$PROJ/.harness" ]; then
    failcase "unreachable URL fails clean" ".harness left behind"
  else
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
  fi
fi

# --- 6: a stale .harness names the fix ---
newproj p6 || { echo "FAIL setup: p6"; exit 1; }
mkdir -p "$PROJ/.harness/junk" || { echo "FAIL setup: stale dir"; exit 1; }
if env -u HARNESS_HOME HARNESS_URL="$URL" "$PROJ/scripts/h" root >"$TMP/got" 2>"$TMP/err"; then
  failcase "stale fetch fails loudly" "exit 0 despite a markerless .harness"
else
  if grep -q "rm -rf .harness" "$TMP/err"; then
    pass "stale fetch fails loudly"
  else
    failcase "stale fetch fails loudly" "stderr never names the fix"
  fi
fi

# --- 7: dispatch prefers the project copy, else the ROOT copy ---
newproj p7 || { echo "FAIL setup: p7"; exit 1; }
printf '#!/bin/bash\necho "PROBE-SHADOW ${HARNESS_PROJECT}"\n' > "$PROJ/scripts/brief.sh" || { echo "FAIL setup: p7 stub"; exit 1; }
chmod +x "$PROJ/scripts/brief.sh" || { echo "FAIL setup: p7 chmod"; exit 1; }
if HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" brief >"$TMP/got" 2>"$TMP/err"; then
  if grep -q "PROBE-SHADOW" "$TMP/got" && grep -qF "$PROJ" "$TMP/got" && [ ! -s "$TMP/err" ]; then
    if grep -q "harness:" "$TMP/got"; then
      failcase "dispatch shadows and stays quiet" "finder chatter leaked onto stdout"
    else
      rm -f "$PROJ/scripts/brief.sh" || { echo "FAIL setup: unstub p7"; exit 1; }
      if HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" brief >"$TMP/got" 2>"$TMP/err"; then
        if grep -q "ROOT-BRIEF" "$TMP/got" && grep -qF "$PROJ" "$TMP/got" && [ ! -s "$TMP/err" ]; then
          pass "dispatch shadows and stays quiet"
        else
          failcase "dispatch shadows and stays quiet" "ROOT copy output wrong or stderr noisy"
        fi
      else
        failcase "dispatch shadows and stays quiet" "ROOT copy exited non-zero"
      fi
    fi
  else
    failcase "dispatch shadows and stays quiet" "project stub output wrong or stderr noisy"
  fi
else
  failcase "dispatch shadows and stays quiet" "dispatch exited non-zero"
fi

# --- 8: doctor lists root, source, and the shadow ---
newproj p8 || { echo "FAIL setup: p8"; exit 1; }
printf '#!/bin/bash\necho probe\n' > "$PROJ/scripts/brief.sh" || { echo "FAIL setup: p8 stub"; exit 1; }
if HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" doctor >"$TMP/got" 2>"$TMP/err"; then
  if grep -qF "$CHECKOUT/template" "$TMP/got" && grep -q "HARNESS_HOME" "$TMP/got" && grep -q "shadow.*brief.sh" "$TMP/got"; then
    pass "doctor reports root source shadow"
  else
    failcase "doctor reports root source shadow" "root, source, or shadow line missing"
  fi
else
  failcase "doctor reports root source shadow" "non-zero exit"
fi

# --- 9: link links per entry, keeps project files, converts old links ---
newproj p9 || { echo "FAIL setup: p9"; exit 1; }
# A project-own skill beside the shared ones.
mkdir -p "$PROJ/.claude/skills/mine" || { echo "FAIL setup: p9 own skill"; exit 1; }
printf 'mine\n' > "$PROJ/.claude/skills/mine/SKILL.md" || { echo "FAIL setup: p9 own file"; exit 1; }
before9=$FAILS
if HARNESS_HOME="$CHECKOUT" HARNESS_URL="$URL" "$PROJ/scripts/h" link >"$TMP/got" 2>"$TMP/err"; then
  # Every shared skill is a link to the checkout entry, and gitignored.
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
  # Every shared agent file is a link, and the probe .agents skill too.
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
  # The project's own skill survives untouched: still real, unlinked, kept.
  if [ -L "$PROJ/.claude/skills/mine" ]; then
    failcase "link links per entry" "project skill replaced by a link"
  elif [ ! -f "$PROJ/.claude/skills/mine/SKILL.md" ]; then
    failcase "link links per entry" "project skill file lost"
  elif grep -qxF ".claude/skills/mine" "$PROJ/.gitignore" 2>/dev/null; then
    failcase "link links per entry" "project skill wrongly gitignored"
  fi
  # A dangling link to a removed shared skill is pruned; the project's own
  # broken link is left alone.
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

# --- 9b: a pre-existing whole-dir symlink is converted ---
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

# --- 10: an unknown command exits 2 ---
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

# --- 11: a relative HARNESS_HOME still resolves absolute and dispatches ---
newproj p11 || { echo "FAIL setup: p11"; exit 1; }
cd "$PROJ" || { echo "FAIL setup: cd p11"; exit 1; }
if HARNESS_HOME="../checkout" HARNESS_URL="$URL" ./scripts/h root >"$TMP/got" 2>"$TMP/err"; then
  printf '%s\n' "$CHECKOUT/template" > "$TMP/want"
  if cmp -s "$TMP/want" "$TMP/got" && [ ! -s "$TMP/err" ]; then
    if HARNESS_HOME="../checkout" HARNESS_URL="$URL" ./scripts/h brief >"$TMP/got" 2>"$TMP/err"; then
      if grep -q "ROOT-BRIEF" "$TMP/got" && grep -qF "$PROJ" "$TMP/got" && [ ! -s "$TMP/err" ]; then
        pass "relative HARNESS_HOME resolves and dispatches"
      else
        failcase "relative HARNESS_HOME resolves and dispatches" "dispatch output wrong or stderr noisy"
      fi
    else
      failcase "relative HARNESS_HOME resolves and dispatches" "dispatch exited non-zero"
    fi
  else
    failcase "relative HARNESS_HOME resolves and dispatches" "root not absolute physical or stderr noisy"
  fi
else
  failcase "relative HARNESS_HOME resolves and dispatches" "root exited non-zero"
fi
cd "$REPO" || { echo "FAIL setup: cd back"; exit 1; }

if [ "$FAILS" -eq 0 ]; then
  exit 0
else
  exit 1
fi
