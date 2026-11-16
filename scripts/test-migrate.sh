#!/bin/bash
# Probe for `harness migrate`: a fixture copy install with one customised
# reviewer prompt, one diverged dashboard file, one unacknowledged edited
# script and one own skill must classify each with the right fate on dry
# run (writing nothing), convert on --apply, no-op on a second --apply,
# and pass `h verify` afterwards — without touching template/.
#
# Self-contained: the fixture lives under mktemp -d, HOME points at a temp
# dir so the real ~/.harness is never consulted, and HARNESS_HOME points at
# this checkout. One `ok <case>` / `FAIL <case>: why` line per case.
# Exits non-zero when any case fails.
#
# Bash 3.2 only: no associative arrays, no ${x,,}, no mapfile, no `local -n`.

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d)" || { echo "FAIL setup: mktemp failed"; exit 1; }
# Physical path: mktemp may return a symlinked prefix (/var -> /private/var
# on macOS) while the installer resolves targets with pwd -P.
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" || { echo "FAIL setup: cannot make fake HOME"; exit 1; }
export HARNESS_HOME="$REPO"
export GIT_AUTHOR_NAME=probe GIT_COMMITTER_NAME=probe
export GIT_AUTHOR_EMAIL=probe@t GIT_COMMITTER_EMAIL=probe@t

# The same rev resolution the migrate uses: the fixture archives the whole
# template tree at the last commit that shipped the copy-install configs, and
# migrate_last_shipped reads the same revision content-wise — one helper, so
# the two cannot disagree about HEAD-vs-deleted.
. "$REPO/commands/lib/migrate.sh"

