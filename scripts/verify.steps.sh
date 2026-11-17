# Your project's gate steps: build, test, smoke — whatever proves the work.
# Sourced by scripts/verify.sh, which defines `step`, `probe_step`, `mode`,
# `LOGS`, and the pass/fail footer around this file, so use those rather than
# redefining them.
#
# This file is yours. The harness installs it once and never compares or
# overwrites it, and scaffolding fixes still arrive in scripts/verify.sh. Keep every check going through `step
# <name> <cmd...>`: it swallows the log and prints one line, which is the whole
# point of the gate. A check too slow for every few minutes — throwaway-repo
# probes, heavy suites — goes through `probe_step` instead: same contract,
# but skipped in the --quick lane, which is what keeps iteration fast.

# The gate usually arrives through `scripts/h verify`, which exports the
# dispatch environment for the shared scripts. Every probe below builds its
# own fixture and must resolve its own project and harness, so none inherits it.
unset HARNESS_PROJECT HARNESS_ROOT HARNESS_SOURCE

# There is no compiler here, so the gate is what a compiler would have caught:
# every script parses, and the CLI can still list its own commands. Cheap enough
# that there's no excuse for skipping it.

# Reference probes resolve the harness through the finder — installs, the
# commit-msg shim, and scripts/h dispatch all go through it — so they need the
# checkout. The gate runs here, in the starter itself, hence one export rather
# than an inline assignment on every probe command.
export HARNESS_HOME="$PWD"

probe_step "codex install context" python3 scripts/test-codex-install.py
probe_step "project contract and export policy" python3 scripts/test-contract-overrides.py
probe_step "finder resolution" bash scripts/test-finder.sh
probe_step "contract split" bash scripts/test-contract-split.sh
probe_step "reference install" bash scripts/test-reference-add.sh
probe_step "migrate a copied install" bash scripts/test-migrate.sh

# The starter runs by reference: its finder resolves to its own template/
# first, so editing a template file takes effect in the next `scripts/h`
# command with no copy step. Proved with a probe-only marker in a scratch
# starter checkout — isolated, so the gate never dirties its own template —
# resolved with no HARNESS_HOME, so only the starter-first path can find it.
probe_step "editing template takes effect immediately" bash -c '
  scratch="$(mktemp -d)" || { echo "error: mktemp failed"; exit 1; }
  trap "rm -rf \"$scratch\"" EXIT
  mkdir -p "$scratch/template/scripts" "$scratch/scripts" ||
    { echo "error: cannot make scratch"; exit 1; }
  cp "$PWD/template/.harness-root" "$scratch/template/.harness-root" ||
    { echo "error: cannot copy marker"; exit 1; }
  cp "$PWD/template/scripts/models.py" "$scratch/template/scripts/models.py" ||
    { echo "error: cannot copy models"; exit 1; }
  cp "$PWD/scripts/h" "$scratch/scripts/h" ||
    { echo "error: cannot copy finder"; exit 1; }
  chmod +x "$scratch/scripts/h" || { echo "error: cannot chmod finder"; exit 1; }
  python3 - "$scratch/template/scripts/models.py" <<PYEOF ||
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace("usage:", "usage: probe-marker-12345", 1)
assert "probe-marker-12345" in t, "no usage line to mark"
open(p, "w").write(t)
PYEOF
    { echo "error: cannot plant marker"; exit 1; }
  # models with no args prints usage and exits 2 — expected, so || true keeps
  # the output for the grep below rather than failing here.
  out="$(env -u HARNESS_HOME HOME="$scratch/no-home" HARNESS_URL="file:///nonexistent-probe" "$scratch/scripts/h" models 2>&1 || true)"
  echo "$out" | grep -q "probe-marker-12345" ||
    { echo "error: edited template did not take effect"; echo "$out"; exit 1; }'

