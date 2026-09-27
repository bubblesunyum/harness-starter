#!/bin/bash
# The gate: build, test, and smoke the app behind a single exit code, so an
# agent can prove its own work without a human reading a screen.
#
#   scripts/verify.sh           # build + tests
#   scripts/verify.sh --full    # + slower checks and any smoke test
#   scripts/verify.sh --quick   # build only
#
# Output is deliberately tiny. A build tool prints tens of thousands of lines
# and an agent that pipes that into its context has spent a chunk of the day's
# tokens to learn one bit — did it pass. Full logs land in /tmp/<prefix>-verify/
# (the ledger's bead prefix, resolved below) and are worth reading only when
# something fails.
#
# ── FILL THIS IN ──────────────────────────────────────────────────────────
# Everything outside the PROJECT STEPS block below is harness scaffolding and
# works as-is. Replace the steps with your project's real build and test
# commands. Keep them going through `step`, which swallows the log and reports
# one line — that is the whole point of the gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The ledger's bead prefix, asked of the ledger itself at runtime — baked into
# this file once per install, which made every copy differ and un-updatable.
# Falls back to the directory name, derived the same way `harness add` does.
_harness_prefix() {
  local p=""
  if command -v bd >/dev/null 2>&1; then
    p="$(bd config get issue_prefix 2>/dev/null | tr -d '[:space:]')" || true
  fi
  if ! printf '%s' "$p" | grep -qE '^[a-z0-9]{1,10}$'; then
    # Physical path, matching what `harness add` derived at install time and what
    # the Python scripts resolve: through a symlink the logical name could be
    # anything, and two scripts deriving different fallbacks disagree.
    p="$(basename "$(cd "$ROOT" && pwd -P)" | tr 'A-Z' 'a-z' | tr -cd '[:alnum:]' | sed 's/^[0-9]*//' | cut -c1-3)"
    [ -n "$p" ] || p="bd"
  fi
  printf '%s\n' "$p"
}
LOGS=/tmp/$(_harness_prefix)-verify
mkdir -p "$LOGS"

mode="${1:---default}"
failed=0
started=$SECONDS

# Everything interesting in a build log is on a line saying "error:" — the rest
# is compile invocations. Keep the first few, deduplicated, and say where the
# whole thing is. Widen the pattern if your toolchain words failures differently.
report() {
  local name="$1" log="$2" status="$3"
  if [ "$status" -eq 0 ]; then
    echo "  ok    $name"
  else
    failed=1
    echo "  FAIL  $name"
    grep -E "(error|failed):" "$log" | sed -e 's/^/        /' | sort -u | head -8
    echo "        full log: $log"
  fi
}

step() {
  local name="$1"; shift
  local log="$LOGS/${name// /-}.log"
  "$@" > "$log" 2>&1
  local status=$?
  # The exit code alongside the log, so readers need not guess the verdict
  # from the text: a passing step often logs nothing at all.
  echo "$status" > "$log.status"
  report "$name" "$log" $status
}

echo "verify: $ROOT"

step "codex support" python3 scripts/codex-support.py check
step "codex regression" python3 scripts/test-codex-support.py

# The knowledge layer gets the same treatment as the code. A doc that quietly
# stopped being true is worse than a missing one, and it can't be caught by
# reviewing a diff — the stale file isn't in the diff, the thing it describes is.
# Runs first because it takes a second and needs no build.
if context_out="$(scripts/context.py check 2>&1)"; then
  echo "$context_out"
else
  failed=1
  echo "$context_out"
fi

# The reviewers exist twice — .claude/agents/ for Claude Code, .opencode/agent/
# generated from it — and the generated half drifts silently, because nothing
# about editing the source makes opencode complain. Checked rather than
# regenerated: a gate that quietly fixed this would pass every time and never
# say the two had parted company.
if agents_out="$(scripts/opencode-agents.py check 2>&1)"; then
  echo "$agents_out"
else
  failed=1
  echo "$agents_out"