FAILS=0
pass() { printf 'ok %s\n' "$1"; }
failcase() { FAILS=$((FAILS + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

# The shared tree before any fixture exists. Covers all of template/: a save
# through a link would read as this probe writing through one.
shared_hash() {
  (cd "$REPO/template" && find . -type f ! -path '*/__pycache__/*' \
    -print0 | sort -z | xargs -0 shasum) | shasum | cut -d' ' -f1
}
SHARED_BEFORE="$(shared_hash)"

# --- fixture: a copy install, the way a plain `harness add` used to leave one ---
# Built by hand: `harness add` is reference-only now and writes no copies.
# Every template file a copy install carried — no stubs, no generated agents,
# no guidance for unlisted stacks — modes preserved. bd inits before the copy
# lands, the way `add` ordered it: bd writes through links into the shared
# checkout, so links never predate a bd command.
FIX="$TMP/fix"
mkdir -p "$FIX" || { echo "FAIL setup: cannot make the fixture project"; exit 1; }
git init -q "$FIX" || { echo "FAIL setup: git init failed"; exit 1; }
(cd "$FIX" && bd init --prefix fix >/dev/null 2>&1) || { echo "FAIL setup: bd init failed"; exit 1; }
# Taken from the last starter commit that still shipped the copy-install
# configs, because that is what every real copied install was made from —
# today's template no longer carries them. A shallow clone may lack it: say so.
# Newest such commit: HEAD while the configs still exist there, else the
# parent of the commit that deleted them.
OLD_REV="$(migrate_last_shipped_rev "$REPO" ".claude/settings.json")" || OLD_REV=""
[ -n "$OLD_REV" ] || { echo "FAIL setup: no starter commit with copy-install configs — this probe needs full history"; exit 1; }
OLD_TREE="$TMP/old-template"
mkdir -p "$OLD_TREE" && git -C "$REPO" archive "$OLD_REV" template | tar -x -C "$OLD_TREE" ||
  { echo "FAIL setup: cannot export template at $OLD_REV"; exit 1; }
while IFS= read -r rel; do
  case "$rel" in stubs/*|.opencode/*|harness/stacks/*) continue ;; esac
  mkdir -p "$FIX/$(dirname "$rel")" || { echo "FAIL setup: cannot make $(dirname "$rel")"; exit 1; }
  cp -p "$OLD_TREE/template/$rel" "$FIX/$rel" || { echo "FAIL setup: cannot copy $rel"; exit 1; }
done <<< "$(cd "$OLD_TREE/template" && find . -type f | sed 's|^\./||' | sort)"
# Normalized the way `add` left them: no doc bd init may have planted that the
# copy doesn't overwrite, and no copied beads skill beside the shared ones.
rm -f "$FIX/CLAUDE.md"
rm -rf "$FIX/.agents/skills/beads"
if [ -f "$FIX/scripts/verify.sh" ] && [ -f "$FIX/.claude/agents/reviewer-taste.md" ]; then
  pass "fixture carries the whole harness"
else
  failcase "fixture carries the whole harness" "contract files missing from the copy"
fi

# One customised reviewer prompt.
printf '\n## Project checks\n\n- No foobar in this repo.\n' >> "$FIX/.claude/agents/reviewer-taste.md" || { echo "FAIL setup: cannot customise the reviewer prompt"; exit 1; }
# One diverged dashboard file, acknowledged the supported way (`diverge` is
# retired; the list is a plain project file now).
printf '\n<!-- project chip -->\n' >> "$FIX/dashboard/index.html" || { echo "FAIL setup: cannot edit the dashboard file"; exit 1; }
printf 'dashboard/index.html\n' >> "$FIX/harness/diverged.txt" || { echo "FAIL setup: cannot acknowledge the fork"; exit 1; }
# One unacknowledged edited script.
printf '\n# project VERDICT tuning\n' >> "$FIX/scripts/dashboard.py" || { echo "FAIL setup: cannot edit the script"; exit 1; }
# One own skill, beside the shared ones.
mkdir -p "$FIX/.claude/skills/own-skill" || { echo "FAIL setup: cannot make the own skill"; exit 1; }
cat > "$FIX/.claude/skills/own-skill/SKILL.md" <<'EOF' || { echo "FAIL setup: cannot write the own skill"; exit 1; }
---
description: The fixture project's own skill.
---

# Own skill

Project-owned answers live beside the shared skills, never inside them.
EOF
# One unedited copy from an older starter revision: byte-identical to the
# template file as it looked at the newest commit whose blob differs from
# today's. Fails loudly when history holds no such commit (shallow clone).
TODAY_BLOB="$(git hash-object "$REPO/template/scripts/brief.sh" 2>/dev/null)" || { echo "FAIL setup: cannot hash today's template/scripts/brief.sh"; exit 1; }
OLD_COMMIT=""
for OLD_CANDIDATE in $(git -C "$REPO" log --format='%H' -- template/scripts/brief.sh 2>/dev/null); do
  CAND_BLOB="$(git -C "$REPO" rev-parse "$OLD_CANDIDATE:template/scripts/brief.sh" 2>/dev/null)" || continue
  if [ "$CAND_BLOB" != "$TODAY_BLOB" ]; then
    OLD_COMMIT="$OLD_CANDIDATE"
    break
  fi
done
if [ -z "$OLD_COMMIT" ]; then
  echo "FAIL setup: no older template/scripts/brief.sh revision in history — shallow clone?"
  exit 1
fi
if ! git -C "$REPO" show "$OLD_COMMIT:template/scripts/brief.sh" > "$FIX/scripts/brief.sh" 2>"$TMP/oldshow.err"; then
  echo "FAIL setup: cannot read the older template revision: $(head -1 "$TMP/oldshow.err" 2>/dev/null)"
  exit 1
fi
if cmp -s "$REPO/template/scripts/brief.sh" "$FIX/scripts/brief.sh"; then
  echo "FAIL setup: the older revision no longer differs from today — pick another commit"
  exit 1
fi
# A fixture gate that can pass: the seed steps fail by design (`false`), so a
# project with real commands replaces them — this one with trivially true ones.
if ! sed -e 's/^step "build" false/step "build" true/' -e 's/^probe_step "tests" false/probe_step "tests" true/' \
    "$FIX/scripts/verify.steps.sh" > "$TMP/steps.sh"; then
  echo "FAIL setup: cannot rewrite the gate steps"
  exit 1
fi
mv "$TMP/steps.sh" "$FIX/scripts/verify.steps.sh" || { echo "FAIL setup: cannot install the gate steps"; exit 1; }

git -C "$FIX" config user.email probe@t >/dev/null 2>&1 || true
git -C "$FIX" config user.name probe >/dev/null 2>&1 || true
BID=""
if ! BID="$(cd "$FIX" && bd create "probe work" --design "d" --acceptance "a" --silent 2>"$TMP/bead.err")"; then
  echo "FAIL setup: cannot file a probe bead: $(head -1 "$TMP/bead.err" 2>/dev/null)"
  exit 1
fi
# Filing dirtied the ledger past its export; refresh with memories before the
# commit the gate's first check compares against.
if ! (cd "$FIX" && BD_EXPORT_AUTO=false BD_IMPORT_AUTO=false \
      bd export --include-memories -o .beads/issues.jsonl >/dev/null 2>&1); then
  echo "FAIL setup: cannot refresh the ledger export"
  exit 1
fi
if ! (cd "$FIX" && git add -A >/dev/null 2>&1 && git -c commit.gpgsign=false commit -m "probe fixture $BID" >/dev/null 2>&1); then
  echo "FAIL setup: cannot commit the fixture"
  exit 1
fi

# --- dry run: every fate listed, nothing written ---
if ! "$REPO/bin/harness" migrate "$FIX" >"$TMP/dry.log" 2>&1; then
  failcase "dry run exits zero" "non-zero exit on a clean tree"
else
  pass "dry run exits zero"
fi
if grep -q "lift.*\.claude/agents/reviewer-taste\.md.*harness/reviewers/taste\.md" "$TMP/dry.log" 2>/dev/null; then
  pass "dry run lifts the customised reviewer prompt"
else
  failcase "dry run lifts the customised reviewer prompt" "no lift fate for reviewer-taste.md"
fi
# One dashboard now: a forked page is named for reconciling, never a shadow.
if grep -q "name.*dashboard/index\.html.*one dashboard" "$TMP/dry.log" 2>/dev/null; then
  pass "dry run names the forked dashboard page"
else
  failcase "dry run names the forked dashboard page" "no name fate for dashboard/index.html"
fi
if grep -q "name.*scripts/dashboard\.py" "$TMP/dry.log" 2>/dev/null; then
  pass "dry run names the unacknowledged edited script"
else
  failcase "dry run names the unacknowledged edited script" "no name fate for scripts/dashboard.py"
fi
if grep -q "keep.*\.claude/skills/own-skill/SKILL\.md" "$TMP/dry.log" 2>/dev/null; then
  pass "dry run keeps the own skill"
else
  failcase "dry run keeps the own skill" "no keep fate for the own skill"
fi
if grep -q "remove.*scripts/verify\.sh" "$TMP/dry.log" 2>/dev/null; then
  pass "dry run removes identical copies"
else
  failcase "dry run removes identical copies" "no remove fate for scripts/verify.sh"
fi
if grep -q "remove.*scripts/brief\.sh.*older starter revision" "$TMP/dry.log" 2>/dev/null; then
  pass "dry run removes an unedited copy from an older starter revision"
else
  failcase "dry run removes an unedited copy from an older starter revision" "no older-revision remove fate for scripts/brief.sh"
fi
if grep -q "stub.*AGENTS\.md" "$TMP/dry.log" 2>/dev/null; then
  pass "dry run stubs the matching contract"
else
  failcase "dry run stubs the matching contract" "no stub fate for AGENTS.md"
fi
if [ -z "$(git -C "$FIX" status --porcelain)" ]; then
  pass "dry run changes nothing"
else
  failcase "dry run changes nothing" "the tree is dirty after a dry run"
fi

# --- a diverged entry acknowledging nothing fails before writing ---
printf 'scripts/dashbord.py\nREADME.md\ndashboard.toml\n' >> "$FIX/harness/diverged.txt" || { echo "FAIL setup: cannot plant bogus diverged entries"; exit 1; }
if "$REPO/bin/harness" migrate "$FIX" >"$TMP/bogus.log" 2>&1; then
  failcase "bogus diverged entries fail the dry run" "exit 0 with entries acknowledging nothing"
else
  before_bogus=$FAILS
  grep -qF "scripts/dashbord.py (no such template file)" "$TMP/bogus.log" 2>/dev/null ||
    failcase "bogus diverged entries fail the dry run" "never flagged the typo entry"
  grep -qF "README.md (no such template file)" "$TMP/bogus.log" 2>/dev/null ||
    failcase "bogus diverged entries fail the dry run" "never flagged the non-template entry"
  grep -qF "dashboard.toml (already quiet" "$TMP/bogus.log" 2>/dev/null ||
    failcase "bogus diverged entries fail the dry run" "never flagged the already-quiet entry"
  grep -q "acknowledge nothing" "$TMP/bogus.log" 2>/dev/null ||
    failcase "bogus diverged entries fail the dry run" "never said acknowledge nothing"
  if [ "$FAILS" -eq "$before_bogus" ]; then
    pass "bogus diverged entries fail the dry run"
  fi
fi
git -C "$FIX" checkout -- harness/diverged.txt >/dev/null 2>&1 || { echo "FAIL setup: cannot restore diverged.txt"; exit 1; }

# --- a dirty tree refuses the write ---
printf '\n# dirty\n' >> "$FIX/dashboard.toml" || { echo "FAIL setup: cannot dirty the tree"; exit 1; }
if "$REPO/bin/harness" migrate --apply "$FIX" >"$TMP/dirty.log" 2>&1; then
  failcase "apply refuses a dirty tree" "exit 0 with uncommitted changes"
elif grep -q "dashboard.toml" "$TMP/dirty.log" 2>/dev/null; then
  pass "apply refuses a dirty tree"
else
  failcase "apply refuses a dirty tree" "refused without naming the change"
fi
git -C "$FIX" checkout -- dashboard.toml >/dev/null 2>&1 || { echo "FAIL setup: cannot clean the tree"; exit 1; }

# --- --apply converts ---
if ! "$REPO/bin/harness" migrate --apply "$FIX" >"$TMP/apply.log" 2>&1; then
  failcase "apply converts the tree" "non-zero exit: $(head -1 "$TMP/apply.log" 2>/dev/null)"
else
  pass "apply converts the tree"
fi
if [ ! -e "$FIX/scripts/verify.sh" ] && [ ! -e "$FIX/scripts/brief.sh" ]; then
  pass "apply removes identical copies"
else
  failcase "apply removes identical copies" "shared scripts still in place"
fi
if grep -q "remove.*scripts/brief\.sh.*older starter revision" "$TMP/apply.log" 2>/dev/null; then
  pass "apply removes the older-revision copy"
else
  failcase "apply removes the older-revision copy" "apply log names no older-revision remove for scripts/brief.sh"
fi
if [ -L "$FIX/.claude/agents/reviewer-taste.md" ] &&
   grep -q "No foobar" "$FIX/harness/reviewers/taste.md" 2>/dev/null; then
  pass "apply lifts the reviewer lines"
else
  failcase "apply lifts the reviewer lines" "prompt not linked or overlay missing the lines"
fi
if [ -f "$FIX/dashboard/index.html" ] && ! [ -L "$FIX/dashboard/index.html" ] &&
   grep -q "project chip" "$FIX/dashboard/index.html" 2>/dev/null; then
  pass "apply leaves the forked dashboard page for a person"
else
  failcase "apply leaves the forked dashboard page for a person" "forked dashboard file gone, linked, or reverted"
fi
if [ -f "$FIX/.claude/settings.json" ] && ! grep -q "dashboard" "$FIX/.claude/settings.json"; then
  pass "apply drops the per-project dashboard hooks"
else
  failcase "apply drops the per-project dashboard hooks" "settings.json still runs a dashboard hook"
fi
# Tracked AND ignored in a link area means a copy the link replaced is still in
# the index; the project's own skill stays tracked (it is not ignored).
stale_index="$(git -C "$FIX" ls-files -ci --exclude-standard -- .claude/skills .claude/agents .opencode/agent .codex/agents .agents/skills)"
if [ -z "$stale_index" ] && git -C "$FIX" ls-files --error-unmatch .claude/skills/own-skill/SKILL.md >/dev/null 2>&1; then
  pass "apply untracks the linked and derived paths"
else
  failcase "apply untracks the linked and derived paths" "tracked but ignored: $(printf '%s' "$stale_index" | head -3 | tr '\n' ' ') (or the own skill was untracked)"
fi
if [ -f "$FIX/scripts/dashboard.py" ] && ! [ -L "$FIX/scripts/dashboard.py" ] &&
   grep -q "project VERDICT tuning" "$FIX/scripts/dashboard.py" 2>/dev/null &&
   grep -q "name.*scripts/dashboard\.py" "$TMP/apply.log" 2>/dev/null; then
  pass "apply keeps and names the edited script"
else
  failcase "apply keeps and names the edited script" "script gone, reverted, or unnamed"
fi
if [ -f "$FIX/.claude/skills/own-skill/SKILL.md" ]; then
  pass "apply keeps the own skill"
else
  failcase "apply keeps the own skill" "own skill removed"
fi
stub_miss=""
for stub in AGENTS.md opencode.json .codex/hooks.json scripts/hooks/commit-msg scripts/hooks/pre-commit; do
  cmp -s "$REPO/template/stubs/$stub" "$FIX/$stub" || stub_miss="$stub_miss $stub"
done
[ -x "$FIX/scripts/h" ] || stub_miss="$stub_miss scripts/h(not executable)"
grep -q "scripts/h session" "$FIX/.claude/settings.json" 2>/dev/null || stub_miss="$stub_miss .claude/settings.json(no session hook)"
if ! grep -qF 'scripts/hooks/pre-commit' "$FIX/.beads/hooks/pre-commit" 2>/dev/null; then
  stub_miss="$stub_miss .beads/hooks/pre-commit(no pre-commit delegate)"
fi
if [ -z "$stub_miss" ]; then
  pass "apply writes the reference stubs"
else
  failcase "apply writes the reference stubs" "not the stub:$stub_miss"
fi
if [ -L "$FIX/.claude/skills/beads" ] || [ -L "$FIX/.claude/skills/orchestrate" ]; then
  pass "apply links the shared skills"
else
  failcase "apply links the shared skills" "no shared skill link after apply"
fi
if grep -qxF '.codex/agents/' "$FIX/.gitignore" 2>/dev/null; then
  pass "apply gitignores the derived codex agents"
else
  failcase "apply gitignores the derived codex agents" ".codex/agents/ not ignored"
fi

# --- a second --apply changes nothing ---
if ! (cd "$FIX" && git add -A >/dev/null 2>&1 && git -c commit.gpgsign=false commit -m "migrate $BID" >/dev/null 2>&1); then
  echo "FAIL setup: cannot commit the migration"
  exit 1
fi
if ! "$REPO/bin/harness" migrate --apply "$FIX" >"$TMP/apply2.log" 2>&1; then
  failcase "second apply changes nothing" "non-zero exit on a converted tree"
elif [ -n "$(git -C "$FIX" status --porcelain)" ]; then
  failcase "second apply changes nothing" "the tree is dirty after a second apply"
else
  pass "second apply changes nothing"
fi

# --- the gate passes on the converted tree ---
if "$FIX/scripts/h" verify >"$TMP/verify.log" 2>&1; then
  pass "h verify passes afterwards"
else
  failcase "h verify passes afterwards" "non-zero exit: $(grep -m1 -E '^\s*(FAIL|!|✗)' "$TMP/verify.log" 2>/dev/null || tail -1 "$TMP/verify.log" 2>/dev/null)"
fi

# --- a commit on the converted tree refreshes the export without a regen ---
# The pre-commit wiring migrate installed is the live path here: the
# fixture's core.hooksPath points at .beads/hooks, the file migrate appended
# to. Filing a bead dirties the export past the committed one; the commit
# itself must carry the fresh export.
if ! BID2="$(cd "$FIX" && bd create "post-migrate probe" --design "d" --acceptance "a" --silent 2>"$TMP/bead2.err")"; then
  failcase "a commit refreshes the export on the converted tree" "cannot file a probe bead: $(head -1 "$TMP/bead2.err" 2>/dev/null)"
else
  tries=0
  while ! (cd "$FIX" && bd show "$BID2" >/dev/null 2>&1); do
    tries=$((tries + 1))
    [ "$tries" -ge 15 ] && break
    sleep 2
  done
  echo "post-migrate source" > "$FIX/probe-refresh.txt" || { echo "FAIL setup: cannot dirty a probe file"; exit 1; }
  if ! (cd "$FIX" && git add -A >/dev/null 2>&1 && git -c commit.gpgsign=false commit -m "post-migrate refresh $BID" >/dev/null 2>&1); then
    failcase "a commit refreshes the export on the converted tree" "commit failed"
  elif ! (cd "$FIX" && git show HEAD:.beads/issues.jsonl >"$TMP/converted-committed.jsonl" 2>/dev/null); then
    failcase "a commit refreshes the export on the converted tree" "the commit carries no ledger export"
  elif ! grep -qF "$BID2" "$TMP/converted-committed.jsonl"; then
    failcase "a commit refreshes the export on the converted tree" "the committed export missed the probe bead"
  elif ! cmp -s "$TMP/converted-committed.jsonl" "$FIX/.beads/issues.jsonl"; then
    failcase "a commit refreshes the export on the converted tree" "the hook left the worktree export dirty"
  else
    pass "a commit refreshes the export on the converted tree"
  fi
fi

# --- the shared checkout is untouched ---
if [ "$(shared_hash)" = "$SHARED_BEFORE" ]; then
  pass "template untouched"
else
  failcase "template untouched" "template/ changed during the probe"
fi

# --- the new files parse ---
if bash -n "$REPO/commands/migrate.sh" && bash -n "$REPO/commands/lib/migrate.sh"; then
  pass "owned files parse"
else
  failcase "owned files parse" "bash -n failed"
fi

if [ "$FAILS" -eq 0 ]; then
  exit 0
else
  exit 1
fi
