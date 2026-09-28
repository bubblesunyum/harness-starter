# Your project's gate steps: build, test, smoke — whatever proves the work.
# Sourced by scripts/verify.sh, which defines `step`, `mode`, `LOGS`, and the
# pass/fail footer around this file, so use those rather than redefining them.
#
# This file is yours. The harness installs it once and never compares or
# overwrites it — `harness update` stays silent about it, and scaffolding fixes
# still arrive in scripts/verify.sh. Keep every check going through `step
# <name> <cmd...>`: it swallows the log and prints one line, which is the whole
# point of the gate.

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

# The roster is machine-local and gitignored, so generated agents must not
# carry it: a model line baked in here passes check on this machine and fails
# it on every fresh clone. Asserted both ways — a populated roster leaks
# nothing into the output, and check passes with the roster removed.
step "generated opencode agents ignore the roster" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  cat > "$probe/harness/models.json" <<EOF ||
{"reviewer-taste": {"model": "some-provider/some-model", "context": 12345},
 "reviewer-correctness": "other-provider/other-model",
 "reviewer-design": {"model": "third-provider/third-model"},
 "librarian": "fourth-provider/fourth-model"}
EOF
    { echo "error: cannot write test roster"; exit 1; }
  (cd "$probe" && ./scripts/opencode-agents.py >/dev/null 2>&1) ||
    { echo "error: generate failed with a populated roster"; exit 1; }
  if grep -H "^model:\|^variant:" "$probe"/.opencode/agent/*.md; then
    echo "error: roster leaked into generated agents — a fresh clone fails check"; exit 1;
  fi
  (cd "$probe" && ./scripts/opencode-agents.py check >/dev/null 2>&1) ||
    { echo "error: check failed with a populated roster"; exit 1; }
  rm "$probe/harness/models.json" ||
    { echo "error: cannot remove test roster"; exit 1; }
  (cd "$probe" && ./scripts/opencode-agents.py check >/dev/null 2>&1) ||
    { echo "error: check failed with no roster — the fresh-clone case"; exit 1; }'

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

# The starter eats its own dogfood: its working tree reads as current against
# its own template. A stale contract file here means the split already slipped —
# a base edited in one place, or an overlay the update started comparing.
step "the starter reads as current" bash -c '
  out=$(bin/harness update 2>&1) || { echo "error: the starter is stale against its own template"; echo "$out"; exit 1; }'

# The split sticks only while the base files stay identical. This is the
# enforcement: a base edited in the root copy instead of the template fails the
# gate, rather than drifting quietly until update calls every install stale.
step "contract scripts match the template byte for byte" bash -c '
  cmp -s template/scripts/verify.sh scripts/verify.sh ||
    { echo "error: scripts/verify.sh differs from its template — change the template, not the copy"; exit 1; }
  cmp -s template/scripts/review.sh scripts/review.sh ||
    { echo "error: scripts/review.sh differs from its template — change the template, not the copy"; exit 1; }'

# Overlay files are the project's to edit, so an edited one must read as
# current, not stale — a warning nobody can clear is the one that stops being
# read, and then the real drift hides behind it.
step "overlay edits stay quiet under update" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  echo "# local steps" >> "$probe/scripts/verify.steps.sh" ||
    { echo "error: cannot edit the steps file"; exit 1; }
  echo "# local scope" >> "$probe/scripts/review.scope.sh" ||
    { echo "error: cannot edit the scope file"; exit 1; }
  out=$(bin/harness update "$probe" 2>&1) ||
    { echo "error: update failed on overlay edits"; echo "$out"; exit 1; }
  if echo "$out" | grep -q "verify.steps.sh\|review.scope.sh"; then
    echo "error: update named an overlay file"; echo "$out"; exit 1;
  fi'

# The scope file is wired in, not decorative: a review that ignored it would
# keep reading the old inline scope, and the packet would carry files the
# project excluded — silently unreviewable in the other direction.
step "review honors the scope overlay" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  # --no-verify: the probe commit is scaffolding in a throwaway repo, and add
  # wired the bead-naming hook here. Its message names nothing real.
  (cd "$probe" && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false add -A &&
    git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit --no-verify -qm init) ||
    { echo "error: probe commit failed"; exit 1; }
  echo "scoped" >> "$probe/scoped.md" || { echo "error: cannot dirty a tracked doc"; exit 1; }
  echo "scoped" >> "$probe/scoped.py" || { echo "error: cannot dirty a tracked source"; exit 1; }
  { printf "%s\n" "SCOPE=(\"*.py\")" "CAPTURES=\"no-captures-here-*.png\"" > "$probe/scripts/review.scope.sh"; } ||
    { echo "error: cannot narrow the scope file"; exit 1; }
  out=$(bash "$probe/scripts/review.sh" </dev/null 2>&1) ||
    { echo "error: review failed"; echo "$out"; exit 1; }
  packet=$(printf "%s" "$out" | grep -o "/tmp/[^ )]*" | head -1)
  [ -n "$packet" ] || { echo "error: review never printed the packet"; echo "$out"; exit 1; }
  grep -q "scoped.py" "$packet" || { echo "error: packet missed an in-scope file"; exit 1; }
  if grep -q "scoped.md" "$packet"; then
    echo "error: packet carried an out-of-scope file"; exit 1;
  fi'

# A gate with no project steps must not pass: "ok" from a suite that ran
# nothing is the silent success this project exists to avoid, in the check
# meant to catch it.
step "a missing steps overlay fails the gate loudly" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  rm "$probe/scripts/verify.steps.sh" || { echo "error: cannot remove the steps file"; exit 1; }
  out=$(bash "$probe/scripts/verify.sh" --quick 2>&1) &&
    { echo "error: the gate passed with no project steps"; echo "$out"; exit 1; }
  echo "$out" | grep -q "verify.steps.sh" ||
    { echo "error: the failure never named the missing file"; echo "$out"; exit 1; }'

# --apply converges stale bases and leaves overlays alone: the fix arrives and
# the project's answers survive in the same run.
step "apply converges base scripts but keeps overlays" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  echo "# local fork" >> "$probe/scripts/verify.sh" || { echo "error: cannot fork the base"; exit 1; }
  echo "# local steps" >> "$probe/scripts/verify.steps.sh" || { echo "error: cannot edit the steps file"; exit 1; }
  out=$(bin/harness update --apply "$probe" 2>&1) ||
    { echo "error: update --apply failed"; echo "$out"; exit 1; }
  echo "$out" | grep -q "applied" ||
    { echo "error: apply never said it applied"; echo "$out"; exit 1; }
  grep -q "local steps" "$probe/scripts/verify.steps.sh" ||
    { echo "error: apply touched the overlay"; exit 1; }
  if grep -q "local fork" "$probe/scripts/verify.sh"; then
    echo "error: apply never converged the base"; exit 1;
  fi
  out=$(bin/harness update "$probe" 2>&1) ||
    { echo "error: update still stale after apply"; echo "$out"; exit 1; }'

# Overlays need no acknowledgment — there is nothing to fork. Accepting one
# would let a dead-weight entry sit in the diverged list looking meaningful.
step "diverge refuses overlay files" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  root="$PWD"
  # if-form, not trailing &&: a refusing diverge as the last line exits the step 1.
  if (cd "$probe" && "$root/bin/harness" diverge scripts/verify.steps.sh >/dev/null 2>&1); then
    echo "error: diverge acknowledged an overlay"; exit 1;
  fi
  if (cd "$probe" && "$root/bin/harness" diverge scripts/review.scope.sh >/dev/null 2>&1); then
    echo "error: diverge acknowledged an overlay"; exit 1;
  fi'

# The migration itself: a pre-split project recovers its inline blocks into
# overlay files on --apply, and the lifted steps actually run. Without this the
# converge above would delete answers only the project has.
step "apply lifts pre-split blocks into overlays" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  rm "$probe/scripts/verify.steps.sh" "$probe/scripts/review.scope.sh" ||
    { echo "error: cannot remove the overlays"; exit 1; }
  python3 - "$probe/scripts/verify.sh" "$probe/scripts/review.sh" <<PYEOF ||
import sys
v, r = sys.argv[1], sys.argv[2]
t = open(v).read()
start = t.index("# ── PROJECT STEPS ──")
end = t.index("# ── END PROJECT STEPS ──") + len("# ── END PROJECT STEPS ──")
open(v, "w").write(t[:start] + "# ── PROJECT STEPS ──\nstep \"legacy\" true\n# ── END PROJECT STEPS ──" + t[end:])
t = open(r).read()
start = t.index("# ── CONFIGURE ──")
end = t.index("# ── END CONFIGURE ──") + len("# ── END CONFIGURE ──")
open(r, "w").write(t[:start] + "# ── CONFIGURE ──\nSCOPE=(\"*.sh\")\nCAPTURES=\"none-*.png\"\n# ── END CONFIGURE ──" + t[end:])
PYEOF
    { echo "error: cannot write old-style scripts"; exit 1; }
  out=$(bin/harness update --apply "$probe" 2>&1) ||
    { echo "error: update --apply failed"; echo "$out"; exit 1; }
  echo "$out" | grep -q "moved this project" ||
    { echo "error: apply never said it moved the blocks"; echo "$out"; exit 1; }
  grep -q "legacy" "$probe/scripts/verify.steps.sh" ||
    { echo "error: steps never landed in the overlay"; exit 1; }
  grep -q "SCOPE=" "$probe/scripts/review.scope.sh" ||
    { echo "error: scope never landed in the overlay"; exit 1; }
  out=$(bash "$probe/scripts/verify.sh" --quick 2>&1) ||
    { echo "error: migrated gate failed"; echo "$out"; exit 1; }
  echo "$out" | grep -q "ok    legacy" ||
    { echo "error: migrated gate never ran the lifted step"; echo "$out"; exit 1; }'

# The same recovery on a re-add: the pre-pass runs before the copy loop, so the
# project's own answers win over the template's placeholders. Without this a
# re-add would install placeholder overlays beside real inline answers, and the
# next --apply would converge the base and strand them.
step "add lifts pre-split blocks before installing overlays" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  rm "$probe/scripts/verify.steps.sh" || { echo "error: cannot remove the overlay"; exit 1; }
  python3 - "$probe/scripts/verify.sh" <<PYEOF ||
import sys
v = sys.argv[1]
t = open(v).read()
start = t.index("# ── PROJECT STEPS ──")
end = t.index("# ── END PROJECT STEPS ──") + len("# ── END PROJECT STEPS ──")
open(v, "w").write(t[:start] + "# ── PROJECT STEPS ──\nstep \"kept\" true\n# ── END PROJECT STEPS ──" + t[end:])
PYEOF
    { echo "error: cannot write an old-style script"; exit 1; }
  out=$(bin/harness add "$probe" 2>&1) || { echo "error: re-add failed"; echo "$out"; exit 1; }
  echo "$out" | grep -q "moved this project" ||
    { echo "error: re-add never said it moved the block"; echo "$out"; exit 1; }
  grep -q "kept" "$probe/scripts/verify.steps.sh" ||
    { echo "error: steps never landed in the overlay"; exit 1; }
  grep -q "kept" "$probe/scripts/verify.sh" ||
    { echo "error: re-add touched the inline steps"; exit 1; }'

# A block with no end marker lifts to end-of-file — converging over that would
# delete everything after the start line. Decline instead: the file stays stale
# and says whose job it is, and no overlay is written.
step "apply leaves marker-damaged scripts stale and loud" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  rm "$probe/scripts/verify.steps.sh" || { echo "error: cannot remove the overlay"; exit 1; }
  python3 - "$probe/scripts/verify.sh" <<PYEOF ||
import sys
v = sys.argv[1]
t = open(v).read()
start = t.index("# ── PROJECT STEPS ──")
end = t.index("# ── END PROJECT STEPS ──") + len("# ── END PROJECT STEPS ──")
open(v, "w").write(t[:start] + "# ── PROJECT STEPS ──\nstep \"doomed\" true\n" + t[end:])
PYEOF
    { echo "error: cannot damage the end marker"; exit 1; }
  out=$(bin/harness update --apply "$probe" 2>&1) &&
    { echo "error: apply passed a marker-damaged script"; echo "$out"; exit 1; }
  echo "$out" | grep -q "verify.steps.sh" ||
    { echo "error: apply never named the stranded overlay"; echo "$out"; exit 1; }
  [ -e "$probe/scripts/verify.steps.sh" ] &&
    { echo "error: apply wrote an overlay from a damaged block"; exit 1; }
  grep -q "doomed" "$probe/scripts/verify.sh" ||
    { echo "error: apply converged over the stranded steps"; exit 1; }'

# Same for a duplicated block: lifting would merge both copies with markers
# inside, so it declines the same loud way.
step "apply leaves duplicated blocks stale and loud" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  rm "$probe/scripts/review.scope.sh" || { echo "error: cannot remove the overlay"; exit 1; }
  python3 - "$probe/scripts/review.sh" <<PYEOF ||
import sys
r = sys.argv[1]
t = open(r).read()
start = t.index("# ── CONFIGURE ──")
end = t.index("# ── END CONFIGURE ──") + len("# ── END CONFIGURE ──")
block = t[start:end]
open(r, "w").write(t[:start] + block + "\n" + block + t[end:])
PYEOF
    { echo "error: cannot duplicate the block"; exit 1; }
  out=$(bin/harness update --apply "$probe" 2>&1) &&
    { echo "error: apply passed a duplicated block"; echo "$out"; exit 1; }
  echo "$out" | grep -q "review.scope.sh" ||
    { echo "error: apply never named the stranded overlay"; echo "$out"; exit 1; }
  # if-form, not trailing &&: an absent overlay as the last line exits the step 1.
  if [ -e "$probe/scripts/review.scope.sh" ]; then
    echo "error: apply wrote an overlay from a duplicated block"; exit 1;
  fi'

# A stale pointer block carries no answers — lifting its comments would strand
# a step-less overlay the gate then passes vacuously. Converge the base, write
# nothing, and let `add` install the template overlay.
step "apply converges answer-less blocks without writing overlays" bash -c '
  fresh_probe || exit 1
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  rm "$probe/scripts/verify.steps.sh" || { echo "error: cannot remove the overlay"; exit 1; }
  python3 - "$probe/scripts/verify.sh" <<PYEOF ||
import sys
v = sys.argv[1]
t = open(v).read()
start = t.index("# ── PROJECT STEPS ──")
end = t.index("# ── END PROJECT STEPS ──") + len("# ── END PROJECT STEPS ──")
open(v, "w").write(t[:start] + "# ── PROJECT STEPS ──\n# an old pointer, edited since\n# ── END PROJECT STEPS ──" + t[end:])
PYEOF
    { echo "error: cannot age the pointer block"; exit 1; }
  out=$(bin/harness update --apply "$probe" 2>&1) ||
    { echo "error: update --apply failed"; echo "$out"; exit 1; }
  echo "$out" | grep -q "applied" ||
    { echo "error: apply never said it applied"; echo "$out"; exit 1; }
  [ -e "$probe/scripts/verify.steps.sh" ] &&
    { echo "error: apply wrote an overlay with no steps in it"; exit 1; }
  out=$(bin/harness update "$probe" 2>&1) ||
    { echo "error: update still stale after apply"; echo "$out"; exit 1; }'

# The committed ledger export is a fresh clone's memories: bd's plain export
# omits them, so the file has to be regenerated with --include-memories (which
# ledger-push.sh does on every push). Compared as whole memory lines in both
# directions — a remembered, edited, or deleted memory trips it, while ordinary
# issue churn never does. In Python, not grep: BSD grep -f dies past 64 KiB
# pattern lines, and a comparison that cannot read the lines passes blind.
step "the committed ledger export carries every memory" bash -c '
  [ -f .beads/issues.jsonl ] || { echo "error: no committed ledger export"; exit 1; }
  tmp="$(mktemp)" || { echo "error: mktemp failed"; exit 1; }
  trap '"'"'rm -f "$tmp"'"'"' EXIT
  bd export --include-memories -o "$tmp" >/dev/null 2>&1 ||
    { echo "error: ledger export failed"; exit 1; }
  python3 - "$tmp" .beads/issues.jsonl <<PYEOF
import sys
export_path, committed_path = sys.argv[1], sys.argv[2]
def memories(path):
    with open(path, errors="replace") as f:
        return {line for line in (l.rstrip("\n") for l in f)
                if line and "\"_type\":\"memory\"" in line}
fresh, committed = memories(export_path), memories(committed_path)
missing = sorted(fresh - committed)
gone = sorted(committed - fresh)
if missing:
    print("error: the committed export is missing memories — "
          "run scripts/ledger-push.sh to regenerate")
    print("\n".join(missing))
if gone:
    print("error: the committed export carries deleted memories — "
          "run scripts/ledger-push.sh to regenerate")
    print("\n".join(gone))
sys.exit(1 if (missing or gone) else 0)
PYEOF'

# Neither transport hydrates a fresh clone on its own: bd init with a
# configured remote starts an empty database without reading the committed
# export. So add imports it on fresh init — issues and memories both, and only
# then. Seeded here with one of each; recall proves the memories arrived.
step "a fresh install hydrates the committed ledger export" bash -c '
  fresh_probe || exit 1
  mkdir -p "$probe/.beads" || { echo "error: cannot seed the export"; exit 1; }
  printf "%s\n" "{\"_type\":\"issue\",\"id\":\"probe-1\",\"title\":\"seeded\",\"status\":\"open\"}" \
    "{\"_type\":\"memory\",\"key\":\"probe-trap\",\"value\":\"seeded knowledge\"}" \
    > "$probe/.beads/issues.jsonl" || { echo "error: cannot seed the export"; exit 1; }
  out=$(bin/harness add "$probe" 2>&1) || { echo "error: harness add failed"; echo "$out"; exit 1; }
  echo "$out" | grep -q "hydrated" ||
    { echo "error: add never said it hydrated"; echo "$out"; exit 1; }
  (cd "$probe" && bd recall probe-trap 2>&1) | grep -q "seeded knowledge" ||
    { echo "error: seeded memory never reached the fresh ledger"; exit 1; }
  (cd "$probe" && bd list 2>&1) | grep -q "seeded" ||
    { echo "error: seeded issue never reached the fresh ledger"; exit 1; }'

if [ "$mode" != "--quick" ]; then
  step "cli lists commands" bash -c 'bin/harness | grep -q "^  add"'
fi