fi

# ── PROJECT STEPS ─────────────────────────────────────────────────────────
# There is no compiler here, so the gate is what a compiler would have caught:
# every script parses, and the CLI can still list its own commands. Cheap enough
# that there's no excuse for skipping it.

step "codex install context" python3 scripts/test-codex-install.py

step "shell parses" bash -c '
  set -e
  for f in bin/harness commands/*.sh commands/lib/*.sh scripts/*.sh scripts/hooks/* \
           template/scripts/*.sh template/scripts/hooks/*; do
    [ -f "$f" ] || continue
    bash -n "$f" || { echo "error: $f"; exit 1; }
  done'

step "python parses" bash -c '
  set -e
  for f in scripts/*.py template/scripts/*.py; do
    [ -f "$f" ] || continue
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$f" \
      || { echo "error: $f"; exit 1; }
  done'

# A throwaway repo for the probe steps below: `fresh_probe || exit 1`, then
# use $probe. Called bare, never captured — inside $(...) the EXIT trap would
# belong to the subshell and reap the probe before the caller runs. Exported
# because each step runs in its own `bash -c` child that otherwise can't see it.
fresh_probe() {
  probe="$(mktemp -d)" || { echo "error: mktemp failed"; return 1; }
  trap 'rm -rf "$probe"' EXIT
  git init -q "$probe" || { echo "error: git init failed in $probe"; return 1; }
}
export -f fresh_probe

# A template file that still says {{PROJECT}} after substitution is one the
# installer missed — and the placeholder only shows up at the far end, in an
# installed project, long after anyone would connect it to this change.
step "placeholders substitute" bash -c '
  # Each step checked on its own. An && chain here reports ok when its own setup
  # failed: probe would be empty, the install would never run, grep would find
  # nothing to complain about, and the gate would pass vacuously — which is the
  # silent success this project exists to avoid, in the check meant to catch it.
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  [ -f "$probe/scripts/brief.sh" ] || { echo "error: install produced no scripts/"; exit 1; }
  left=$(grep -rl "{{" "$probe" --include="*.sh" --include="*.py" --include="*.md" \
                --include="*.html" --include="*.json" 2>/dev/null || true)
  [ -z "$left" ] || { echo "error: placeholders survived in: $left"; exit 1; }
  # The template itself, not just what it installs: files now ship byte-for-byte
  # with no substitution step, so a placeholder typed into template/ would sail
  # straight through the installer verbatim. Vendor assets are third-party code
  # that was never substituted, so they are out of scope for this.
  tleft=$(grep -rl "{{PROJECT}}\|{{PREFIX}}" template/ --include="*.sh" --include="*.py" \
                --include="*.md" --include="*.html" --include="*.json" \
                --exclude-dir=vendor 2>/dev/null || true)
  [ -z "$tleft" ] || { echo "error: placeholders in template/: $tleft"; exit 1; }'

# A fresh install has to come out clean, or the drift warning cries wolf on every
# project that ever ran `harness add` — and a warning nobody believes is worse
# than no warning. This caught it once already: the installer's own post-copy
# edits to AGENTS.md and .claude/settings.json read as drift until the comparison
# learned to normalise them away.
step "a fresh install reads as current" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  out=$(bin/harness update "$probe" 2>&1) || {
    echo "error: update called a fresh install stale"; echo "$out"; exit 1; }'

# An edited reviewer-design.md reads as customised, not contract-stale: the
# template asks the project to name its look there, so a filled-in file is the
# harness working. Asserted through the exit code, which is the part a project
# would act on.
step "an edited design file reads as customised" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  [ -f "$probe/.claude/agents/reviewer-design.md" ] || { echo "error: install produced no design file"; exit 1; }
  echo "# the app looks like this" >> "$probe/.claude/agents/reviewer-design.md" ||
    { echo "error: cannot customise the design file"; exit 1; }
  out=$(bin/harness update "$probe" 2>&1) || {
    echo "error: update called a customised file stale"; echo "$out"; exit 1; }
  echo "$out" | grep -q "customised" ||
    { echo "error: update never said customised"; echo "$out"; exit 1; }'

# `update --apply` converges a stale contract file back to the template and
# leaves customised files alone. Asserted by re-running update, which is the
# same check a project sees.
step "update --apply converges contract files" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  [ -f "$probe/.claude/skills/workflow/SKILL.md" ] || { echo "error: install produced no workflow skill"; exit 1; }
  echo "# local note" >> "$probe/.claude/skills/workflow/SKILL.md" ||
    { echo "error: cannot dirty a contract file"; exit 1; }
  echo "# our look" >> "$probe/.claude/agents/reviewer-design.md" ||
    { echo "error: cannot customise the design file"; exit 1; }
  out=$(bin/harness update --apply "$probe" 2>&1) ||
    { echo "error: update --apply failed"; echo "$out"; exit 1; }
  echo "$out" | grep -q "applied" ||
    { echo "error: apply never said it applied"; echo "$out"; exit 1; }
  grep -q "our look" "$probe/.claude/agents/reviewer-design.md" ||
    { echo "error: apply touched a customised file"; exit 1; }
  out=$(bin/harness update "$probe" 2>&1) || {
    echo "error: update still stale after apply"; echo "$out"; exit 1; }'

# A contract file carrying bd's managed block plus real drift is left for a
# hand merge: the template has no copy of that block, so overwriting would
# delete it. The block survives and the file stays stale, loudly.
step "update --apply keeps off files with a beads block" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  [ -f "$probe/AGENTS.md" ] || { echo "error: install produced no AGENTS.md"; exit 1; }
  printf "\n<!-- BEGIN BEADS -->\nmanaged\n<!-- END BEADS -->\n# real drift\n" >> "$probe/AGENTS.md" ||
    { echo "error: cannot dirty AGENTS.md"; exit 1; }
  out=$(bin/harness update --apply "$probe" 2>&1) &&
    { echo "error: apply claimed success with a blocked file stale"; echo "$out"; exit 1; }
  grep -q "BEGIN BEADS" "$probe/AGENTS.md" ||
    { echo "error: apply deleted the beads block"; exit 1; }
  echo "$out" | grep -q "Merge by hand" ||
    { echo "error: apply never said whose job it is"; echo "$out"; exit 1; }'

# A stale contract reviewer source comes with its follow-ups: the merge is half
# the job, and the generated copies, the hashes, and the gate are the other
# half. librarian.md is the contract agent — the named reviewers are customised.
step "update names follow-ups for reviewer sources" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  [ -f "$probe/.claude/agents/librarian.md" ] || { echo "error: install produced no librarian file"; exit 1; }
  echo "# local note" >> "$probe/.claude/agents/librarian.md" ||
    { echo "error: cannot dirty an agent source"; exit 1; }
  out=$(bin/harness update "$probe" 2>&1 || true)
  echo "$out" | grep -q "codex-support.py write" ||
    { echo "error: no follow-ups for reviewer sources"; echo "$out"; exit 1; }
  echo "$out" | grep -q "context.py bless" ||
    { echo "error: follow-ups never mention bless"; echo "$out"; exit 1; }'

# A customised-only difference points at the generated-copy checks instead of
# ordering a rebuild — that order would nag on every install that ever filled
# its reviewers in.
step "update points customised sources at the copy checks" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  [ -f "$probe/.claude/agents/reviewer-taste.md" ] || { echo "error: install produced no taste file"; exit 1; }
  echo "# local note" >> "$probe/.claude/agents/reviewer-taste.md" ||
    { echo "error: cannot dirty an agent source"; exit 1; }
  out=$(bin/harness update "$probe" 2>&1 || true)
  echo "$out" | grep -q "kept up" ||
    { echo "error: no copy-check pointer for customised sources"; echo "$out"; exit 1; }
  if echo "$out" | grep -q "context.py bless"; then
    echo "error: rebuild order nagging on a customised-only diff"; echo "$out"; exit 1;
  fi'

# An acknowledged fork stops failing the check but stays visible: the warning
# nobody can clear is the one that stops being read. --apply never writes it.
step "update respects acknowledged forks" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  [ -f "$probe/scripts/review.sh" ] || { echo "error: install produced no review file"; exit 1; }
  root="$PWD"
  echo "# local fork" >> "$probe/scripts/review.sh" ||
    { echo "error: cannot fork a contract file"; exit 1; }
  bin/harness update "$probe" >/dev/null 2>&1 &&
    { echo "error: update passed a forked contract file"; exit 1; }
  (cd "$probe" && "$root/bin/harness" diverge scripts/review.sh >/dev/null 2>&1) ||
    { echo "error: harness diverge refused a real fork"; exit 1; }
  out=$(bin/harness update "$probe" 2>&1) || {
    echo "error: update still stale after diverge"; echo "$out"; exit 1; }
  echo "$out" | grep -q "diverged" ||
    { echo "error: update never said diverged"; echo "$out"; exit 1; }
  out=$(bin/harness update --apply "$probe" 2>&1) || {
    echo "error: apply failed on an acknowledged fork"; echo "$out"; exit 1; }
  grep -q "local fork" "$probe/scripts/review.sh" ||
    { echo "error: apply wrote an acknowledged fork"; exit 1; }'

# Stack guidance reaches only the projects that use the stack: a Swift probe
# gets swift.md and not web.md, a bare one gets neither, and each reads as
# current. Guidance for someone else's platform is the failure this prevents.
step "stack guidance installs only where detected" bash -c '
  fresh_probe || exit 1
  touch "$probe/Package.swift" || { echo "error: cannot mark the probe as swift"; exit 1; }
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  grep -qx swift "$probe/harness/stacks.txt" ||
    { echo "error: stacks.txt never recorded swift"; exit 1; }
  [ -f "$probe/harness/stacks/swift.md" ] || { echo "error: no swift guidance installed"; exit 1; }
  [ ! -e "$probe/harness/stacks/web.md" ] || { echo "error: web guidance installed into a swift project"; exit 1; }
  out=$(bin/harness update "$probe" 2>&1) || {
    echo "error: update called a fresh stack install stale"; echo "$out"; exit 1; }
  bare="$(mktemp -d)" && git init -q "$bare" || { echo "error: cannot make a bare probe"; exit 1; }
  bin/harness add "$bare" >/dev/null 2>&1 || { echo "error: harness add failed on a bare probe"; rm -rf "$bare"; exit 1; }
  [ -f "$bare/harness/stacks.txt" ] && [ ! -e "$bare/harness/stacks" ] ||
    { echo "error: a project with no stack got stack guidance, or no stacks.txt"; rm -rf "$bare"; exit 1; }
  rm -rf "$bare"'

# stacks.txt is the project's once written: a re-run of add installs what an
# edit added and never re-detects over it — or a wrong guess could never be
# corrected for good.
step "an edited stacks.txt survives a re-add" bash -c '
  fresh_probe || exit 1
  touch "$probe/Package.swift" || { echo "error: cannot mark the probe as swift"; exit 1; }
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  printf "web\n" > "$probe/harness/stacks.txt" || { echo "error: cannot edit stacks.txt"; exit 1; }
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: re-add failed"; exit 1; }
  [ "$(grep -v "^#" "$probe/harness/stacks.txt")" = "web" ] ||
    { echo "error: re-add rewrote stacks.txt"; exit 1; }
  [ -f "$probe/harness/stacks/web.md" ] || { echo "error: re-add never installed the added stack"; exit 1; }'

# A stack name with no guidance behind it, or an install from before stacks
# existed, fails update loudly — either way reviewers are missing checks and
# nothing else would say so.
step "update fails loudly on unknown or unrecorded stacks" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  # Web: a case-insensitive disk finds web.md for it, yet nothing installs.
  printf "cobol\nWeb\n" >> "$probe/harness/stacks.txt" || { echo "error: cannot edit stacks.txt"; exit 1; }
  out=$(bin/harness update "$probe" 2>&1) &&
    { echo "error: update passed an unknown stack"; echo "$out"; exit 1; }
  echo "$out" | grep -q "no guidance for" && echo "$out" | grep -qx "  Web" ||
    { echo "error: update never named every unknown stack"; echo "$out"; exit 1; }
  rm "$probe/harness/stacks.txt" || { echo "error: cannot remove stacks.txt"; exit 1; }
  out=$(bin/harness update "$probe" 2>&1) &&
    { echo "error: update passed an install with no stacks.txt"; echo "$out"; exit 1; }
  echo "$out" | grep -q "stacks.txt missing" ||
    { echo "error: update never said stacks.txt is missing"; echo "$out"; exit 1; }'

# A diverged entry that acknowledges nothing — typo, removed file, or one
# already quiet — fails loudly: the list is harness configuration, and a typo
# there silently un-acknowledges the fork it meant.
step "update fails loudly on diverged entries that acknowledge nothing" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  echo "nope/nothing.py" >> "$probe/harness/diverged.txt" ||
    { echo "error: cannot write the diverged list"; exit 1; }
  out=$(bin/harness update "$probe" 2>&1) &&
    { echo "error: update passed a bogus diverged entry"; echo "$out"; exit 1; }
  echo "$out" | grep -q "acknowledge nothing" ||
    { echo "error: update never said whose fault it is"; echo "$out"; exit 1; }'

# An unreadable diverged list fails loudly rather than reading as empty: empty
# would silently un-acknowledge every fork, which is the false alarm the list
# exists to prevent.
step "update fails loudly on an unreadable diverged list" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  chmod 000 "$probe/harness/diverged.txt" ||
    { echo "error: cannot make the diverged list unreadable"; exit 1; }
  out=$(bin/harness update "$probe" 2>&1) &&
    { echo "error: update passed an unreadable diverged list"; echo "$out"; exit 1; }
  echo "$out" | grep -q "not readable" ||
    { echo "error: update never said the list is unreadable"; echo "$out"; exit 1; }
  chmod 644 "$probe/harness/diverged.txt" || exit 1;'

# `harness diverge` validates before writing: only a real, differing contract
# file lands in the list. Asserted through the exit code and the list itself.
step "harness diverge validates before acknowledging" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  root="$PWD"
  (cd "$probe" && "$root/bin/harness" diverge scripts/review.sh >/dev/null 2>&1) &&
    { echo "error: diverge acknowledged a current file"; exit 1; }
  echo "# local fork" >> "$probe/scripts/review.sh" ||
    { echo "error: cannot fork a contract file"; exit 1; }
  (cd "$probe" && "$root/bin/harness" diverge scripts/review.sh harness/seat.md nope >/dev/null 2>&1) &&
    { echo "error: diverge passed bad files"; exit 1; }
  grep -qxF "scripts/review.sh" "$probe/harness/diverged.txt" ||
    { echo "error: diverge never recorded the fork"; exit 1; }'

# A role's packet budget is its explicit "context", else a heuristic from the
# model id — Claude-pattern ids read as 200000, anything else as 8192 — and an
# unconfigured role has no budget at all rather than a guessed one.
step "models.py budget resolves explicit, pattern, and default budgets" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  cat > "$probe/harness/models.json" <<EOF ||
{"reviewer-taste": {"model": "ollama/qwen3:27b", "context": 12345},
 "reviewer-correctness": "opencode/anthropic/claude-opus-5-5",
 "reviewer-design": {"model": "ollama/qwen3:27b"}}
EOF
    { echo "error: cannot write test roster"; exit 1; }
  [ "$(python3 "$probe/scripts/models.py" budget reviewer-taste)" = "12345" ] ||
    { echo "error: explicit context not honored"; exit 1; }
  [ "$(python3 "$probe/scripts/models.py" budget reviewer-correctness)" = "200000" ] ||
    { echo "error: claude pattern not 200k"; exit 1; }
  [ "$(python3 "$probe/scripts/models.py" budget reviewer-design)" = "8192" ] ||
    { echo "error: default not conservative"; exit 1; }
  # if-form, not trailing &&: a failed && as the last line exits the step 1.
  if python3 "$probe/scripts/models.py" budget nobody >/dev/null 2>&1; then
    echo "error: budget passed for an unconfigured role"; exit 1;
  fi'

# An over-budget packet refuses with the binding role and the narrower command
# — a truncated packet reporting confidently on its first pages is the failure.
step "review.sh refuses a packet over the smallest reviewer budget" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  cat > "$probe/harness/models.json" <<EOF ||
{"reviewer-taste": {"model": "ollama/qwen3:27b", "context": 100},
 "reviewer-correctness": {"model": "ollama/qwen3:27b", "context": 100},
 "reviewer-design": {"model": "ollama/qwen3:27b", "context": 100}}
EOF
    { echo "error: cannot write test roster"; exit 1; }
  echo "# change" >> "$probe/scripts/brief.sh" ||
    { echo "error: cannot dirty a tracked file"; exit 1; }
  out=$(bash "$probe/scripts/review.sh" 2>&1) &&
    { echo "error: review passed an over-budget packet"; echo "$out"; exit 1; }
  echo "$out" | grep -q "reviewer-taste" ||
    { echo "error: refusal never named the binding role"; echo "$out"; exit 1; }
  echo "$out" | grep -q "scripts/review.sh <commit>" ||
    { echo "error: refusal never said how to narrow"; echo "$out"; exit 1; }'

# A packet within budget still prints its path — the refusal must not fire on
# ordinary changes.
step "review.sh passes a packet within budget" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  cat > "$probe/harness/models.json" <<EOF ||
{"reviewer-taste": {"model": "ollama/qwen3:27b", "context": 1000000},
 "reviewer-correctness": {"model": "ollama/qwen3:27b", "context": 1000000},
 "reviewer-design": {"model": "ollama/qwen3:27b", "context": 1000000}}
EOF
    { echo "error: cannot write test roster"; exit 1; }
  echo "# change" >> "$probe/scripts/brief.sh" ||
    { echo "error: cannot dirty a tracked file"; exit 1; }
  out=$(bash "$probe/scripts/review.sh" 2>&1) || {
    echo "error: review refused a fitting packet"; echo "$out"; exit 1; }
  echo "$out" | grep -q "review-packet" ||
    { echo "error: review never printed the packet"; echo "$out"; exit 1; }'

# `harness add` owns the git dependency: a fresh directory gets a repository
# rather than an error, and says so in its own voice.
step "add initialises a missing git repository" bash -c '
  probe=$(mktemp -d) || { echo "error: mktemp failed"; exit 1; }
  trap "rm -rf \"$probe\"" EXIT
  out=$(bin/harness add "$probe" 2>&1) || { echo "error: harness add failed"; echo "$out"; exit 1; }
  [ -d "$probe/.git" ] || { echo "error: no .git after add"; exit 1; }
  echo "$out" | grep -q "initialised a git repository" ||
    { echo "error: add never said it initialised one"; echo "$out"; exit 1; }'

# But never a nested one: inside another repository it refuses, naming the
# parent, rather than leaving a repository inside a repository. Asserted on the
# parent path itself — the target path contains it, so matching the target
# would pass even a refusal that named nothing.
step "add refuses a subdirectory of a repository" bash -c '
  fresh_probe || exit 1
  mkdir "$probe/sub" || { echo "error: mkdir failed"; exit 1; }
  parent="$(cd "$probe" && pwd -P)" || { echo "error: pwd failed"; exit 1; }
  out=$(bin/harness add "$probe/sub" 2>&1) &&
    { echo "error: add succeeded inside a repository"; echo "$out"; exit 1; }
  [ -d "$probe/sub/.git" ] && { echo "error: add created a nested .git"; exit 1; }
  echo "$out" | grep -qF "at $parent" ||
    { echo "error: the refusal never named the parent"; echo "$out"; exit 1; }'

# A .git entry git itself rejects — half a `git init`, a stray file — refuses
# rather than installing a harness onto a repository that doesn't work.
step "add refuses a broken .git entry" bash -c '
  probe=$(mktemp -d) || { echo "error: mktemp failed"; exit 1; }
  trap "rm -rf \"$probe\"" EXIT
  mkdir "$probe/.git" || { echo "error: mkdir failed"; exit 1; }
  out=$(bin/harness add "$probe" 2>&1) &&
    { echo "error: add succeeded over a broken .git"; echo "$out"; exit 1; }
  if [ -e "$probe/AGENTS.md" ]; then
    echo "error: add installed files into a broken repository"; exit 1;
  fi'

# A bare repository has no working tree to install into: refuse, and leave it
# alone. `rev-parse --show-toplevel` fails there, so without this the install
# would sail past the nesting guard and git init a .git inside the bare repo.
step "add refuses a bare repository" bash -c '
  probe=$(mktemp -d) || { echo "error: mktemp failed"; exit 1; }
  trap "rm -rf \"$probe\"" EXIT
  git init -q --bare "$probe/b.git" || { echo "error: git init --bare failed"; exit 1; }
  out=$(bin/harness add "$probe/b.git" 2>&1) &&
    { echo "error: add succeeded in a bare repository"; echo "$out"; exit 1; }
  if [ -e "$probe/b.git/.git" ]; then
    echo "error: add wrote a .git into a bare repo"; exit 1;
  fi'

# A linked worktree is a repository already — .git is a file, not a directory —
# so it installs rather than refusing with the directory as its own parent.
step "add accepts a linked worktree" bash -c '
  fresh_probe || exit 1
  trap '"'"'rm -rf "$probe" "$probe-wt"'"'"' EXIT
  (cd "$probe" && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m init) ||
    { echo "error: empty commit failed"; exit 1; }
  git -C "$probe" worktree add -q "$probe-wt" 2>&1 ||
    { echo "error: worktree add failed"; exit 1; }
  out=$(bin/harness add "$probe-wt" 2>&1) || { echo "error: harness add failed"; echo "$out"; exit 1; }
  if echo "$out" | grep -q "initialised a git repository"; then
    echo "error: add claimed to initialise a worktree"; echo "$out"; exit 1;
  fi'

if [ "$mode" != "--quick" ]; then
  step "cli lists commands" bash -c 'bin/harness | grep -q "^  add"'
fi

# ── END PROJECT STEPS ─────────────────────────────────────────────────────

# What the gate proved, as a git tree. Comparing a commit's timestamp against the
# gate's can only ever say "you committed after you verified", which is the
# order the loop prescribes — so it marked every fresh commit unverified. The
# tree says the thing actually worth knowing: whether the content in that commit
# is the content the gate ran against.
if [ "$failed" -eq 0 ]; then
  idx="$LOGS/index"
  rm -f "$idx"
  GIT_INDEX_FILE="$idx" git read-tree HEAD 2>/dev/null &&
    GIT_INDEX_FILE="$idx" git add -A 2>/dev/null &&
    GIT_INDEX_FILE="$idx" git write-tree 2>/dev/null > "$LOGS/tree"
  rm -f "$idx"
fi

# How long the gate takes is worth watching: it's the tax on every change, and
# when it grows past the patience of whoever's waiting, it stops getting run.
echo $((SECONDS - started)) > "$LOGS/elapsed"

[ "$failed" -eq 0 ] && echo "verify: passed" || echo "verify: FAILED"
exit "$failed"