step "shell parses" bash -c '
  set -e
  for f in bin/harness commands/*.sh commands/lib/*.sh scripts/*.sh scripts/hooks/* \
           scripts/h template/scripts/*.sh template/scripts/hooks/* \
           template/scripts/lib/*.sh template/scripts/h template/stubs/scripts/hooks/*; do
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

step "shared opencode agents" python3 scripts/test-shared-agents.py
step "context budget" python3 scripts/test-context-budget.py
step "dashboard board regression" python3 scripts/test-dashboard-board.py
step "dashboard switch regression" python3 scripts/test-dashboard-switch.py
step "one dashboard across projects" python3 scripts/test-dashboard-one-board.py
step "dashboard polling regression" node scripts/test-dashboard-polling.mjs

# A throwaway repo for the probe steps below: `fresh_probe || exit 1`, then
# use $probe. Called bare, never captured — inside $(...) the EXIT trap would
# belong to the subshell and reap the probe before the caller runs. Exported
# because each step runs in its own `bash -c` child that otherwise can't see it.
# Only the probes that test `harness add` itself use this directly now; the
# rest take `golden_probe` below, which is this plus the install, copied.
fresh_probe() {
  probe="$(mktemp -d)" || { echo "error: mktemp failed"; return 1; }
  trap 'rm -rf "$probe"' EXIT
  git init -q "$probe" || { echo "error: git init failed in $probe"; return 1; }
}
export -f fresh_probe

# One install per gate run, shared by every probe below. Each probe used to run
# its own private `bin/harness add` (~5-7s apiece across ~50 probes), pricing a
# full run in minutes. The golden dir pays that once, up front; probes copy it
# with cp -R instead of installing. Built from this tree, so a reference
# install of it is the install — the same stubs, seeds and finder, the same
# wired hooks, the same fresh ledger, the shared contract a link away.
build_golden() {
  GOLDEN="$(mktemp -d)" || { echo "error: mktemp failed"; return 1; }
  # Reference install of this tree: the harness must resolve without the
  # network, and the real ~/.harness is never consulted. HOME is overridden
  # inline — never exported — so the rest of the gate keeps its own.
  GOLDEN_HOME="$(mktemp -d)" || { echo "error: mktemp failed"; return 1; }
  HARNESS_HOME="$PWD" HOME="$GOLDEN_HOME" bin/harness add "$GOLDEN" >/dev/null 2>&1 || {
    echo "error: harness add failed for the golden fixture"
    rm -rf "$GOLDEN" "$GOLDEN_HOME"
    return 1
  }
}

# A throwaway repo carrying the golden install: `golden_probe || exit 1`, then
# use $probe. Same bare-and-exported contract as fresh_probe. The re-init over
# the copied .git changes nothing the install left — hooks stay wired, the
# ledger stays fresh — it only guarantees the copy reads as a repository.
golden_probe() {
  [ -n "${GOLDEN:-}" ] && [ -d "$GOLDEN" ] ||
    { echo "error: no golden fixture — the golden install above failed"; return 1; }
  probe="$(mktemp -d)" || { echo "error: mktemp failed"; return 1; }
  trap 'rm -rf "$probe"' EXIT
  cp -R "$GOLDEN/." "$probe/" ||
    { echo "error: cannot copy the golden fixture into $probe"; return 1; }
  git init -q "$probe" || { echo "error: git init failed in $probe"; return 1; }
}
export -f golden_probe

# Ledger-lane runs need no fixture: every serial step reads the tree or the
# live ledger, and every golden_probe sits inside a probe_step that already
# skips in this lane — so building the golden install here would pay a full
# install for nothing. Only build_golden, golden_probe and the reap in
# verify.sh name GOLDEN, and the reap only runs when this run built it.
if [ "$mode" = "--quick" ]; then
  : # quick lane builds nothing; its probes skip and its serial steps read the tree
elif [ "${scope:-full}" = "ledger" ]; then
  echo "  skip  golden fixture (ledger lane — no serial step reads GOLDEN)"
else
  step "golden fixture" build_golden
  # step runs in this shell, so a good build leaves GOLDEN set on the install
  # and a bad one removed it above; every golden_probe then fails fast instead
  # of copying nothing. Exported for the bash -c children, reaped on exit.
  if [ -n "${GOLDEN:-}" ] && [ -d "$GOLDEN" ]; then
    export GOLDEN
    # Owned by this run only, and deliberately NOT exported: nested
    # --quick gates below inherit GOLDEN itself, and a nested reap must
    # never delete the outer run's fixture out from under it.
    GOLDEN_MINE=1
    trap 'rm -rf "$GOLDEN" "${GOLDEN_HOME:-}"' EXIT
  fi
fi

# Reading one field out of bd JSON, and waiting out its read-your-write lag:
# step bodies below are single-quoted, so both quote kinds are spoken for down
# there - these live up here, where quotes are just quotes, and get exported
# like fresh_probe because each step runs in its own bash -c child. bd stderr
# is captured into the error, so a failing list says why instead of dying mute.
probe_json_field() {
  local dir="$1" field="$2" json
  json=$(cd "$dir" && bd list --json --all 2>&1) ||
    { echo "error: cannot list the probe beads: $json"; return 1; }
  printf %s "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0].get(sys.argv[1]))' "$field" ||
    { echo "error: cannot read the probe bead back"; return 1; }
}
export -f probe_json_field

# Polls wake every POLL_INTERVAL; POLL_TRIES keeps today's 30s ceiling.
POLL_TRIES=60
POLL_INTERVAL=0.5
export POLL_TRIES POLL_INTERVAL

await_bead_closed() {
  local dir="$1" bid="$2" tries=0 st=""
  while [ "$st" != "closed" ]; do
    st=$(probe_json_field "$dir" status) || return 1
    [ "$st" = "closed" ] && break
    tries=$((tries + 1))
    [ "$tries" -ge "$POLL_TRIES" ] && { echo "error: the probe bead $bid never closed (status: $st)"; return 1; }
    sleep "$POLL_INTERVAL"
  done
}
export -f await_bead_closed

# Waits until a deleted probe bead stops resolving: rapid bd invocations can
# read a snapshot from before the mutation landed, so an unasserted fixture
# would read as a probe that cannot see staleness. A delete that never lands
# fails loudly here rather than passing vacuously below.
await_bead_gone() {
  local dir="$1" bid="$2" tries=0
  while (cd "$dir" && bd show "$bid" >/dev/null 2>&1); do
    tries=$((tries + 1))
    [ "$tries" -ge "$POLL_TRIES" ] && { echo "error: the probe bead $bid still resolves after delete"; return 1; }
    sleep "$POLL_INTERVAL"
  done
}
export -f await_bead_gone

# Waits until a freshly filed probe bead resolves: rapid bd invocations can
# read a snapshot from before the mutation landed, so committing against an
# unasserted fixture would blame the hook for a bead the ledger can't see yet.
await_bead_ready() {
  local dir="$1" bid="$2" tries=0
  while ! (cd "$dir" && bd show "$bid" >/dev/null 2>&1); do
    tries=$((tries + 1))
    [ "$tries" -ge "$POLL_TRIES" ] && { echo "error: the probe bead $bid never resolves"; return 1; }
    sleep "$POLL_INTERVAL"
  done
}
export -f await_bead_ready



# The shared harness root one probe's finder resolves, on stdout. A reference
# install keeps no scripts of its own, so probes that used to import the
# probe's copy import the shared module instead — resolved the way a real
# session resolves it, never hardcoded to this checkout.
probe_shared_root() {
  HARNESS_HOME="$PWD" "$1/scripts/h" root 2>/dev/null || {
    echo "error: the probe finder cannot resolve the harness"; return 1; }
}
export -f probe_shared_root

# The default verdict, served silently: a dashboard.toml with no [verdict]
# section is the common case — every fresh install — so reading it must
# neither complain nor serve anything but the match-nothing default. Fails on
# any stderr, which is where a validator complaint would land.
# A reference install keeps no dashboard.py of its own: the shared module is
# imported by path, so the probe's toml only reads when the module's project
# points at the probe. HARNESS_PROJECT names it; HARNESS_ROOT names the
# shared checkout the module was loaded from.
probe_dashboard_default_silent() {
  local probe="$1" mod="$2" err shared
  shared="${mod%/scripts/dashboard.py}"
  err="$(cd "$probe" && HARNESS_PROJECT="$probe" HARNESS_ROOT="$shared" python3 - "$mod" <<'PYEOF' 2>&1
import importlib.util
import sys
spec = importlib.util.spec_from_file_location("probedb", sys.argv[1])
db = importlib.util.module_from_spec(spec)
spec.loader.exec_module(db)
got = db.verdict_pattern()
assert got == db.DEFAULT_VERDICT, "default verdict %r" % (got,)
PYEOF
)"
  [ -z "$err" ] || { echo "error: the default verdict complained: $err"; return 1; }
}
export -f probe_dashboard_default_silent

# The verdict pattern the probe's dashboard serves, through the real reader —
# importing the module runs only definitions, never the server. HARNESS_PROJECT
# points the shared module at the probe, as above.
probe_dashboard_verdict() {
  local probe="$1" want="$2" mod="$3" shared
  shared="${mod%/scripts/dashboard.py}"
  (cd "$probe" && HARNESS_PROJECT="$probe" HARNESS_ROOT="$shared" python3 - "$want" "$mod" <<'PYEOF'
import importlib.util
import sys
want = sys.argv[1]
spec = importlib.util.spec_from_file_location("probedb", sys.argv[2])
db = importlib.util.module_from_spec(spec)
spec.loader.exec_module(db)
got = db.verdict_pattern()
assert got == want, "served verdict %r != %r" % (got, want)
# A verdict shape the validator let through must still not blow up the reader:
# log_ok runs on gate logs with no status sibling beside them.
db.log_ok("BUILD OK and error: boom")
PYEOF
  )
}
export -f probe_dashboard_verdict


# A template file that still says {{PROJECT}} after substitution is one the
# installer missed — and the placeholder only shows up at the far end, in an
# installed project, long after anyone would connect it to this change.
probe_step "placeholders substitute" bash -c '
  # Each step checked on its own. An && chain here reports ok when its own setup
  # failed: probe would be empty, the install would never run, grep would find
  # nothing to complain about, and the gate would pass vacuously — which is the
  # silent success this project exists to avoid, in the check meant to catch it.
  golden_probe || exit 1
  [ -f "$probe/scripts/h" ] || { echo "error: install produced no finder"; exit 1; }
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

# Retired commands stay retired: update and diverge print their pointer on
# stderr and exit 2, and the listing names them as retired.
probe_step "retired commands print their pointer and exit 2" bash -c '
  out=$(bin/harness update 2>&1); rc=$?; [ "$rc" -eq 2 ] ||
    { echo "error: update exited $rc, want 2"; echo "$out"; exit 1; }
  echo "$out" | grep -q "retired" ||
    { echo "error: update never said retired"; echo "$out"; exit 1; }
  out=$(bin/harness diverge scripts/review.sh 2>&1); rc=$?; [ "$rc" -eq 2 ] ||
    { echo "error: diverge exited $rc, want 2"; echo "$out"; exit 1; }
  echo "$out" | grep -q "retired" ||
    { echo "error: diverge never said retired"; echo "$out"; exit 1; }
  bin/harness 2>&1 | grep -q "retired" ||
    { echo "error: the listing never names the retired commands"; exit 1; }'

# No [verdict] section is the common case — every fresh install — so the
# default must be served silently: no complaint on stderr, match-nothing
# pattern from the reader.
probe_step "dashboard serves the default verdict silently with no verdict section" bash -c '
  golden_probe || exit 1
  grep -q "^\\[verdict\\]" "$probe/dashboard.toml" &&
    { echo "error: the fixture already has a verdict section"; exit 1; }
  mod="$(probe_shared_root "$probe")/scripts/dashboard.py" || exit 1
  probe_dashboard_default_silent "$probe" "$mod" || exit 1'

# The config a probe dashboard serves, through the real readers — importing
# the module runs only definitions, never the server. Setup lives here too:
# the golden toml carries no [theme]/[board]/[assets] tables, so appending
# each exactly once is a fresh table, never a duplicate.
probe_dashboard_config() {
  local probe="$1" mod="$2" shared
  shared="${mod%/scripts/dashboard.py}"
  # Bare heredoc, no || guard on the redirect line: bash 3.2 (the gate's
  # shell) cannot re-import an exported function carrying one. A failed
  # append fails the asserts below rather than passing silently.
  cat >> "$probe/dashboard.toml" <<'TOMLEOF'
[theme]
"--probe-accent" = "#123456"
[board]
hidden = ["peers"]
order = ["ready", "done"]
[assets]
css = ["dashboard-assets/probe.css"]
js = ["dashboard-assets/probe.js"]
TOMLEOF
  (cd "$probe" && HARNESS_PROJECT="$probe" HARNESS_ROOT="$shared" python3 - "$mod" <<'PYEOF'
import importlib.util
import sys
spec = importlib.util.spec_from_file_location("probedb", sys.argv[1])
db = importlib.util.module_from_spec(spec)
spec.loader.exec_module(db)
theme = db.theme()
assert theme == {"--probe-accent": "#123456"}, "theme %r" % (theme,)
board = db.board()
assert board == {"hidden": ["peers"], "order": ["ready", "done"]}, "board %r" % (board,)
assets = db.assets()
assert assets == {"css": ["probe.css"], "js": ["probe.js"]}, "assets %r" % (assets,)
PYEOF
  )
}
export -f probe_dashboard_config

# What one /assets/ path resolves to, through the same function the handler
# answers with: an allowlisted file serves its bytes with a fixed
# content-type, and anything else — unlisted, traversal, empty, absolute —
# reads as missing, which the handler turns into a 404.
probe_dashboard_asset_serving() {
  local probe="$1" mod="$2" shared
  shared="${mod%/scripts/dashboard.py}"
  mkdir -p "$probe/dashboard-assets" || { echo "error: cannot make probe assets"; return 1; }
  printf '/* probe */\n' > "$probe/dashboard-assets/probe.css" || return 1
  printf '// probe\n' > "$probe/dashboard-assets/probe.js" || return 1
  printf '/* unlisted */\n' > "$probe/dashboard-assets/evil.css" || return 1
  # Bare heredoc, same bash-3.2 reason as above.
  cat >> "$probe/dashboard.toml" <<'TOMLEOF'
[assets]
css = ["dashboard-assets/probe.css"]
js = ["dashboard-assets/probe.js"]
TOMLEOF
  (cd "$probe" && HARNESS_PROJECT="$probe" HARNESS_ROOT="$shared" python3 - "$mod" <<'PYEOF'
import importlib.util
import sys
spec = importlib.util.spec_from_file_location("probedb", sys.argv[1])
db = importlib.util.module_from_spec(spec)
spec.loader.exec_module(db)
got = db.asset_body("probe.css")
assert got is not None and got[0] == "text/css" and got[1] == b"/* probe */\n", "css %r" % (got,)
got = db.asset_body("probe.js")
assert got is not None and got[0] == "text/javascript" and got[1] == b"// probe\n", "js %r" % (got,)
assert db.asset_body("evil.css") is None, "an unlisted file resolved"
assert db.asset_body("../dashboard.toml") is None, "a traversal resolved"
assert db.asset_body("a/../../dashboard.toml") is None, "a nested traversal resolved"
assert db.asset_body("") is None, "an empty path resolved"
assert db.asset_body("/probe.css") is None, "an absolute path resolved"
assert db.asset_body("dashboard-assets/probe.css") is None, "a prefixed path resolved"
PYEOF
  )
}
export -f probe_dashboard_asset_serving

# A broken table keeps its last good values and complains, without taking a
# good table down with it. Good then bad in one process, because the cache
# that holds last-good lives in the module. The shared module reads the
# probe's toml through HARNESS_PROJECT, as above.
probe_dashboard_broken_config() {
  local probe="$1" mod="$2" shared
  shared="${mod%/scripts/dashboard.py}"
  (cd "$probe" && HARNESS_PROJECT="$probe" HARNESS_ROOT="$shared" python3 - "$mod" <<'PYEOF'
import importlib.util, io, sys
from contextlib import redirect_stderr
toml_path = "dashboard.toml"
with open(toml_path, "a") as f:
    f.write("[theme]\n\"--probe-accent\" = \"#123456\"\n[board]\nhidden = []\norder = [\"ready\"]\n")
spec = importlib.util.spec_from_file_location("probedb", sys.argv[1])
db = importlib.util.module_from_spec(spec)
spec.loader.exec_module(db)
buf = io.StringIO()
with redirect_stderr(buf):
    first_theme = db.theme()
    first_board = db.board()
assert first_theme == {"--probe-accent": "#123456"}, "good theme %r" % (first_theme,)
assert first_board == {"hidden": [], "order": ["ready"]}, "good board %r" % (first_board,)
assert buf.getvalue() == "", "a good config complained: %r" % (buf.getvalue(),)
text = open(toml_path).read()
good_line = "\"--probe-accent\" = \"#123456\""
assert good_line in text, "the fixture never planted the good theme"
open(toml_path, "w").write(text.replace(good_line, "\"BAD NAME!\" = \"#123456\"", 1))
buf = io.StringIO()
with redirect_stderr(buf):
    kept = db.theme()
    board_kept = db.board()
assert kept == {"--probe-accent": "#123456"}, "a broken theme lost last good: %r" % (kept,)
assert "keeping last good theme" in buf.getvalue(), "no complaint: %r" % (buf.getvalue(),)
assert board_kept == {"hidden": [], "order": ["ready"]}, "a bad theme took board down: %r" % (board_kept,)
PYEOF
  )
}
export -f probe_dashboard_broken_config

# What the toml lists is what state.json carries: the theme overrides, the
# board hide/reorder lists, and the asset paths, read through the real module.
probe_step "dashboard serves theme, board, and assets from the toml" bash -c '
  golden_probe || exit 1
  mod="$(probe_shared_root "$probe")/scripts/dashboard.py" || exit 1
  probe_dashboard_config "$probe" "$mod" || exit 1'

# Only an allowlisted file resolves, with a fixed content-type; an unlisted
# file and every traversal shape read as missing, which the handler 404s.
probe_step "dashboard serves allowlisted assets and 404s the rest" bash -c '
  golden_probe || exit 1
  mod="$(probe_shared_root "$probe")/scripts/dashboard.py" || exit 1
  probe_dashboard_asset_serving "$probe" "$mod" || exit 1'

# Vercel chip probes: link + token fixtures through the real reader, with the
# fetch stubbed — no network in the gate. Bare heredocs, no || guard on a
# redirect line: bash 3.2 (the gate's shell) cannot re-import an exported
# function carrying one. A failed fixture fails the asserts below rather than
# passing silently.
#
# The loader plus link fixture the three vercel probes share: the caller feeds
# the test body on stdin and it runs with db preloaded. Mode names whether the
# fixture links, stays missing, or carries a torn file. One helper, called by
# all three probes below.
probe_dashboard_vercel_run() {
  local probe="$1"
  local mode="${2:-linked}"
  local mod="$3"
  local body shared
  shared="${mod%/scripts/dashboard.py}"
  body=$(cat)
  rm -f "$probe/.env.local" || return 1
  if [ "$mode" = "linked" ]; then
    mkdir -p "$probe/.vercel" || return 1
    printf '{"projectId":"probe-proj","orgId":"probe-org"}' > "$probe/.vercel/project.json" || return 1
    grep -q probe-proj "$probe/.vercel/project.json" ||
      { echo "error: the fixture never linked"; return 1; }
  elif [ "$mode" = "torn" ]; then
    mkdir -p "$probe/.vercel" || return 1
    printf '{torn' > "$probe/.vercel/project.json" || return 1
  else
    rm -rf "$probe/.vercel" || return 1
  fi
  (cd "$probe" && HARNESS_PROJECT="$probe" HARNESS_ROOT="$shared" python3 - "$body" "$mod" <<'PYEOF'
import importlib.util
import sys
spec = importlib.util.spec_from_file_location("probedb", sys.argv[2])
db = importlib.util.module_from_spec(spec)
spec.loader.exec_module(db)
exec(sys.argv[1])
PYEOF
  )
}
export -f probe_dashboard_vercel_run

probe_dashboard_vercel_unlinked() {
  local probe="$1" mod="$2"
  [ ! -e "$probe/.vercel/project.json" ] || { echo "error: the fixture is already linked"; return 1; }
  # Empty assignment, not env -u: env cannot invoke a shell function, and an
  # empty token reads as absent the same way an unset one does.
  VERCEL_API_TOKEN= probe_dashboard_vercel_run "$probe" unlinked "$mod" <<'PYEOF'
assert db.vercel_state() is None, "unlinked served %r" % (db.vercel_state(),)
st = db.state(fast=True)
assert "vercel" not in st, "unlinked state carries a vercel key"
PYEOF
  [ $? -eq 0 ] || return 1
  VERCEL_API_TOKEN= probe_dashboard_vercel_run "$probe" torn "$mod" <<'PYEOF'
got = db.vercel_state()
assert got == {"configured": False, "why": "link"}, "torn link %r" % (got,)
st = db.state(fast=True)
assert st.get("vercel") == {"configured": False, "why": "link"}, "state key %r" % (st.get("vercel"),)
PYEOF
}
export -f probe_dashboard_vercel_unlinked

# A linked checkout missing the token or the upstream ref reads as
# unconfigured with why — never an exception — and the state key carries
# exactly that.
probe_dashboard_vercel_misconfigured() {
  local probe="$1" mod="$2"
  # Empty assignment, not env -u: env cannot invoke a shell function, and an
  # empty token reads as absent the same way an unset one does.
  VERCEL_API_TOKEN= probe_dashboard_vercel_run "$probe" linked "$mod" <<'PYEOF'
got = db.vercel_state()
assert got == {"configured": False, "why": "token"}, "token case %r" % (got,)
st = db.state(fast=True)
assert st.get("vercel") == {"configured": False, "why": "token"}, "state key %r" % (st.get("vercel"),)
open(".env.local", "wb").write(b"\xff\xfeVERCEL_API_TOKEN=probe-token\n")
assert db.vercel_token() == "", "bad bytes read as a token"
db._vercel["at"] = 0.0
got = db.vercel_state()
assert got == {"configured": False, "why": "token"}, "bad bytes %r" % (got,)
PYEOF
  [ $? -eq 0 ] || return 1
  VERCEL_API_TOKEN=probe-token probe_dashboard_vercel_run "$probe" linked "$mod" <<'PYEOF'
import urllib.error
# The fetch stays stubbed to fail: no shape under test may reach the network.
def boom(*a):
    raise urllib.error.URLError("probe must not fetch")
db.vercel_fetch = boom
got = db.vercel_state()
assert got == {"configured": False, "why": "upstream"}, "upstream case %r" % (got,)
PYEOF
}
export -f probe_dashboard_vercel_misconfigured

# API states map to chip labels through the real reader with the fetch
# stubbed: READY lands deployed, building states land deploying, anything
# else failed, no match behind — a ragged payload and a dead API land
# unreachable.
probe_dashboard_vercel_labels() {
  local probe="$1" mod="$2"
  # --no-verify: the empty commit is scaffolding in a throwaway repo, and add
  # wired the bead-naming hook here. Its message names nothing real.
  (cd "$probe" && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --no-verify --allow-empty -m probe-init) || return 1
  (cd "$probe" && git update-ref refs/remotes/origin/main HEAD) || return 1
  [ -n "$(cd "$probe" && git rev-parse --verify origin/main 2>/dev/null || true)" ] ||
    { echo "error: the fixture never grew an origin/main"; return 1; }
  VERCEL_API_TOKEN=probe-token probe_dashboard_vercel_run "$probe" linked "$mod" <<'PYEOF'
import json
import urllib.error
head = db.vercel_head()
assert head and len(head) == 40, "the fixture has no origin/main to match"
def dep(state):
    return {"state": state, "url": "probe.vercel.app", "createdAt": 1720000000000,
            "meta": {"githubCommitSha": head, "githubCommitCreatedAt": 1720000000000}}
def read(deps):
    db.vercel_fetch = lambda *a, _d=deps: _d
    db._vercel["at"] = 0.0
    return db.vercel_state()
got = read([dep("READY")])
assert got.get("status") == "deployed" and got.get("sha") == head[:7], "ready %r" % (got,)
assert got.get("url") == "https://probe.vercel.app", "url %r" % (got,)
for building in ("QUEUED", "INITIALIZING", "BUILDING"):
    got = read([dep(building)])
    assert got.get("status") == "deploying", "%s %r" % (building, got)
for failed in ("ERROR", "CANCELED"):
    got = read([dep(failed)])
    assert got.get("status") == "failed", "%s %r" % (failed, got)
other = dep("READY")
other["meta"] = {"githubCommitSha": "0" * 40}
got = read([other])
assert got.get("status") == "behind" and got.get("sha") is None, "no match %r" % (got,)
got = read([None])
assert got.get("status") == "unreachable", "ragged payload served %r" % (got,)
def boom(*a):
    raise urllib.error.URLError("probe offline")
db.vercel_fetch = boom
db._vercel["at"] = 0.0
got = db.vercel_state()
assert got.get("configured") is True and got.get("status") == "unreachable", "dead api %r" % (got,)
assert "probe offline" in got.get("error", ""), "error lost %r" % (got,)
assert "probe-token" not in json.dumps(got), "the token leaked into state: %r" % (got,)
PYEOF
}
export -f probe_dashboard_vercel_labels

# An unlinked checkout serves no vercel key: the page renders no chip and the
# board reads as before this reader existed.
probe_step "dashboard vercel unlinked serves no vercel key" bash -c '
  golden_probe || exit 1
  mod="$(probe_shared_root "$probe")/scripts/dashboard.py" || exit 1
  probe_dashboard_vercel_unlinked "$probe" "$mod" || exit 1'

# A linked checkout missing the token or the upstream ref reads as
# unconfigured with why, never an exception.
probe_step "dashboard vercel misconfigured reads unconfigured with why" bash -c '
  golden_probe || exit 1
  mod="$(probe_shared_root "$probe")/scripts/dashboard.py" || exit 1
  probe_dashboard_vercel_misconfigured "$probe" "$mod" || exit 1'

# API states map to chip labels; a dead API reads unreachable with the token
# nowhere in what the reader serves.
probe_step "dashboard vercel maps api states to chip labels" bash -c '
  golden_probe || exit 1
  mod="$(probe_shared_root "$probe")/scripts/dashboard.py" || exit 1
  probe_dashboard_vercel_labels "$probe" "$mod" || exit 1'

# A broken table keeps serving its last good values and says so on stderr,
# while a good table beside it keeps updating.
probe_step "dashboard keeps last good config on a broken table" bash -c '
  golden_probe || exit 1
  mod="$(probe_shared_root "$probe")/scripts/dashboard.py" || exit 1
  probe_dashboard_broken_config "$probe" "$mod" || exit 1'

# A pattern with the wrong group shape never reaches the reader: log_ok pulls
# the verdict word out of exactly one group, so zero groups serve permanent
# red and two hand back tuples, which have no .upper. The toml keeps serving
# the default instead, with the complaint on stderr.
probe_step "dashboard keeps the default over a misshapen verdict pattern" bash -c '
  golden_probe || exit 1
  printf "[verdict]\npattern = '"'"'(BUILD|TEST) (OK|FAIL)'"'"'\n" >> "$probe/dashboard.toml" ||
    { echo "error: cannot plant the bad pattern"; exit 1; }
  mod="$(probe_shared_root "$probe")/scripts/dashboard.py" || exit 1
  probe_dashboard_verdict "$probe" "(?!)" "$mod" ||
    { echo "error: a two-group pattern reached the reader"; exit 1; }'

# Stack guidance stays in the shared checkout: a reference install records the
# project's stacks in harness/stacks.txt and links only those stacks' guidance
# (the path the reviewers read) — never a copy, and never guidance for someone
# else's platform.
probe_step "add records stacks without copying guidance" bash -c '
  fresh_probe || exit 1
  touch "$probe/Package.swift" || { echo "error: cannot mark the probe as swift"; exit 1; }
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  grep -qx swift "$probe/harness/stacks.txt" ||
    { echo "error: stacks.txt never recorded swift"; exit 1; }
  [ -L "$probe/harness/stacks/swift.md" ] && [ -f "$probe/harness/stacks/swift.md" ] ||
    { echo "error: swift guidance is not a live link into the shared checkout"; exit 1; }
  [ -z "$(find "$probe/harness/stacks" ! -type d ! -type l 2>/dev/null)" ] ||
    { echo "error: a reference install copied stack guidance"; exit 1; }
  [ ! -e "$probe/harness/stacks/web.md" ] ||
    { echo "error: guidance for an unlisted stack was linked"; exit 1; }
  bare="$(mktemp -d)" && git init -q "$bare" || { echo "error: cannot make a bare probe"; exit 1; }
  bin/harness add "$bare" >/dev/null 2>&1 || { echo "error: harness add failed on a bare probe"; rm -rf "$bare"; exit 1; }
  [ -f "$bare/harness/stacks.txt" ] && [ -z "$(find "$bare/harness/stacks" ! -type d 2>/dev/null)" ] ||
    { echo "error: a project with no stack got stack guidance, or no stacks.txt"; rm -rf "$bare"; exit 1; }
  rm -rf "$bare"'

# stacks.txt is the project's once written: a re-run of add never re-detects
# over it — or a wrong guess could never be corrected for good.
probe_step "an edited stacks.txt survives a re-add" bash -c '
  fresh_probe || exit 1
  touch "$probe/Package.swift" || { echo "error: cannot mark the probe as swift"; exit 1; }
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  printf "web\n" > "$probe/harness/stacks.txt" || { echo "error: cannot edit stacks.txt"; exit 1; }
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: re-add failed"; exit 1; }
  [ "$(grep -v "^#" "$probe/harness/stacks.txt")" = "web" ] ||
    { echo "error: re-add rewrote stacks.txt"; exit 1; }'

# A stack name with no guidance behind it warns loudly: reviewers would
# otherwise miss the platform checks and nothing would say so.
probe_step "add warns loudly on unknown stack names" bash -c '
  fresh_probe || exit 1
  mkdir -p "$probe/harness" || { echo "error: cannot make harness/"; exit 1; }
  # Web: a case-insensitive disk finds web.md for it, yet nothing installs.
  printf "cobol\nWeb\n" > "$probe/harness/stacks.txt" || { echo "error: cannot write stacks.txt"; exit 1; }
  out=$(bin/harness add "$probe" 2>&1) || { echo "error: harness add failed"; echo "$out"; exit 1; }
  echo "$out" | grep -q "no guidance for" ||
    { echo "error: add never warned about unknown stacks"; echo "$out"; exit 1; }
  echo "$out" | grep -q "cobol" ||
    { echo "error: add never named every unknown stack"; echo "$out"; exit 1; }
  echo "$out" | grep -q "Web" ||
    { echo "error: add never named every unknown stack"; echo "$out"; exit 1; }'

# A role's packet budget is its explicit "context", else the catalog's limit
# for the pinned model, else the pin's own window — and a role the harness doesn't know has
# no budget at all rather than a guessed one. A foreign roster entry is
# refused rather than budgeted. A reference install keeps no models.py of its
# own, so the shared one runs through the probe's finder — the dispatch a real
# session uses, reading the probe's own roster.
probe_step "models.py budget resolves explicit and default budgets" bash -c '
  golden_probe || exit 1
  cat > "$probe/harness/models.json" <<EOF ||
{"reviewer-taste": {"model": "opencode-go/muse-spark-1.3-contributor", "variant": "xhigh", "context": 12345},
 "reviewer-design": {"model": "opencode-go/muse-spark-1.3-contributor", "variant": "xhigh"},
 "librarian": {"model": "ollama/qwen3:27b", "variant": "xhigh"}}
EOF
    { echo "error: cannot write test roster"; exit 1; }
  # An empty catalog cache, so the default is OPENCODE_CONTEXT rather than
  # whatever this machine has cached for the pinned model.
  export XDG_CACHE_HOME="$probe/no-cache"
  [ "$(HARNESS_HOME="$PWD" "$probe/scripts/h" models budget reviewer-taste)" = "12345" ] ||
    { echo "error: explicit context not honored"; exit 1; }
  [ "$(HARNESS_HOME="$PWD" "$probe/scripts/h" models budget reviewer-design)" = "1048576" ] ||
    { echo "error: default is not the pin window"; exit 1; }
  # if-form, not trailing &&: a failed && as the last line exits the step 1.
  if HARNESS_HOME="$PWD" "$probe/scripts/h" models budget nobody >/dev/null 2>&1; then
    echo "error: budget passed for an unknown role"; exit 1;
  fi
  if HARNESS_HOME="$PWD" "$probe/scripts/h" models budget librarian >/dev/null 2>&1; then
    echo "error: budget passed for a foreign roster entry"; exit 1;
  fi'

# An over-budget packet refuses with the binding role and the narrower command
# — a truncated packet reporting confidently on its first pages is the failure.
# The shared review runs through the probe's finder; the dirtied stub stands in
# for any tracked change, since review reads the whole working tree.
probe_step "review.sh refuses a packet over the smallest reviewer budget" bash -c '
  golden_probe || exit 1
  cat > "$probe/harness/models.json" <<EOF ||
{"reviewer-taste": {"model": "opencode-go/muse-spark-1.3-contributor", "variant": "xhigh", "context": 100},
 "reviewer-correctness": {"model": "opencode-go/muse-spark-1.3-contributor", "variant": "xhigh", "context": 100},
 "reviewer-design": {"model": "opencode-go/muse-spark-1.3-contributor", "variant": "xhigh", "context": 100}}
EOF
    { echo "error: cannot write test roster"; exit 1; }
  echo "# change" >> "$probe/AGENTS.md" ||
    { echo "error: cannot dirty a tracked file"; exit 1; }
  out=$(HARNESS_HOME="$PWD" "$probe/scripts/h" review 2>&1) &&
    { echo "error: review passed an over-budget packet"; echo "$out"; exit 1; }
  echo "$out" | grep -q "reviewer-taste" ||
    { echo "error: refusal never named the binding role"; echo "$out"; exit 1; }
  echo "$out" | grep -q "scripts/h review <commit>" ||
    { echo "error: refusal never said how to narrow"; echo "$out"; exit 1; }'

# A packet within budget still prints its path — the refusal must not fire on
# ordinary changes.
probe_step "review.sh passes a packet within budget" bash -c '
  golden_probe || exit 1
  cat > "$probe/harness/models.json" <<EOF ||
{"reviewer-taste": {"model": "opencode-go/muse-spark-1.3-contributor", "variant": "xhigh", "context": 1000000},
 "reviewer-correctness": {"model": "opencode-go/muse-spark-1.3-contributor", "variant": "xhigh", "context": 1000000},
 "reviewer-design": {"model": "opencode-go/muse-spark-1.3-contributor", "variant": "xhigh", "context": 1000000}}
EOF
    { echo "error: cannot write test roster"; exit 1; }
  echo "# change" >> "$probe/AGENTS.md" ||
    { echo "error: cannot dirty a tracked file"; exit 1; }
  out=$(HARNESS_HOME="$PWD" "$probe/scripts/h" review 2>&1) || {
    echo "error: review refused a fitting packet"; echo "$out"; exit 1; }
  echo "$out" | grep -q "review-packet" ||
    { echo "error: review never printed the packet"; echo "$out"; exit 1; }'

# A fresh install runs opencode on the pin and nothing else (har-wbbe): the
# stub pins the session model, the linked shared agents carry it, and there
# is no local roster — ensure writes the pinned one with no terminal, the pin
# check passes the install as it stands, and a foreign roster planted
# afterwards fails it.
probe_step "a fresh install pins opencode to one model" bash -c '
  golden_probe || exit 1
  pin="opencode-go/muse-spark-1.3-contributor"
  [ ! -e "$probe/harness/models.json" ] ||
    { echo "error: a reference install carries a roster"; exit 1; }
  modroot="$(probe_shared_root "$probe")" || exit 1
  python3 - "$probe/opencode.json" "$modroot/stubs/opencode.json" <<EOF ||
import json, sys
stub, full = (json.load(open(p)) for p in sys.argv[1:3])
sys.exit(0 if stub.get("model") == full.get("model") == "$pin#xhigh"
         and stub.get("small_model") == full.get("small_model") else 1)
EOF
    { echo "error: the stub never pinned the session model"; exit 1; }
  for agent in "$probe"/.opencode/agent/*.md; do
    grep -qxF "model: $pin#xhigh" "$agent" ||
      { echo "error: $agent does not carry the pin"; exit 1; }
  done
  (HARNESS_HOME="$PWD" "$probe/scripts/h" models ensure </dev/null >/dev/null 2>&1) ||
    { echo "error: ensure failed without a terminal"; exit 1; }
  python3 - "$probe/harness/models.json" "$pin" <<EOF ||
import json, sys
roster = json.load(open(sys.argv[1]))
pinned = {"model": sys.argv[2], "variant": "xhigh"}
sys.exit(0 if roster and all(entry == pinned for entry in roster.values()) else 1)
EOF
    { echo "error: ensure wrote something other than the pin"; exit 1; }
  out=$(python3 "$modroot/scripts/opencode-pin.py" check "$probe" 2>&1) ||
    { echo "error: pin check failed a fresh install"; echo "$out"; exit 1; }
  echo "{\"implement\": {\"model\": \"opencode-go/cheap\"}}" > "$probe/harness/models.json" ||
    { echo "error: cannot plant a foreign roster"; exit 1; }
  if python3 "$modroot/scripts/opencode-pin.py" check "$probe" >/dev/null 2>&1; then
    echo "error: pin check passed a foreign roster"; exit 1;
  fi'

# `harness add` merges the root instructions into an existing shadow instead
# of leaving AGENTS.md unloaded: the shadow keeps its own entries and its
# plugin, and gains whatever root entries it was missing. Add never
# overwrites, so the planted shadow survives the install to be merged.
probe_step "add merges root instructions into a shadowing opencode.json" bash -c '
  fresh_probe || exit 1
  mkdir -p "$probe/.opencode" || { echo "error: cannot make .opencode"; exit 1; }
  printf "{\"instructions\":[\"CLAUDE.md\",\"LOCAL.md\"],\"plugin\":[\"probe-plugin\"]}\n" \
    > "$probe/.opencode/opencode.json" || { echo "error: cannot plant the shadow"; exit 1; }
  grep -q "LOCAL.md" "$probe/.opencode/opencode.json" ||
    { echo "error: the fixture never planted the shadow"; exit 1; }
  if grep -q "AGENTS.md" "$probe/.opencode/opencode.json"; then
    echo "error: the fixture shadow already carries every instruction"; exit 1;
  fi
  out=$(bin/harness add "$probe" 2>&1) || { echo "error: harness add failed"; echo "$out"; exit 1; }
  echo "$out" | grep -q "merged instructions" ||
    { echo "error: add never said it merged"; echo "$out"; exit 1; }
  grep -q "AGENTS.md" "$probe/.opencode/opencode.json" ||
    { echo "error: add never merged the missing instruction"; exit 1; }
  grep -q "LOCAL.md" "$probe/.opencode/opencode.json" ||
    { echo "error: add dropped the shadow own entry"; exit 1; }
  grep -q "probe-plugin" "$probe/.opencode/opencode.json" ||
    { echo "error: add dropped the shadow plugin"; exit 1; }'

# A copied install is a conversion, not an install: add refuses before writing
# anything and points at the migrate, instead of printing "already there" for
# every stub and leaving the stale contract in place.
probe_step "add refuses a copied install and points at migrate" bash -c '
  fresh_probe || exit 1
  mkdir -p "$probe/scripts" || { echo "error: cannot shape the probe as a copy"; exit 1; }
  cp "$PWD/template/scripts/brief.sh" "$probe/scripts/brief.sh" ||
    { echo "error: cannot plant the copy marker"; exit 1; }
  out=$(bin/harness add "$probe" 2>&1) &&
    { echo "error: add succeeded over a copied install"; echo "$out"; exit 1; }
  echo "$out" | grep -q "copied install" ||
    { echo "error: the refusal never named the copied install"; echo "$out"; exit 1; }
  echo "$out" | grep -q "harness migrate" ||
    { echo "error: the refusal never pointed at migrate"; echo "$out"; exit 1; }
  if [ -e "$probe/AGENTS.md" ] || [ -e "$probe/scripts/h" ]; then
    echo "error: add wrote reference files into the refused copy"; exit 1;
  fi'

# A target that is already a reference install — scripts/h, no copies —
# re-runs idempotently instead of refusing.
probe_step "add re-runs idempotently over a reference install" bash -c '
  golden_probe || exit 1
  out=$(bin/harness add "$probe" 2>&1) || { echo "error: re-add failed"; echo "$out"; exit 1; }
  if echo "$out" | grep -q "copied install"; then
    echo "error: re-add mistook a reference install for a copy"; echo "$out"; exit 1;
  fi'

# A plugin-only .opencode/opencode.json shadows the root one — opencode reads
# only the deeper file — so without its instructions AGENTS.md never loads.
# The pin check fails it loudly rather than passing a tree that unloads the
# contract.
probe_step "a plugin-only opencode shadow fails the pin check" bash -c '
  golden_probe || exit 1
  mkdir -p "$probe/.opencode" || { echo "error: cannot make .opencode"; exit 1; }
  printf "{\"plugin\":[\"probe-plugin\"]}\n" > "$probe/.opencode/opencode.json" ||
    { echo "error: cannot plant the plugin-only shadow"; exit 1; }
  modroot="$(probe_shared_root "$probe")" || exit 1
  if python3 "$modroot/scripts/opencode-pin.py" check "$probe" >/dev/null 2>&1; then
    echo "error: the pin check passed a plugin-only shadow"; exit 1;
  fi'

# `harness add` owns the git dependency: a fresh directory gets a repository
# rather than an error, and says so in its own voice.
probe_step "add initialises a missing git repository" bash -c '
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
probe_step "add refuses a subdirectory of a repository" bash -c '
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
probe_step "add refuses a broken .git entry" bash -c '
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
probe_step "add refuses a bare repository" bash -c '
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
probe_step "add accepts a linked worktree" bash -c '
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

# Every other probe commit sidesteps the commit-msg hook — scaffolding commits
# use --no-verify — so a broken hook regex ships silently. This commits
# bead-less content in a wired probe and expects rejection, then proves the
# hook still accepts a commit naming a real bead, so a hook that rejects
# everything doesn't pass either.
probe_step "the commit-msg hook rejects a bead-less commit" bash -c '
  golden_probe || exit 1
  # Normalize the install-staged fixture (ledger export, model roster) into a
  # seed commit: the artifact-only commit below must stage only the handoff,
  # and installs now stage their generated files.
  (cd "$probe" && git add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit --no-verify -qm "seed install fixture" >/dev/null 2>&1) ||
    { echo "error: cannot seed-commit the install fixture"; exit 1; }
  [ -x "$probe/scripts/hooks/commit-msg" ] || { echo "error: install produced no hook logic"; exit 1; }
  [ -f "$probe/.git/hooks/commit-msg" ] || { echo "error: add never wired the hook"; exit 1; }
  # Pinned like the identity flags below it: a global core.hooksPath would run
  # hooks from elsewhere, and the bead-less commit would sail through a hook
  # that never ran — failing the probe on a correct tree.
  hook="core.hooksPath=$probe/.git/hooks"
  mkdir -p "$probe/harness/handoffs" || { echo "error: cannot make artifact directory"; exit 1; }
  echo "# probe handoff" > "$probe/harness/handoffs/20260101-000000.md" ||
    { echo "error: cannot write handoff fixture"; exit 1; }
  (cd "$probe" && git add harness/handoffs/20260101-000000.md >/dev/null 2>&1) ||
    { echo "error: cannot stage handoff fixture"; exit 1; }
  (cd "$probe" && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false -c "$hook" commit -m "record handoff" >/dev/null 2>&1) ||
    { echo "error: artifact-only commit was rejected"; exit 1; }
  echo "probe" > "$probe/probe.txt" || { echo "error: cannot dirty a probe file"; exit 1; }
  (cd "$probe" && git add probe.txt >/dev/null 2>&1) ||
    { echo "error: cannot stage source fixture"; exit 1; }
  out=$(cd "$probe" && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false -c "$hook" commit -m "probe source without bead" 2>&1) &&
    { echo "error: the hook accepted source without a bead"; echo "$out"; exit 1; }
  echo "$out" | grep -q "names no bead" ||
    { echo "error: source refusal never said why"; echo "$out"; exit 1; }
  echo "# mixed source and artifact" >> "$probe/harness/handoffs/20260101-000000.md" ||
    { echo "error: cannot edit handoff fixture"; exit 1; }
  (cd "$probe" && git add harness/handoffs/20260101-000000.md >/dev/null 2>&1) ||
    { echo "error: cannot stage mixed artifact"; exit 1; }
  out=$(cd "$probe" && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false -c "$hook" commit -m "probe mixed commit without bead" 2>&1) &&
    { echo "error: the hook accepted mixed source and artifact without a bead"; echo "$out"; exit 1; }
  echo "$out" | grep -q "names no bead" ||
    { echo "error: mixed refusal never said why"; echo "$out"; exit 1; }
  # `bd q` prints only the new bead id: capturing it saves the full-list read
  # a separate lookup would do, and never reads a pre-settle snapshot.
  bid=$(cd "$probe" && bd q "probe bead for the hook" 2>/dev/null) ||
    { echo "error: cannot file a probe bead"; exit 1; }
  [ -n "$bid" ] || { echo "error: the probe bead has no id"; exit 1; }
  await_bead_ready "$probe" "$bid" || exit 1
  (cd "$probe" && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false -c "$hook" commit -m "probe commit for $bid" >/dev/null 2>&1) ||
    { echo "error: the hook rejected a commit naming $bid"; exit 1; }
  echo "source before rename" > "$probe/rename-source.txt" ||
    { echo "error: cannot write rename source"; exit 1; }
  (cd "$probe" && git add rename-source.txt && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit --no-verify -m "seed rename fixture" >/dev/null 2>&1) ||
    { echo "error: cannot seed rename fixture"; exit 1; }
  (cd "$probe" && git mv rename-source.txt harness/handoffs/renamed.md) ||
    { echo "error: cannot stage rename fixture"; exit 1; }
  out=$(cd "$probe" && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false -c "$hook" commit -m "probe renamed source without bead" 2>&1) &&
    { echo "error: the hook accepted a source rename into handoffs"; echo "$out"; exit 1; }
  echo "$out" | grep -q "names no bead" ||
    { echo "error: rename refusal never said why"; echo "$out"; exit 1; }'

# Overlay files are the project's to edit, so doctor reports an edited one as
# an overlay, never a shadow — a warning nobody can clear is the one that stops
# being read, and then the real drift hides behind it.
probe_step "doctor names edited seeds as overlays, not shadows" bash -c '
  golden_probe || exit 1
  echo "# local steps" >> "$probe/scripts/verify.steps.sh" ||
    { echo "error: cannot edit the steps file"; exit 1; }
  echo "# local scope" >> "$probe/scripts/review.scope.sh" ||
    { echo "error: cannot edit the scope file"; exit 1; }
  out=$(HARNESS_HOME="$PWD" "$probe/scripts/h" doctor 2>&1) ||
    { echo "error: doctor failed"; echo "$out"; exit 1; }
  echo "$out" | grep -q "overlay: scripts/verify.steps.sh" ||
    { echo "error: doctor never named the steps overlay"; echo "$out"; exit 1; }
  echo "$out" | grep -q "overlay: scripts/review.scope.sh" ||
    { echo "error: doctor never named the scope overlay"; echo "$out"; exit 1; }
  if echo "$out" | grep -q "shadow: scripts/verify.steps.sh\|shadow: scripts/review.scope.sh"; then
    echo "error: doctor called an overlay a shadow"; echo "$out"; exit 1;
  fi'

# The scope file is wired in, not decorative: a review that ignored it would
# keep reading the old inline scope, and the packet would carry files the
# project excluded — silently unreviewable in the other direction. The shared
# review runs through the probe's finder, reading the probe's own scope.
probe_step "review honors the scope overlay" bash -c '
  golden_probe || exit 1
  # --no-verify: the probe commit is scaffolding in a throwaway repo, and add
  # wired the bead-naming hook here. Its message names nothing real.
  (cd "$probe" && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false add -A &&
    git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit --no-verify -qm init) ||
    { echo "error: probe commit failed"; exit 1; }
  echo "scoped" >> "$probe/scoped.md" || { echo "error: cannot dirty a tracked doc"; exit 1; }
  echo "scoped" >> "$probe/scoped.py" || { echo "error: cannot dirty a tracked source"; exit 1; }
  { printf "%s\n" "SCOPE=(\"*.py\")" "CAPTURES=\"no-captures-here-*.png\"" > "$probe/scripts/review.scope.sh"; } ||
    { echo "error: cannot narrow the scope file"; exit 1; }
  out=$(HARNESS_HOME="$PWD" "$probe/scripts/h" review </dev/null 2>&1) ||
    { echo "error: review failed"; echo "$out"; exit 1; }
  packet=$(printf "%s" "$out" | grep -o "/tmp/[^ )]*" | head -1)
  [ -n "$packet" ] || { echo "error: review never printed the packet"; echo "$out"; exit 1; }
  grep -q "scoped.py" "$packet" || { echo "error: packet missed an in-scope file"; exit 1; }
  if grep -q "scoped.md" "$packet"; then
    echo "error: packet carried an out-of-scope file"; exit 1;
  fi'

# A gate with no project steps must not pass: "ok" from a suite that ran
# nothing is the silent success this project exists to avoid, in the check
# meant to catch it. The shared gate runs through the probe's finder.
probe_step "a missing steps overlay fails the gate loudly" bash -c '
  golden_probe || exit 1
  rm "$probe/scripts/verify.steps.sh" || { echo "error: cannot remove the steps file"; exit 1; }
  out=$(HARNESS_HOME="$PWD" "$probe/scripts/h" verify --quick 2>&1) &&
    { echo "error: the gate passed with no project steps"; echo "$out"; exit 1; }
  echo "$out" | grep -q "verify.steps.sh" ||
    { echo "error: the failure never named the missing file"; echo "$out"; exit 1; }'

# A reference install keeps no ledger-export-check.sh of its own, so the export
# probes run the shared one — the same script the gate runs — with the probe
# as its project, resolved through the probe's finder the way a real session
# resolves it.
probe_export_check() {
  local probe="$1" root
  root="$(probe_shared_root "$probe")" || return 1
  HARNESS_PROJECT="$probe" bash "$root/scripts/ledger-export-check.sh"
}
export -f probe_export_check

# Neither transport hydrates a fresh clone on its own: bd init with a
# configured remote starts an empty database without reading the committed
# export. So add imports it on fresh init — issues and memories both, and only
# then. Seeded here with one of each; recall proves the memories arrived.
probe_step "a fresh install hydrates the committed ledger export" bash -c '
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

# The export probe earns its place: a closed bead left open in the committed
# file fails the gate naming it, and the regen command from the message clears
# it. Setup polls for settle with a deadline - rapid bd invocations can read a
# snapshot from before the mutation landed, and an unasserted fixture would read
# as a probe that cannot see staleness. The delete path has its own probe
# below: bare `bd delete` only previews (exit 0, har-67c), so the fixture
# asserts the preview leaves the bead listed before deleting with --force.
# The deeper find from that bead: `bd config` and `bd info` auto-import a
# stale .beads/issues.jsonl when the ledger looks stale to them, resurrecting
# deleted beads — no timestamp guard can apply to a row that is missing
# locally. Closes only ever drift the other way (a stale row is skipped unless
# strictly newer), which is why the close probe above stayed green while a
# delete drift healed itself. Every harness prefix lookup now reads `bd list`
# instead, and the probe below trips if a future bd starts healing under those
# commands too.
probe_step "a stale ledger export fails the gate naming the bead" bash -c '
  golden_probe || exit 1
  bid=$(cd "$probe" && bd q "probe bead for a stale export" 2>/dev/null) ||
    { echo "error: cannot file a probe bead"; exit 1; }
  [ -n "$bid" ] || { echo "error: the probe bead has no id"; exit 1; }
  (cd "$probe" && bd export --include-memories -o .beads/issues.jsonl >/dev/null 2>&1) ||
    { echo "error: cannot write the probe export"; exit 1; }
  grep -qF "$bid" "$probe/.beads/issues.jsonl" ||
    { echo "error: the probe export missed the bead"; exit 1; }
  # Tracked like the dogfooded copy: the staleness path under test runs past
  # the untracked check, which would otherwise fail first without naming the
  # bead (har-l5a).
  (cd "$probe" && git add .beads/issues.jsonl >/dev/null 2>&1) ||
    { echo "error: cannot track the probe export"; exit 1; }
  (cd "$probe" && bd close "$bid" --reason "probe" >/dev/null 2>&1) ||
    { echo "error: cannot close the probe bead"; exit 1; }
  await_bead_closed "$probe" "$bid" || exit 1
  out=$(probe_export_check "$probe" 2>&1)
  echo "$out" | grep -q "FAIL  ledger export" || {
    st=$(probe_json_field "$probe" status) || st="unreadable"
    if [ "$st" != "closed" ]; then
      echo "error: the probe close reverted before the gate ran (status: $st)";
    else
      echo "error: the gate passed a stale ledger export";
    fi
    echo "$out"; exit 1; }
  echo "$out" | grep -qF "$bid" ||
    { echo "error: the failure never named the closed bead"; echo "$out"; exit 1; }
  echo "$out" | grep -q "bd export --include-memories" ||
    { echo "error: the failure never said how to regen"; echo "$out"; exit 1; }
  (cd "$probe" && bd export --include-memories -o .beads/issues.jsonl >/dev/null 2>&1) ||
    { echo "error: cannot regen the probe export"; exit 1; }
  out=$(probe_export_check "$probe" 2>&1)
  echo "$out" | grep -q "ok    ledger export" ||
    { echo "error: the gate still fails after a regen"; echo "$out"; exit 1; }'

# The commit itself keeps the export fresh: a bead filed and closed (plus a
# memory remembered) after the last regen, committed with no manual export,
# must land a committed export that names the drift and carries memories —
# and the worktree file must match it. Runs through the live hooks path
# (.beads/hooks, where the install appends the refresh after bd's own block),
# not just the .git/hooks delegation the commit-msg probe covers.
probe_step "a commit refreshes the ledger export without a manual regen" bash -c '
  golden_probe || exit 1
  (cd "$probe" && git add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit --no-verify -qm "seed install fixture" >/dev/null 2>&1) ||
    { echo "error: cannot seed-commit the install fixture"; exit 1; }
  grep -qF "scripts/hooks/pre-commit" "$probe/.beads/hooks/pre-commit" 2>/dev/null ||
    { echo "error: add never wired the pre-commit refresh into .beads/hooks"; exit 1; }
  [ -x "$probe/scripts/hooks/pre-commit" ] ||
    { echo "error: install produced no pre-commit hook logic"; exit 1; }
  bid=$(cd "$probe" && bd q "probe bead for a hook refresh" 2>/dev/null) ||
    { echo "error: cannot file a probe bead"; exit 1; }
  [ -n "$bid" ] || { echo "error: the probe bead has no id"; exit 1; }
  await_bead_ready "$probe" "$bid" || exit 1
  (cd "$probe" && bd close "$bid" --reason "probe" >/dev/null 2>&1) ||
    { echo "error: cannot close the probe bead"; exit 1; }
  await_bead_closed "$probe" "$bid" || exit 1
  (cd "$probe" && bd remember "probe hook refresh knowledge" >/dev/null 2>&1) ||
    { echo "error: cannot remember a probe memory"; exit 1; }
  echo "probe" > "$probe/probe-refresh.txt" || { echo "error: cannot dirty a probe file"; exit 1; }
  (cd "$probe" && git add -A >/dev/null 2>&1) ||
    { echo "error: cannot stage the probe work"; exit 1; }
  hook="core.hooksPath=$probe/.beads/hooks"
  (cd "$probe" && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false -c "$hook" commit -m "probe commit for $bid" >/dev/null 2>&1) ||
    { echo "error: the commit with a stale export failed"; exit 1; }
  (cd "$probe" && git show HEAD:.beads/issues.jsonl >"$probe/.probe-committed.jsonl" 2>/dev/null) ||
    { echo "error: the commit carries no ledger export"; exit 1; }
  grep -qF "$bid" "$probe/.probe-committed.jsonl" ||
    { echo "error: the committed export missed the probe bead — pre-commit never refreshed"; exit 1; }
  grep -q "probe hook refresh knowledge" "$probe/.probe-committed.jsonl" ||
    { echo "error: the committed export missed the probe memory — refresh dropped --include-memories"; exit 1; }
  cmp -s "$probe/.probe-committed.jsonl" "$probe/.beads/issues.jsonl" ||
    { echo "error: the hook left the worktree export dirty"; exit 1; }
  rm -f "$probe/.probe-committed.jsonl" ||
    { echo "error: cannot clean the probe comparison file"; exit 1; }
  out=$(probe_export_check "$probe" 2>&1)
  echo "$out" | grep -q "ok    ledger export" ||
    { echo "error: the gate still fails after a hook-refreshed commit"; echo "$out"; exit 1; }'

# The delete half of the drift the export check exists for: a deleted bead
# still sitting in the committed file fails the gate naming it, and the regen
# clears it. Opens by pinning the har-67c trap — bare `bd delete` only
# previews and exits 0, so the bead must still resolve there — then deletes
# with --force and polls until it stops resolving before asserting anything.
probe_step "a deleted bead still exported fails the gate naming the bead" bash -c '
  golden_probe || exit 1
  bid=$(cd "$probe" && bd q "probe bead for a deleted export" 2>/dev/null) ||
    { echo "error: cannot file a probe bead"; exit 1; }
  [ -n "$bid" ] || { echo "error: the probe bead has no id"; exit 1; }
  (cd "$probe" && bd export --include-memories -o .beads/issues.jsonl >/dev/null 2>&1) ||
    { echo "error: cannot write the probe export"; exit 1; }
  grep -qF "$bid" "$probe/.beads/issues.jsonl" ||
    { echo "error: the probe export missed the bead"; exit 1; }
  # Tracked like the dogfooded copy: the gone-line path under test runs past
  # the untracked check, which would otherwise fail first without naming the
  # bead (har-l5a).
  (cd "$probe" && git add .beads/issues.jsonl >/dev/null 2>&1) ||
    { echo "error: cannot track the probe export"; exit 1; }
  (cd "$probe" && bd delete "$bid" >/dev/null 2>&1) ||
    { echo "error: the preview delete failed"; exit 1; }
  (cd "$probe" && bd show "$bid" >/dev/null 2>&1) ||
    { echo "error: the preview delete deleted — bd changed its delete UX, update the skill rule"; exit 1; }
  (cd "$probe" && bd delete "$bid" --force >/dev/null 2>&1) ||
    { echo "error: cannot delete the probe bead"; exit 1; }
  await_bead_gone "$probe" "$bid" || exit 1
  out=$(probe_export_check "$probe" 2>&1)
  echo "$out" | grep -q "FAIL  ledger export" || {
    echo "error: the gate passed a deleted bead still in the export";
    echo "$out"; exit 1; }
  echo "$out" | grep -qF "$bid" ||
    { echo "error: the failure never named the deleted bead"; echo "$out"; exit 1; }
  (cd "$probe" && bd export --include-memories -o .beads/issues.jsonl >/dev/null 2>&1) ||
    { echo "error: cannot regen the probe export"; exit 1; }
  out=$(probe_export_check "$probe" 2>&1)
  echo "$out" | grep -q "ok    ledger export" ||
    { echo "error: the gate still fails after a regen"; echo "$out"; exit 1; }'

# The har-l5a path: an export with matching content but no git tracking reaches
# no fresh clone, so the gate fails saying untracked with the fix — and a
# `git add` clears it.
probe_step "an untracked ledger export fails the gate saying to track it" bash -c '
  golden_probe || exit 1
  (cd "$probe" && bd q "probe bead for an untracked export" >/dev/null 2>&1) ||
    { echo "error: cannot file a probe bead"; exit 1; }
  (cd "$probe" && bd export --include-memories -o .beads/issues.jsonl >/dev/null 2>&1) ||
    { echo "error: cannot write the probe export"; exit 1; }
  # Fresh installs stage the export at install time, so force the untracked
  # shape this probe exists for (har-l5a): matching content, no tracking.
  # --cached -f: the filed probe bead changed the worktree export after the
  # install staged it, and without -f git refuses a removal whose staged
  # content matches neither the file nor HEAD. Index-only either way.
  (cd "$probe" && git rm --cached -qf .beads/issues.jsonl >/dev/null 2>&1) || true
  out=$(probe_export_check "$probe" 2>&1)
  echo "$out" | grep -q "FAIL  ledger export" || {
    echo "error: the gate passed an untracked ledger export";
    echo "$out"; exit 1; }
  echo "$out" | grep -q "untracked" ||
    { echo "error: the failure never said untracked"; echo "$out"; exit 1; }
  echo "$out" | grep -q "git add .beads/issues.jsonl" ||
    { echo "error: the failure never said how to track it"; echo "$out"; exit 1; }
  (cd "$probe" && git add .beads/issues.jsonl >/dev/null 2>&1) ||
    { echo "error: cannot track the probe export"; exit 1; }
  out=$(probe_export_check "$probe" 2>&1)
  echo "$out" | grep -q "ok    ledger export" ||
    { echo "error: the gate still fails after tracking"; echo "$out"; exit 1; }'

# An empty install has no export and nothing to carry: the probe passes rather
# than failing a project that did nothing wrong.
probe_step "an empty install passes the ledger export check" bash -c '
  golden_probe || exit 1
  out=$(probe_export_check "$probe" 2>&1)
  if echo "$out" | grep -q "FAIL  ledger export"; then
    echo "error: the gate failed an empty ledger"; echo "$out"; exit 1;
  fi
  echo "$out" | grep -q "ledger export" ||
    { echo "error: the check never ran on an empty ledger"; echo "$out"; exit 1; }'

# A fresh clone carries the committed export without the gitignored Dolt
# working set behind it. The probe skips that shape out loud instead of failing
# on an export command that cannot work before hydration.
probe_step "a clone with no live ledger skips the export check" bash -c '
  golden_probe || exit 1
  (cd "$probe" && bd q "probe bead" >/dev/null 2>&1) ||
    { echo "error: cannot file a probe bead"; exit 1; }
  (cd "$probe" && bd export --include-memories -o .beads/issues.jsonl >/dev/null 2>&1) ||
    { echo "error: cannot write the probe export"; exit 1; }
  rm -rf "$probe/.beads/embeddeddolt" || { echo "error: cannot remove the probe database"; exit 1; }
  out=$(probe_export_check "$probe" 2>&1)
  if echo "$out" | grep -q "FAIL  ledger export"; then
    echo "error: the gate failed a clone with no live ledger"; echo "$out"; exit 1;
  fi
  echo "$out" | grep -q "no live ledger, skipping" ||
    { echo "error: the skip never said itself"; echo "$out"; exit 1; }'

if [ "$mode" != "--quick" ]; then
  step "cli lists commands" bash -c 'bin/harness | grep -q "^  add"'
fi

