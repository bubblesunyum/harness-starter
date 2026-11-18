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

# The gate usually arrives through `scripts/harness verify`, which exports the
# dispatch environment for the shared scripts. Every probe below builds its
# own fixture and must resolve its own project and harness, so none inherits it.
unset HARNESS_PROJECT HARNESS_ROOT HARNESS_SOURCE

# There is no compiler here, so the gate is what a compiler would have caught:
# every script parses, and the CLI can still list its own commands. Cheap enough
# that there's no excuse for skipping it.

# Reference probes resolve the harness through the finder — installs, the
# commit-msg shim, and scripts/harness dispatch all go through it — so they need the
# checkout. The gate runs here, in the starter itself, hence one export rather
# than an inline assignment on every probe command.
export HARNESS_HOME="$PWD"

probe_step --when "bin/* commands/add.sh commands/lib/* template/scripts/harness template/scripts/h template/stubs/* template/scripts/codex-support.py" "codex install context" python3 scripts/test-codex-install.py
probe_step --when "bin/* commands/add.sh commands/lib/* template/scripts/harness template/scripts/h template/stubs/*" "project contract and export policy" python3 scripts/test-contract-overrides.py
# finder and contract split read the whole template/ (session output, every
# file scanned for fill-in blocks), so no path list is narrow enough: always run.
probe_step "finder resolution" bash scripts/test-finder.sh
probe_step "contract split" bash scripts/test-contract-split.sh
probe_step --when "bin/* commands/add.sh commands/lib/* template/scripts/harness template/scripts/h template/stubs/* template/harness/* template/harness/evals/* scripts/harness scripts/verify.steps.sh scripts/review.scope.sh dashboard.toml" "reference install" bash scripts/test-reference-add.sh
probe_step --when "bin/* commands/migrate.sh commands/add.sh commands/lib/* template/scripts/harness template/scripts/h template/stubs/*" "migrate a copied install" bash scripts/test-migrate.sh

# The starter runs by reference: its finder resolves to its own template/
# first, so editing a template file takes effect in the next `scripts/harness`
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
  cp "$PWD/scripts/harness" "$scratch/scripts/harness" ||
    { echo "error: cannot copy finder"; exit 1; }
  chmod +x "$scratch/scripts/harness" || { echo "error: cannot chmod finder"; exit 1; }
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
  out="$(env -u HARNESS_HOME HOME="$scratch/no-home" HARNESS_URL="file:///nonexistent-probe" "$scratch/scripts/harness" models 2>&1 || true)"
  echo "$out" | grep -q "probe-marker-12345" ||
    { echo "error: edited template did not take effect"; echo "$out"; exit 1; }'

step "shell parses" bash -c '
  set -e
  for f in bin/harness commands/*.sh commands/lib/*.sh scripts/*.sh scripts/hooks/* \
           scripts/harness template/scripts/*.sh template/scripts/hooks/* \
           template/scripts/lib/*.sh template/scripts/harness template/stubs/scripts/hooks/*; do
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
#
# The build is cached per checkout under .tmp/golden-cache (gitignored — skill
# symlinks are absolute, so sharing entries across checkouts would serve the
# wrong tree). The key derives from what the install reads: the modes,
# contents and names of the files git lists under template commands bin — the
# installer predicate at commands/lib/install.sh, plus commands/ and bin/ for
# the installer logic itself — salted with the bd, git and python3 versions.
# Names come from one bulk `git ls-files --cached --others --exclude-standard
# -z` (tracked plus untracked-non-ignored, no index hashes); modes from one
# bulk stat and contents from one bulk shasum over those working-tree files,
# each sorted so the merge is deterministic. Keying the working tree is the
# point: the index knows nothing of unstaged edits, so an index key serves a
# stale HIT over the normal edit-then-gate flow. Never
# a hand-maintained file list, and never a bare hash-and-copy: two gates
# racing populate-vs-read serialize on a lock (flock where it exists, a mkdir
# spin where it does not, macOS ships no flock), the store publishes
# atomically (copy to a stage dir, rename into place) with the newest 5
# entries kept, and every HIT still proves itself — a sentinel written at
# store time carrying the key and the checkout top, a byte-compare of the
# installed finder against its template source, and a bd list smoke in the
# HIT copy. A tripwire failure, including a checkout-top mismatch (the tree
# moved under a warm cache), clears the poisoned entry and fails loudly; the
# retry is a clean MISS rebuild. A mkdir lock left by a dead holder is stolen
# with a warning; a lock held by a live gate past the 30s ceiling falls back
# to an uncached build — green and slow, never red.
golden_cache_dir() {
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  printf '%s/.tmp/golden-cache\n' "$top"
}

golden_cache_key() {
  # Key over the WORKING TREE uniformly: one bulk name list from git, one
  # bulk stat for modes, one bulk shasum for contents, all sorted, then the
  # version salts. The list travels through a temp file — never a variable,
  # which cannot hold the NULs `ls-files -z` emits. Empty list or any
  # list/stat/sum failure returns 1 (the caller builds uncached), never a key
  # over nothing.
  local top="$1" list modes sums rc
  list="$(mktemp 2>/dev/null)" || return 1
  modes="$(mktemp 2>/dev/null)" || { rm -f "$list"; return 1; }
  sums="$(mktemp 2>/dev/null)" || { rm -f "$list" "$modes"; return 1; }
  git -C "$top" ls-files --cached --others --exclude-standard -z -- template commands bin >"$list" 2>/dev/null ||
    { rm -f "$list" "$modes" "$sums"; return 1; }
  if [ ! -s "$list" ]; then
    echo "error: git lists no files under template commands bin — cannot key the golden cache" >&2
    rm -f "$list" "$modes" "$sums"
    return 1
  fi
  if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    (cd "$top" && xargs -0 stat -f '%Lp %N' <"$list" 2>/dev/null | sort >"$modes") ||
      { rm -f "$list" "$modes" "$sums"; return 1; }
  else
    (cd "$top" && xargs -0 stat -c '%a %n' <"$list" 2>/dev/null | sort >"$modes") ||
      { rm -f "$list" "$modes" "$sums"; return 1; }
  fi
  if [ ! -s "$modes" ]; then rm -f "$list" "$modes" "$sums"; return 1; fi
  (cd "$top" && xargs -0 shasum <"$list" 2>/dev/null | sort >"$sums") ||
    { rm -f "$list" "$modes" "$sums"; return 1; }
  if [ ! -s "$sums" ]; then rm -f "$list" "$modes" "$sums"; return 1; fi
  {
    cat "$modes"
    cat "$sums"
    printf 'bd: %s\n' "$(bd --version 2>/dev/null || echo no-bd)"
    printf 'git: %s\n' "$(git --version 2>/dev/null || echo no-git)"
    printf 'python3: %s\n' "$(python3 --version 2>&1 || echo no-python3)"
  } | shasum | cut -d' ' -f1
  rc=$?
  rm -f "$list" "$modes" "$sums"
  return $rc
}

# Serialize one cache fetch-or-build. Prefers flock, which the kernel releases
# if the holder dies; without it (macOS) a mkdir spin with a 30s ceiling. The
# mkdir branch writes the holder PID into $dir.lock/pid on acquisition. On
# contention a lock whose pid file is missing or unreadable, whose PID is dead
# (kill -0), or which is older than 15 minutes is stolen with a loud warning
# (rm the pid, rmdir, loop around and take it over). A lock held by a live
# gate spins as before, but expiry returns 2 (vs 1 for errors) so the caller
# can stay green with an uncached build instead of failing red. No traps here:
# a trap would fight the gate reaps, and traps cannot cover kill -9 anyway —
# the PID file does.
golden_cache_lock() {
  local dir="$1" tries holder steal
  GOLDEN_LOCK_MODE=""
  GOLDEN_LOCK_DIR="$dir"
  if command -v flock >/dev/null 2>&1; then
    : > "$dir.lockfile" 2>/dev/null || return 1
    exec 9>"$dir.lockfile" || return 1
    flock 9 || { exec 9>&-; return 1; }
    GOLDEN_LOCK_MODE="flock"
    return 0
  fi
  tries=0
  while true; do
    if mkdir "$dir.lock" 2>/dev/null; then
      printf '%s\n' "$$" > "$dir.lock/pid" 2>/dev/null || true
      GOLDEN_LOCK_MODE="mkdir"
      return 0
    fi
    # Contention. A missing pid may only mean the winner has not written it
    # yet, so grace-sleep and re-read before calling it stale.
    holder="$(cat "$dir.lock/pid" 2>/dev/null)" || holder=""
    if [ -z "$holder" ]; then
      sleep 0.2
      holder="$(cat "$dir.lock/pid" 2>/dev/null)" || holder=""
    fi
    steal=0
    case "$holder" in
      ''|*[!0-9]*) steal=1;;
      *) kill -0 "$holder" 2>/dev/null || steal=1;;
    esac
    if [ "$steal" = "0" ] && [ -n "$(find "$dir.lock" -mmin +15 2>/dev/null)" ]; then
      steal=1
    fi
    if [ "$steal" = "1" ]; then
      echo "warning: stealing a stale golden cache lock at $dir.lock (holder ${holder:-missing}) — removing it and taking over"
      rm -f "$dir.lock/pid" 2>/dev/null || true
      if rmdir "$dir.lock" 2>/dev/null; then
        continue
      fi
      # Lost a race: someone else stole it or the holder finished. Back off
      # and re-evaluate; bounded so a junk-filled lock dir fails loudly.
      sleep 0.2
      tries=$((tries + 1))
      if [ "$tries" -ge 150 ]; then
        echo "error: cannot take the golden cache lock at $dir.lock"
        return 1
      fi
      continue
    fi
    sleep 0.2
    tries=$((tries + 1))
    if [ "$tries" -ge 150 ]; then
      return 2
    fi
  done
}

golden_cache_unlock() {
  if [ "${GOLDEN_LOCK_MODE:-}" = "flock" ]; then
    exec 9>&-
  elif [ "${GOLDEN_LOCK_MODE:-}" = "mkdir" ]; then
    rm -f "${GOLDEN_LOCK_DIR:-}.lock/pid" 2>/dev/null || true
    rmdir "${GOLDEN_LOCK_DIR:-}.lock" 2>/dev/null || true
  fi
  GOLDEN_LOCK_MODE=""
  GOLDEN_LOCK_DIR=""
}

# Keep the newest 5 entries; anything else under the lock is a leftover stage
# from a killed run (the live stager holds the lock), so stages go too.
golden_cache_evict() {
  local cache="$1" n d
  # Plain ls never yields dotfiles, so sweep dead stages directly: anything
  # still here under the lock is a leftover — the live stager holds the lock,
  # and our own stage already renamed into place before this runs.
  rm -rf "$cache"/.stage-* 2>/dev/null || true
  n=0
  for d in $(ls -t "$cache" 2>/dev/null); do
    case "$d" in
      .lock|.lockfile) continue;;
    esac
    [ -d "$cache/$d" ] || continue
    n=$((n + 1))
    if [ "$n" -gt 5 ]; then
      rm -rf "$cache/$d" || true
    fi
  done
}

# Fresh reference install of this tree into a new GOLDEN dir. Owns no lock:
# callers hold it (or hold none) and unlock on failure. Cleans its own dirs on
# failure, with the same messages as the pre-cache install.
golden_install_fresh() {
  # Reference install of this tree: the harness must resolve without the
  # network, and the real ~/.harness is never consulted. HOME is overridden
  # inline — never exported — so the rest of the gate keeps its own.
  GOLDEN="$(mktemp -d)" || { echo "error: mktemp failed"; return 1; }
  GOLDEN_HOME="$(mktemp -d)" || { echo "error: mktemp failed"; rm -rf "$GOLDEN"; return 1; }
  HARNESS_HOME="$PWD" HOME="$GOLDEN_HOME" bin/harness add "$GOLDEN" >/dev/null 2>&1 || {
    echo "error: harness add failed for the golden fixture"
    rm -rf "$GOLDEN" "$GOLDEN_HOME"
    return 1
  }
  return 0
}

# HIT path under the lock: prove the entry tripwires into a fresh GOLDEN copy.
# Returns 0 on a HIT, 1 after clearing a poisoned entry (caller fails loudly),
# 2 on a local error that keeps the entry (caller fails without STALE status).
# Same messages and same entry-clearing as the inline tripwires before it.
golden_hit_copy() {
  local entry="$1" key="$2" top="$3" sentinel_key sentinel_top
  sentinel_key="$(sed -n '1p' "$entry/.golden-sentinel" 2>/dev/null)"
  sentinel_top="$(sed -n '2p' "$entry/.golden-sentinel" 2>/dev/null)"
  if [ "$sentinel_key" != "$key" ]; then
    rm -rf "$entry"
    unset GOLDEN
    echo "error: the golden cache entry for key $key is torn (sentinel mismatch) — cleared it, re-run the gate to rebuild"
    return 1
  fi
  if [ "$sentinel_top" != "$top" ]; then
    rm -rf "$entry"
    unset GOLDEN
    echo "error: the golden cache entry for key $key is stale (checkout moved from ${sentinel_top:-unknown} to $top) — cleared it, re-run the gate to rebuild"
    return 1
  fi
  GOLDEN="$(mktemp -d)" || { echo "error: mktemp failed"; return 2; }
  if ! cp -R "$entry/." "$GOLDEN/" 2>/dev/null; then
    echo "error: cannot copy the golden cache entry for key $key into $GOLDEN"
    rm -rf "$GOLDEN"
    unset GOLDEN
    return 2
  fi
  # The sentinel proves the entry, it is not part of the fixture: a HIT copy
  # carries exactly what a fresh install would.
  rm -f "$GOLDEN/.golden-sentinel"
  git init -q "$GOLDEN" 2>/dev/null || {
    echo "error: git init failed in $GOLDEN"
    rm -rf "$GOLDEN"
    unset GOLDEN
    return 2
  }
  if ! cmp -s "$GOLDEN/scripts/harness" "$top/template/scripts/harness"; then
    rm -rf "$entry" "$GOLDEN"
    unset GOLDEN
    echo "error: the golden cache entry for key $key is stale (scripts/harness no longer matches template) — cleared it, re-run the gate to rebuild"
    return 1
  fi
  if ! (cd "$GOLDEN" && bd list --json --all >/dev/null 2>&1); then
    rm -rf "$entry" "$GOLDEN"
    unset GOLDEN
    echo "error: the golden cache entry for key $key is stale (bd list fails in the HIT copy) — cleared it, re-run the gate to rebuild"
    return 1
  fi
  return 0
}

# MISS publish under the lock: copy GOLDEN to a stage dir, write the sentinel
# (key beside checkout top), rename into place, evict the oldest. A store
# failure warns and stays green — the MISS build itself is already good.
golden_publish() {
  local cache="$1" entry="$2" key="$3" top="$4" stage
  stage="$cache/.stage-$$"
  rm -rf "$stage"
  if mkdir -p "$stage" 2>/dev/null &&
     cp -R "$GOLDEN/." "$stage/" 2>/dev/null &&
     printf '%s\n' "$key" "$top" > "$stage/.golden-sentinel" 2>/dev/null &&
     rm -rf "$entry" && mv "$stage" "$entry" 2>/dev/null; then
    # Recency bump for the ls -t LRU in golden_cache_evict: the fresh entry
    # must read as newest or the evict below could reap what it just stored.
    touch "$entry" 2>/dev/null || true
    golden_cache_evict "$cache"
  else
    echo "warning: cannot store the golden cache entry for key $key — continuing uncached"
    rm -rf "$stage"
  fi
}

build_golden() {
  local top cache key entry rc
  GOLDEN_CACHE_STATUS=""
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=""
  cache=""
  key=""
  if [ -n "$top" ]; then
    cache="$(golden_cache_dir)" || cache=""
  fi
  if [ -n "$cache" ] && key="$(golden_cache_key "$top")" && [ -n "$key" ]; then
    mkdir -p "$cache" 2>/dev/null || cache=""
  else
    cache=""
    key=""
  fi
  case "$key" in ''|*[!0-9a-f]*) cache=""; key="";; esac
  if [ -z "$cache" ]; then
    # Unkeyable tree or unwritable cache: today's behavior, no cache at all.
    echo "golden fixture cache MISS (uncached)"
    GOLDEN_CACHE_STATUS="MISS (uncached)"
    golden_install_fresh || return 1
    return 0
  fi
  entry="$cache/$key"
  golden_cache_lock "$cache"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    # A live gate holds the lock past the ceiling: stay green and slow with a
    # fully uncached build rather than failing red on a race.
    echo "warning: the golden cache lock is held by a live gate — building uncached instead of waiting"
    echo "golden fixture cache MISS (uncached)"
    GOLDEN_CACHE_STATUS="MISS (uncached)"
    golden_install_fresh || return 1
    return 0
  elif [ "$rc" -ne 0 ]; then
    return 1
  fi
  if [ -d "$entry" ]; then
    golden_hit_copy "$entry" "$key" "$top"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      # Recency bump for the ls -t LRU in golden_cache_evict: a HIT must read
      # as new or an old hot entry ages out under newer cold ones.
      touch "$entry" 2>/dev/null || true
      echo "golden fixture cache HIT key=$key"
      GOLDEN_CACHE_STATUS="HIT key=$key"
      golden_cache_unlock
      return 0
    elif [ "$rc" -eq 1 ]; then
      GOLDEN_CACHE_STATUS="STALE key=$key (entry cleared)"
      golden_cache_unlock
      return 1
    else
      golden_cache_unlock
      return 1
    fi
  fi
  # MISS: the same install as before the cache existed, then an atomic publish.
  golden_install_fresh || { golden_cache_unlock; return 1; }
  golden_publish "$cache" "$entry" "$key" "$top"
  echo "golden fixture cache MISS key=$key"
  GOLDEN_CACHE_STATUS="MISS key=$key"
  golden_cache_unlock
  return 0
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

# One failure path for every scenario below: the name up front says which
# scenario broke, the message says which sub-case, and the captured output
# follows only when there is any — no pasted command text. Exported like
# golden_probe because each step runs in its own bash -c child.
probe_fail() { echo "error: ${PROBE_SCENARIO:-probe}: $1"; [ -n "${out:-}" ] && printf '%s\n' "$out"; exit 1; }
export -f probe_fail

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
  # Which lane the cache took, beside the step line: the body output above is
  # swallowed into the step log, and HIT-vs-MISS is what the next reader asks.
  [ -n "${GOLDEN_CACHE_STATUS:-}" ] && echo "  golden cache ${GOLDEN_CACHE_STATUS}"
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
  HARNESS_HOME="$PWD" "$1/scripts/harness" root 2>/dev/null || {
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
probe_step --when "bin/* commands/add.sh commands/lib/* template/*" "placeholders substitute" bash -c '
  # Each step checked on its own. An && chain here reports ok when its own setup
  # failed: probe would be empty, the install would never run, grep would find
  # nothing to complain about, and the gate would pass vacuously — which is the
  # silent success this project exists to avoid, in the check meant to catch it.
  golden_probe || exit 1
  [ -f "$probe/scripts/harness" ] || { echo "error: install produced no finder"; exit 1; }
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
probe_step --when "bin/* commands/update.sh commands/diverge.sh" "retired commands print their pointer and exit 2" bash -c '
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

# One copy proves both session separation and the findings append: two sessions write separate live files, brief names the unclosed journal, close and the hook reap only the closer, and a finding lands with its category.
probe_step --when "template/scripts/lib/journal.sh template/scripts/hooks/commit-msg template/stubs/scripts/hooks/commit-msg template/scripts/brief.sh commands/lib/*" "learning loop journal and findings" bash -c '
PROBE_SCENARIO="learning loop journal and findings"
golden_probe || probe_fail "no golden fixture"
root="$(probe_shared_root "$probe")" || probe_fail "finder cannot resolve the harness"
jl="$root/scripts/lib/journal.sh"
HARNESS_HOME="$PWD" "$probe/scripts/harness" link >/dev/null 2>&1 || probe_fail "cannot link the probe install"
(cd "$probe" && git check-ignore -q harness/handoffs/.live-probe-a.md) || probe_fail "live journal files are not gitignored after link"
HARNESS_SESSION_ID=probe-a HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" bash "$jl" event verify "FAILED probe-build" || probe_fail "session-a journal write failed"
HARNESS_SESSION_ID=probe-b HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" bash "$jl" event verify "passed" || probe_fail "session-b journal write failed"
[ -f "$probe/harness/handoffs/.live-probe-a.md" ] || probe_fail "session-a live file missing"
[ -f "$probe/harness/handoffs/.live-probe-b.md" ] || probe_fail "sessions share one live file"
grep -q "FAILED probe-build" "$probe/harness/handoffs/.live-probe-a.md" || probe_fail "failing run never landed in the live file"
out=$(HARNESS_HOME="$PWD" HARNESS_PROJECT="$probe" HARNESS_SESSION_ID=probe-c "$probe/scripts/harness" brief 2>&1) || probe_fail "brief failed in the probe"
echo "$out" | grep -q "probe-a" || probe_fail "brief never named the unclosed journal"
HARNESS_SESSION_ID=probe-a HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" bash "$jl" close || probe_fail "session-a close failed"
[ ! -e "$probe/harness/handoffs/.live-probe-a.md" ] || probe_fail "session-a live file survives its own close"
[ -f "$probe/harness/handoffs/.live-probe-b.md" ] || probe_fail "session-a close removed the session-b live file"
printf "# probe note\n" > "$probe/harness/handoffs/note-probe.md" || probe_fail "cannot plant the probe handoff note"
# The hook half needs its own unclosed journal: the direct close above already reaped session-a, so write again, then the hook close must reap only the closer.
HARNESS_SESSION_ID=probe-a HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" bash "$jl" event verify "passed" || probe_fail "session-a journal rewrite failed"
[ -f "$probe/harness/handoffs/.live-probe-a.md" ] || probe_fail "rewritten live file missing before the hook close"
(cd "$probe" && git reset -q .beads/issues.jsonl 2>/dev/null || true; git add harness/handoffs/note-probe.md && printf "probe close\n" > .tmp-probe-msg && HARNESS_SESSION_ID=probe-a HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" bash "$root/scripts/hooks/commit-msg" .tmp-probe-msg; rc=$?; rm -f .tmp-probe-msg; [ $rc -eq 0 ]) || probe_fail "hook close failed"
[ ! -e "$probe/harness/handoffs/.live-probe-a.md" ] || probe_fail "session-a live file survives its hook close"
[ -f "$probe/harness/handoffs/.live-probe-b.md" ] || probe_fail "hook close removed the session-b live file"
HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" bash "$jl" finding --category probe-slug --reviewer reviewer-taste --bead probe-1 --outcome accepted --note "probe finding" || probe_fail "finding append failed"
python3 - "$probe/harness/learning.jsonl" <<PYEOF || probe_fail "finding never landed with its category"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip() and not l.startswith("#")]
assert rows and rows[-1].get("category") == "probe-slug", rows
PYEOF
'

# Skip and fail-soft share one copy with a stubbed gate: --no-reflect skips out loud and a dead reflector warns and continues. Prose-only reads as zero candidates with a note, never REFLECTOR_FAILED. Verify is stubbed here because the reflector is under test, not the gate, keeping the scenario under time.
probe_step --when "template/scripts/wrap-up.sh template/scripts/reflect.sh template/.claude/agents/reflector.md template/scripts/lib/journal.sh template/scripts/harness" "reflect skips and fails soft" bash -c '
PROBE_SCENARIO="reflect skips and fails soft"
golden_probe || probe_fail "no golden fixture"
top="$PWD"
HARNESS_HOME="$top" "$probe/scripts/harness" link >/dev/null 2>&1 || probe_fail "cannot link the probe install"
printf "%s\n" "step \"probe build\" true" > "$probe/scripts/verify.steps.sh" || probe_fail "cannot plant trivial steps"
printf "%s\n" "#!/bin/bash" "exit 0" > "$probe/scripts/verify.sh" || probe_fail "cannot plant the gate stub"
chmod +x "$probe/scripts/verify.sh" || probe_fail "cannot chmod the gate stub"
(cd "$probe" && git add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit --no-verify -qm init) || probe_fail "probe init commit failed"
bid=$(cd "$probe" && bd create "probe reflect skips" --design d --acceptance a --silent 2>/dev/null) || probe_fail "cannot file a probe bead"
await_bead_ready "$probe" "$bid" || probe_fail "probe bead never resolved"
echo "probe work" > "$probe/probe-work.txt" || probe_fail "cannot dirty the probe"
out=$(cd "$probe" && env -u OPENCODE_BIN HARNESS_HOME="$top" HARNESS_SESSION_ID=probe-flag "$probe/scripts/harness" wrap-up --quick --no-push --no-reflect -m "probe no-reflect close $bid" --bead "$bid" 2>&1) || probe_fail "wrap-up failed with --no-reflect"
echo "$out" | grep -q "reflect skipped (--no-reflect)" || probe_fail "--no-reflect never said it skipped"
if echo "$out" | grep -q "reflector proposed"; then probe_fail "--no-reflect still ran the reflector"; fi
echo "more probe work" >> "$probe/probe-work.txt" || probe_fail "cannot dirty the probe again"
printf "%s\n" "#!/usr/bin/env python3" "import sys" "a=sys.argv[1:]" "if a[:1]==[\"--version\"]:" "    print(\"opencode 2.0.0\")" "else:" "    sys.stderr.write(\"fake opencode: no model here\")" "    sys.exit(1)" > "$probe/opencode" || probe_fail "cannot plant failing fake opencode"
chmod +x "$probe/opencode" || probe_fail "cannot chmod the fake"
out=$(cd "$probe" && env -u OPENCODE_SESSION_ID -u OPENCODE_BIN HARNESS_HOME="$top" PATH="$probe:$PATH" HARNESS_SESSION_ID=probe-fail "$probe/scripts/harness" wrap-up --quick --no-push -m "probe failed-reflect close $bid" --bead "$bid" 2>&1) || probe_fail "wrap-up failed when the reflector failed"
echo "$out" | grep -q "continuing without candidates" || probe_fail "reflector failure never warned and continued"
# A prose-only reply is zero candidates with a note, never REFLECTOR_FAILED.
# Direct reflect.sh keeps this under time: same agent stub as the wrap-up
# probes, without another close cycle.
root="$(probe_shared_root "$probe")" || probe_fail "finder cannot resolve the harness"
printf "%s\n" "#!/usr/bin/env python3" "import json,os,sys" "a=sys.argv[1:]" "if a[:1]==[\"--version\"]:" "    print(\"opencode 2.0.0\")" "else:" "    print(json.dumps({\"type\":\"text\",\"part\":{\"text\":os.environ[\"FAKE_CANDIDATE\"]},\"sessionID\":\"ses_probe\"}))" > "$probe/opencode" || probe_fail "cannot plant prose fake opencode"
chmod +x "$probe/opencode" || probe_fail "cannot chmod the prose fake"
out=$(cd "$probe" && env -u OPENCODE_SESSION_ID -u OPENCODE_BIN HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" PATH="$probe:$PATH" OPENCODE_CONFIG_CONTENT="{\"agent\":{}}" HARNESS_SESSION_ID=probe-prose FAKE_CANDIDATE="just some prose, no json here" bash "$root/scripts/reflect.sh" 2>&1) || probe_fail "reflect failed on a prose-only reply"
if echo "$out" | grep -q "REFLECTOR_FAILED"; then probe_fail "prose-only reply read as REFLECTOR_FAILED"; fi
echo "$out" | grep -q "prose only" || probe_fail "prose-only reply never noted it held prose only"
echo "$out" | grep -q "^CANDIDATES " || probe_fail "prose-only reply never printed the candidates line"
_cands=$(echo "$out" | sed -n "s/^CANDIDATES //p" | head -1)
[ -n "$_cands" ] || probe_fail "no candidates path from prose-only reflect"
[ ! -s "$_cands" ] || probe_fail "prose-only reply left candidates behind"
'
# Native reflector in one copy: with OPENCODE_SESSION_ID set the real reflect.sh says to run the reflector natively instead of calling out. Wrap-up forwards this line verbatim, so calling reflect.sh directly keeps the scenario under time. The packet diff covers session-start..work, and harness reflect previews without writing learning rows; the handoff skill documents that flow.
probe_step --when "template/scripts/reflect.sh template/.claude/agents/reflector.md template/scripts/lib/journal.sh template/scripts/harness template/.claude/skills/handoff/SKILL.md" "reflect runs native in opencode" bash -c '
PROBE_SCENARIO="reflect runs native in opencode"
golden_probe || probe_fail "no golden fixture"
top="$PWD"
root="$(probe_shared_root "$probe")" || probe_fail "finder cannot resolve the harness"
HARNESS_HOME="$top" "$probe/scripts/harness" link >/dev/null 2>&1 || probe_fail "cannot link the probe install"
(cd "$probe" && git add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit --no-verify -qm init) || probe_fail "probe init commit failed"
echo "native probe work" > "$probe/probe-work.txt" || probe_fail "cannot dirty the probe"
out=$(cd "$probe" && HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" OPENCODE_SESSION_ID=probe-native bash "$root/scripts/reflect.sh" 2>&1) || probe_fail "reflector failed on the native path"
echo "$out" | grep -q "REFLECTOR_NATIVE" || probe_fail "native path never said to run the reflector natively"
# The packet diff sees work committed after the journal first wrote: journal
# first (records the start rev), commit, then the packet must carry it.
HARNESS_SESSION_ID=probe-native HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" bash "$root/scripts/lib/journal.sh" event verify "passed" || probe_fail "probe journal write failed"
echo "committed probe work probe-commit-marker-1" > "$probe/probe-committed.md" || probe_fail "cannot plant the committed file"
(cd "$probe" && git add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit --no-verify -qm "probe committed work") || probe_fail "probe committed commit failed"
echo "uncommitted probe work" > "$probe/probe-uncommitted.md" || probe_fail "cannot dirty the probe after commit"
out=$(cd "$probe" && HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" HARNESS_SESSION_ID=probe-native bash "$root/scripts/reflect.sh" --packet-only 2>&1) || probe_fail "packet-only reflect failed"
pkt=$(echo "$out" | sed -n "s/^PACKET //p" | head -1) || probe_fail "no PACKET line from reflect"
[ -n "$pkt" ] && [ -f "$pkt" ] || probe_fail "packet file missing: $pkt"
grep -q "probe-commit-marker-1" "$pkt" || probe_fail "packet diff misses work committed after session start"
grep -q "session start" "$pkt" || probe_fail "packet label never says which base it used"
# harness reflect previews: prints candidates and the file path, writes
# nothing to learning.jsonl.
before=0
[ -f "$probe/harness/learning.jsonl" ] && before=$(grep -c . "$probe/harness/learning.jsonl" || true)
out=$(cd "$probe" && HARNESS_HOME="$top" HARNESS_PROJECT="$probe" OPENCODE_SESSION_ID=probe-native "$probe/scripts/harness" reflect 2>&1) || probe_fail "harness reflect preview failed"
echo "$out" | grep -q "^PACKET " || probe_fail "harness reflect never printed the packet line"
echo "$out" | grep -q "^CANDIDATES " || probe_fail "harness reflect never printed the candidates line"
after=0
[ -f "$probe/harness/learning.jsonl" ] && after=$(grep -c . "$probe/harness/learning.jsonl" || true)
[ "$after" = "$before" ] || probe_fail "harness reflect wrote learning rows on preview"
# The handoff skill documents preview-then-keep.
grep -q "scripts/harness reflect" "$root/.claude/skills/handoff/SKILL.md" || probe_fail "handoff skill never documents harness reflect"
grep -q -- "--candidates-file" "$root/.claude/skills/handoff/SKILL.md" || probe_fail "handoff skill never documents --candidates-file"
grep -q -- "--keep-lesson" "$root/.claude/skills/handoff/SKILL.md" || probe_fail "handoff skill never documents --keep-lesson"
'


# Propose path in one copy with a stubbed gate: fake opencode returns two candidates, wrap-up keeps one (the other logs unreviewed), learning log and export carry it. Reviewed closes log kept/dropped, brief pressure counts only kept, and a failed keyed remember logs failed. Same stub reason as above.
probe_step --when "template/scripts/wrap-up.sh template/scripts/reflect.sh template/.claude/agents/reflector.md template/scripts/lib/journal.sh template/scripts/brief.sh template/scripts/harness" "reflect proposes a lesson and logs it kept" bash -c '
PROBE_SCENARIO="reflect proposes a lesson and logs it kept"
golden_probe || probe_fail "no golden fixture"
top="$PWD"
root="$(probe_shared_root "$probe")" || probe_fail "finder cannot resolve the harness"
HARNESS_HOME="$top" "$probe/scripts/harness" link >/dev/null 2>&1 || probe_fail "cannot link the probe install"
printf "%s\n" "step \"probe build\" true" > "$probe/scripts/verify.steps.sh" || probe_fail "cannot plant trivial steps"
printf "%s\n" "#!/bin/bash" "exit 0" > "$probe/scripts/verify.sh" || probe_fail "cannot plant the gate stub"
chmod +x "$probe/scripts/verify.sh" || probe_fail "cannot chmod the gate stub"
(cd "$probe" && git add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit --no-verify -qm init) || probe_fail "probe init commit failed"
bid=$(cd "$probe" && bd create "probe reflect work" --design d --acceptance a --silent 2>/dev/null) || probe_fail "cannot file a probe bead"
await_bead_ready "$probe" "$bid" || probe_fail "probe bead never resolved"
HARNESS_SESSION_ID=probe-reflect HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" bash "$root/scripts/lib/journal.sh" event verify "passed" || probe_fail "probe journal write failed"
echo "probe work" > "$probe/probe-work.txt" || probe_fail "cannot dirty the probe"
fake="$probe/opencode"
printf "%s\n" "#!/usr/bin/env python3" "import json,os,sys" "a=sys.argv[1:]" "if a[:1]==[\"--version\"]:" "    print(\"opencode 2.0.0\")" "else:" "    print(json.dumps({\"type\":\"text\",\"part\":{\"text\":os.environ[\"FAKE_CANDIDATE\"]},\"sessionID\":\"ses_probe\"}))" > "$fake" || probe_fail "cannot plant fake opencode"
chmod +x "$fake" || probe_fail "cannot chmod the fake"
out=$(cd "$probe" && env -u OPENCODE_SESSION_ID -u OPENCODE_BIN HARNESS_HOME="$top" PATH="$probe:$PATH" OPENCODE_CONFIG_CONTENT="{\"agent\":{}}" HARNESS_SESSION_ID=probe-reflect FAKE_CANDIDATE="$(printf "%s\n%s" "{\"tier\":\"memory\",\"target\":\"probe-trap\",\"text\":\"probe lesson text here\",\"evidence\":\"$bid\"}" "{\"tier\":\"memory\",\"target\":\"probe-unreviewed\",\"text\":\"unreviewed lesson text\",\"evidence\":\"$bid\"}")" "$probe/scripts/harness" wrap-up --quick --no-push -m "probe reflect $bid" --bead "$bid" --keep-lesson 1 2>&1) || probe_fail "wrap-up failed"
echo "$out" | grep -q "reflector proposed 2 candidate" || probe_fail "wrap-up never reported the candidates"
echo "$out" | grep -q "lesson 1 .* kept" || probe_fail "wrap-up never marked lesson 1 kept"
echo "$out" | grep -q "lesson 2 .* unreviewed" || probe_fail "fresh close never marked lesson 2 unreviewed"
python3 - "$probe/harness/learning.jsonl" <<PYEOF || probe_fail "fresh close never logged kept and unreviewed"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip() and not l.startswith("#")]
keep = [r for r in rows if r.get("target") == "probe-trap"]
unrev = [r for r in rows if r.get("target") == "probe-unreviewed"]
assert keep and keep[-1].get("outcome") == "kept", keep
assert unrev and unrev[-1].get("outcome") == "unreviewed", unrev
assert not [r for r in unrev if r.get("outcome") == "dropped"], unrev
PYEOF
(cd "$probe" && git show HEAD:.beads/issues.jsonl 2>/dev/null | grep -q "probe lesson text here") || probe_fail "kept memory never reached the committed export"
# A reviewed list is reused verbatim and each outcome is logged. A full
# close per outcome would price this past time, so reuse runs through the
# real reflect.sh and the outcomes through the real annotate function from
# wrap-up.sh (sourcing the whole script would run a close, so only the two
# functions travel). The fake bd fails only the failed key. The drive runs
# from inside the probe: bd remember writes to the ledger of its cwd.
mkdir -p "$probe/fakebin" || probe_fail "cannot make the fake bin"
realbd=$(command -v bd) || probe_fail "cannot locate real bd"
printf "%s\n" "#!/bin/bash" "if [ \"\$1\" = \"remember\" ] && [ \"\${4:-}\" = \"probe-failed-key\" ]; then echo \"fake bd remember failure\" >&2; exit 1; fi" "exec \"$realbd\" \"\$@\"" > "$probe/fakebin/bd" || probe_fail "cannot plant fake bd"
chmod +x "$probe/fakebin/bd" || probe_fail "cannot chmod fake bd"
printf "%s\n" "{\"tier\": \"memory\", \"target\": \"probe-reviewed-keep\", \"text\": \"reviewed keep lesson\", \"evidence\": \"$bid\"}" "{\"tier\": \"memory\", \"target\": \"probe-failed-key\", \"text\": \"failed lesson text\", \"evidence\": \"$bid\"}" "{\"tier\": \"skill\", \"target\": \"probe-skill-file\", \"text\": \"reviewed drop lesson\", \"evidence\": \"$bid\"}" > "$probe/candidates.jsonl" || probe_fail "cannot plant the reviewed candidates"
out=$(cd "$probe" && HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" bash "$root/scripts/reflect.sh" --candidates-file "$probe/candidates.jsonl" 2>&1) || probe_fail "candidates-file reuse failed"
echo "$out" | grep -q "^CANDIDATES " || probe_fail "reuse never printed the candidates line"
echo "$out" | grep -q "probe-reviewed-keep" || probe_fail "reuse never listed the kept candidate"
sed -n "/^warn_keep_ignored()/,/^}/p; /^annotate_reflect_lesson()/,/^}/p" "$root/scripts/wrap-up.sh" > "$probe/annotate.sh" || probe_fail "cannot extract annotate"
grep -q "annotate_reflect_lesson" "$probe/annotate.sh" || probe_fail "annotate extraction missed"
HARNESS="$root"
CANDIDATES_FILE="$probe/candidates.jsonl"
KEEP_LESSONS=(1 2)
export HARNESS HARNESS_SESSION_ID=probe-reflect HARNESS_PROJECT="$probe"
export PATH="$probe/fakebin:$PATH"
. "$probe/annotate.sh" || probe_fail "cannot load annotate"
drive_out=$( cd "$probe" && { annotate_reflect_lesson 1 memory "probe-reviewed-keep" "reviewed keep lesson" "$bid"; annotate_reflect_lesson 2 memory "probe-failed-key" "failed lesson text" "$bid"; annotate_reflect_lesson 3 skill "probe-skill-file" "reviewed drop lesson" "$bid"; } 2>&1 ) || probe_fail "annotate drive failed"
echo "$drive_out" | grep -q "lesson 1 .* kept" || probe_fail "reviewed drive never marked lesson 1 kept"
echo "$drive_out" | grep -qi "lesson 2 .* failed" || probe_fail "keyed remember failure was never loud and failed"
echo "$drive_out" | grep -q "lesson 3 .* dropped" || probe_fail "reviewed drive never marked lesson 3 dropped"
python3 - "$probe/harness/learning.jsonl" <<PYEOF || probe_fail "reviewed drive never logged kept/failed/dropped"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip() and not l.startswith("#")]
keep = [r for r in rows if r.get("target") == "probe-reviewed-keep"]
fail = [r for r in rows if r.get("target") == "probe-failed-key"]
drop = [r for r in rows if r.get("target") == "probe-skill-file"]
assert keep and keep[-1].get("outcome") == "kept", keep
assert fail and fail[-1].get("outcome") == "failed", fail
assert drop and drop[-1].get("outcome") == "dropped", drop
PYEOF
# Lesson pressure counts only kept: pad probe-trap to three kept, plant three
# unreviewed elsewhere, and one brief run names only the kept target.
stamp=$(date -u "+%Y-%m-%dT%H:%M:%SZ") || probe_fail "cannot stamp probe rows"
printf "%s\n" "{\"kind\": \"lesson\", \"tier\": \"memory\", \"target\": \"probe-trap\", \"text\": \"pad one\", \"evidence\": \"$bid\", \"outcome\": \"kept\", \"ts\": \"$stamp\"}" "{\"kind\": \"lesson\", \"tier\": \"memory\", \"target\": \"probe-trap\", \"text\": \"pad two\", \"evidence\": \"$bid\", \"outcome\": \"kept\", \"ts\": \"$stamp\"}" "{\"kind\": \"lesson\", \"tier\": \"memory\", \"target\": \"probe-pressure-ignored\", \"text\": \"one\", \"evidence\": \"$bid\", \"outcome\": \"unreviewed\", \"ts\": \"$stamp\"}" "{\"kind\": \"lesson\", \"tier\": \"memory\", \"target\": \"probe-pressure-ignored\", \"text\": \"two\", \"evidence\": \"$bid\", \"outcome\": \"unreviewed\", \"ts\": \"$stamp\"}" "{\"kind\": \"lesson\", \"tier\": \"memory\", \"target\": \"probe-pressure-ignored\", \"text\": \"three\", \"evidence\": \"$bid\", \"outcome\": \"unreviewed\", \"ts\": \"$stamp\"}" >> "$probe/harness/learning.jsonl" || probe_fail "cannot plant pressure rows"
out=$(cd "$probe" && HARNESS_HOME="$top" HARNESS_PROJECT="$probe" "$probe/scripts/harness" brief 2>&1) || probe_fail "brief failed over pressure rows"
echo "$out" | grep -q "lessons on probe-trap" || probe_fail "brief never counted kept pressure"
if echo "$out" | grep -q "lessons on probe-pressure-ignored"; then probe_fail "brief counted unreviewed pressure"; fi
'

# Due signal in one copy: cadence names the marker's line-1 date; lesson and finding pressure each fire once; an old one-line marker keeps the size rule; a reset at 28 keys clears the line until 8 more land (7 stay silent); a broken memories read refuses the reset without touching the marker.
probe_step --when "template/scripts/brief.sh template/.claude/agents/librarian.md" "consolidation due signal" bash -c '
PROBE_SCENARIO="consolidation due signal"
golden_probe || probe_fail "no golden fixture"
top="$PWD"
root="$(probe_shared_root "$probe")" || probe_fail "finder cannot resolve the harness"
# The real brief.sh with the real env, minus the finder handoff: one
# refusal-path run below still goes through scripts/harness dispatch, which
# is what proves the flag survives it.
brief_out() {
out=$(HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" bash "$root/scripts/brief.sh" 2>&1) || probe_fail "brief failed"
}
expect_due_once() {
brief_out || probe_fail "brief failed"
n="$(echo "$out" | grep -c "consolidation due" || true)"
[ "$n" = "1" ] || probe_fail "reported due $n times, want exactly 1"
[ -z "${1:-}" ] || echo "$out" | grep -q "$1" || probe_fail "due line never matched $1"
}
expect_silent() {
brief_out || probe_fail "brief failed"
if echo "$out" | grep -q "consolidation due"; then probe_fail "still reports due"; fi
}
mark_consolidated() {
out=$(HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" bash "$root/scripts/brief.sh" --mark-consolidated 2>&1) || probe_fail "mark-consolidated failed"
}
# One ledger write per key range: N serial `bd remember` calls price the
# probe out of its time budget, and `bd import` takes memory lines natively.
plant_memories() {
rm -f "$probe/memories-batch.jsonl" || probe_fail "cannot clean the probe batch"
i="$1"
while [ "$i" -le "$2" ]; do
printf "{\"_type\":\"memory\",\"key\":\"probe-trap-%s\",\"value\":\"probe trap memory %s\"}\n" "$i" "$i" >> "$probe/memories-batch.jsonl" || probe_fail "cannot write the probe batch"
i=$((i + 1))
done
(cd "$probe" && bd import "$probe/memories-batch.jsonl" >/dev/null 2>&1) || probe_fail "cannot import probe memories $1-$2"
rm -f "$probe/memories-batch.jsonl" || probe_fail "cannot clean the probe batch"
}
[ ! -e "$probe/harness/.last-consolidation" ] || probe_fail "fresh install carries a consolidation marker"
# Cadence reads the date off the marker line 1: an aged two-line marker with newer notes names that date, never the traps= line.
printf "%s\n" "2020-01-01T00:00:00Z" "traps=0" > "$probe/harness/.last-consolidation" || probe_fail "cannot plant the marker"
touch -t 202001010000 "$probe/harness/.last-consolidation" || probe_fail "cannot age the marker"
for i in 1 2 3 4 5; do printf "%s\n" "# probe note $i" > "$probe/harness/handoffs/note-probe-$i.md" || probe_fail "cannot plant handoff note $i"; done
expect_due_once "5 handoffs since 2020-01-01T00:00:00Z"
rm -f "$probe"/harness/handoffs/note-probe-*.md || probe_fail "cannot clear the probe notes"
cp "$probe/harness/learning.jsonl" "$probe/learning-backup.jsonl" || probe_fail "cannot back up the learning log"
printf "%s\n" "2020-01-01T00:00:00Z" > "$probe/harness/.last-consolidation" || probe_fail "cannot backdate the marker"
stamp="$(date -u "+%Y-%m-%dT%H:%M:%SZ")" || probe_fail "cannot stamp probe rows"
printf "%s\n" "{\"bead\": \"probe-1\", \"category\": \"probe-x\", \"evidence\": \"probe-1\", \"kind\": \"lesson\", \"outcome\": \"kept\", \"target\": \"probe-target\", \"text\": \"probe lesson one\", \"tier\": \"memory\", \"ts\": \"$stamp\"}" "{\"bead\": \"probe-2\", \"category\": \"probe-x\", \"evidence\": \"probe-2\", \"kind\": \"lesson\", \"outcome\": \"kept\", \"target\": \"probe-target\", \"text\": \"probe lesson two\", \"tier\": \"memory\", \"ts\": \"$stamp\"}" "{\"bead\": \"probe-3\", \"category\": \"probe-x\", \"evidence\": \"probe-3\", \"kind\": \"lesson\", \"outcome\": \"kept\", \"target\": \"probe-target\", \"text\": \"probe lesson three\", \"tier\": \"memory\", \"ts\": \"$stamp\"}" >> "$probe/harness/learning.jsonl" || probe_fail "cannot plant probe lessons"
expect_due_once "lessons on probe-target"
cp "$probe/learning-backup.jsonl" "$probe/harness/learning.jsonl" || probe_fail "cannot restore the learning log"
printf "%s\n" "2020-01-01T00:00:00Z" > "$probe/harness/.last-consolidation" || probe_fail "cannot backdate the marker"
stamp="$(date -u "+%Y-%m-%dT%H:%M:%SZ")" || probe_fail "cannot stamp probe rows"
printf "%s\n" "{\"bead\": \"probe-1\", \"category\": \"probe-findings\", \"kind\": \"finding\", \"note\": \"probe\", \"outcome\": \"accepted\", \"reviewer\": \"reviewer-taste\", \"ts\": \"$stamp\"}" "{\"bead\": \"probe-2\", \"category\": \"probe-findings\", \"kind\": \"finding\", \"note\": \"probe\", \"outcome\": \"rejected\", \"reviewer\": \"reviewer-correctness\", \"ts\": \"$stamp\"}" "{\"bead\": \"probe-3\", \"category\": \"probe-findings\", \"kind\": \"finding\", \"note\": \"probe\", \"outcome\": \"accepted\", \"reviewer\": \"reviewer-design\", \"ts\": \"$stamp\"}" >> "$probe/harness/learning.jsonl" || probe_fail "cannot plant probe findings"
expect_due_once "findings in probe-findings"
cp "$probe/learning-backup.jsonl" "$probe/harness/learning.jsonl" || probe_fail "cannot restore the learning log"
# An old one-line marker keeps the size rule: 9 keys over a budget of 8 is due.
printf "%s\n" "2020-01-01T00:00:00Z" > "$probe/harness/.last-consolidation" || probe_fail "cannot plant the old marker"
plant_memories 1 9
expect_due_once "9 known traps"
# A pass plus reset clears the line at 28 keys; pressure is growth from there.
# No due run first: the old one-line marker still in place fires on size at
# 28, so the silent after the reset is already non-vacuous.
plant_memories 10 28
mark_consolidated
echo "$out" | grep -q "marked consolidated" || probe_fail "mark-consolidated never confirmed the reset"
sed -n "1p" "$probe/harness/.last-consolidation" | grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$" || probe_fail "mark-consolidated never wrote the date line"
grep -q "^traps=28$" "$probe/harness/.last-consolidation" || probe_fail "mark-consolidated never wrote traps=28"
expect_silent
# Seven more stay silent; the eighth brings it back.
plant_memories 29 35
expect_silent
plant_memories 36 36
expect_due_once "36 known traps"
# A broken memories read refuses the reset: loud, and the old marker untouched.
mkdir -p "$probe/fakebin" || probe_fail "cannot make the fake bin"
realbd="$(command -v bd)" || probe_fail "cannot locate real bd"
printf "%s\n" "#!/bin/bash" "if [ \"\$1\" = \"memories\" ]; then echo \"probe stub refuses bd memories\" >&2; exit 1; fi" "exec \"$realbd\" \"\$@\"" > "$probe/fakebin/bd" || probe_fail "cannot plant fake bd"
chmod +x "$probe/fakebin/bd" || probe_fail "cannot chmod fake bd"
before="$(cat "$probe/harness/.last-consolidation")" || probe_fail "cannot read the marker"
out=$(cd "$probe" && HARNESS_HOME="$top" HARNESS_PROJECT="$probe" PATH="$probe/fakebin:$PATH" "$probe/scripts/harness" brief --mark-consolidated 2>&1) && probe_fail "mark-consolidated passed over a broken memories read" || true
echo "$out" | grep -q "no trap count in the brief" || probe_fail "refusal never said why"
[ "$(cat "$probe/harness/.last-consolidation")" = "$before" ] || probe_fail "refused mark rewrote the marker"
'


# The consolidation prompt: the librarian gains promote/correct/prune beside
# delete/merge/move/shorten, scopes every pass to the marker, proposes only,
# and turns a 3x finding category into a reviewer trap. Static checks on the
# tree — the behavioral half is the due-signal probe below.
step "librarian consolidation prompt" bash -c '
  for w in promote correct prune; do
    grep -q "$w" template/.claude/agents/librarian.md ||
      { echo "error: librarian never names $w"; exit 1; }
  done
  for w in last-consolidation "3 times" reviewer-trap "scripts/harness agent" native "You propose" memory-archive "since the marker"; do
    grep -q "$w" template/.claude/agents/librarian.md ||
      { echo "error: librarian never covers $w"; exit 1; }
  done
  for w in CONSOLIDATION_NOTES CONSOLIDATION_HOURS CONSOLIDATION_MAX_TRAPS CONSOLIDATION_TRAP_GROWTH CONSOLIDATION_LESSONS CONSOLIDATION_FINDINGS; do
    grep -q "$w" template/scripts/brief.sh ||
      { echo "error: brief never sets $w"; exit 1; }
  done
  for w in "consolidation due" last-consolidation "Tune here"; do
    grep -q "$w" template/scripts/brief.sh ||
      { echo "error: brief never covers $w"; exit 1; }
  done
  if grep -q "agent.py" template/scripts/brief.sh; then
    echo "error: brief shells to the agent instead of only printing one line"; exit 1;
  fi
  [ -f template/harness/.last-consolidation ] ||
    { echo "error: no marker seed in template/harness"; exit 1; }
  [ ! -s template/harness/.last-consolidation ] ||
    { echo "error: the marker seed is not empty"; exit 1; }
  grep -q "Consolidation is one librarian pass" template/.claude/HARNESS.md ||
    { echo "error: HARNESS.md never explains consolidation"; exit 1; }
  grep -q "consolidation due" template/.claude/HARNESS.md ||
    { echo "error: HARNESS.md never names the due line"; exit 1; }
  for w in "agents/librarian.md" "scripts/brief.sh"; do
    grep -q "$w" template/.claude/HARNESS.md ||
      { echo "error: HARNESS.md tracks comment lost $w"; exit 1; }
  done
  for w in promote correct "last-consolidation" "reviewer-trap"; do
    grep -q "$w" template/.opencode/agent/librarian.md ||
      { echo "error: opencode translation lost $w"; exit 1; }
  done'

# The wiki's static shape: the generator carries its caps and its link check,
# the brief carries the threshold and the topic display, the librarian carries
# the proposal duties, context.py counts and watches the layer, and HARNESS.md
# explains it with a tracks entry. The opencode translation stays in step
# because it is generated, never hand-edited.
step "wiki derived layer format" bash -c '
  for w in WIKI_INDEX_MAX_PCT WIKI_TOTAL_MAX_PCT WIKI_EXCERPT_CHARS "tracks: scripts/build-wiki.sh" "exactly one page" "cap breach"; do
    grep -q "$w" template/scripts/build-wiki.sh ||
      { echo "error: build-wiki.sh never covers $w"; exit 1; }
  done
  for w in WIKI_MAX_KEYS "wiki topics" "harness/wiki/<topic>.md" "Tune here"; do
    grep -q "$w" template/scripts/brief.sh ||
      { echo "error: brief.sh never covers $w"; exit 1; }
  done
  if grep -q "FILL THIS IN" template/scripts/build-wiki.sh; then
    echo "error: the generator carries a fill-in block — only seeds may"; exit 1;
  fi
  for w in "build-wiki.sh" "only writer" "propose" "WIKI_MAX_KEYS" "diff empty"; do
    grep -q "$w" template/.claude/agents/librarian.md ||
      { echo "error: librarian never covers $w"; exit 1; }
  done
  for w in "wiki index" "## Wiki" "wiki_pages" "wiki_threshold"; do
    grep -q "$w" template/scripts/context.py ||
      { echo "error: context.py never covers $w"; exit 1; }
  done
  grep -q "The wiki is derived" template/.claude/HARNESS.md ||
    { echo "error: HARNESS.md never explains the wiki"; exit 1; }
  grep -q "scripts/build-wiki.sh" template/.claude/HARNESS.md ||
    { echo "error: HARNESS.md tracks comment lost build-wiki.sh"; exit 1; }
  for w in "build-wiki.sh" "only writer"; do
    grep -q "$w" template/.opencode/agent/librarian.md ||
      { echo "error: opencode translation lost $w"; exit 1; }
  done'

# Wiki lifecycle in one copy: empty builds nothing, 61 keys build and rebuild losslessly, colliding topics keep distinct files, zero cap breaches loudly with no publish, fake harness proves staleness.
probe_step --when "template/scripts/build-wiki.sh template/scripts/brief.sh template/scripts/context.py template/.claude/agents/librarian.md" "wiki lifecycle" bash -c '
PROBE_SCENARIO="wiki lifecycle"
golden_probe || probe_fail "no golden fixture"
root="$(probe_shared_root "$probe")" || probe_fail "finder cannot resolve the harness"
out=$(HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" bash "$root/scripts/build-wiki.sh" 2>&1) || probe_fail "empty build failed"
echo "$out" | grep -q "nothing to build" || probe_fail "empty build never said so"
[ ! -e "$probe/harness/wiki" ] || probe_fail "empty build created harness/wiki"
(cd "$probe" && bd remember "probe below-threshold one" --key "probe-below-one" >/dev/null 2>&1) || probe_fail "cannot remember probe memory one"
(cd "$probe" && bd remember "probe below-threshold two" --key "probe-below-two" >/dev/null 2>&1) || probe_fail "cannot remember probe memory two"
out=$(HARNESS_HOME="$PWD" HARNESS_PROJECT="$probe" "$probe/scripts/harness" brief 2>&1) || probe_fail "brief failed"
echo "$out" | grep -q "known traps (2)" || probe_fail "brief lost the flat key list below threshold"
if echo "$out" | grep -q "wiki topics"; then probe_fail "brief named topics below threshold"; fi
[ ! -e "$probe/harness/wiki" ] || probe_fail "harness/wiki exists below threshold"
# One import, not 59 remembers: crossing WIKI_MAX_KEYS one bd call at a time
# cost this probe twenty seconds.
import_file="$probe/wiki-memories.jsonl"
: > "$import_file" || probe_fail "cannot start the probe memory file"
add_memory() { printf "{\"_type\":\"memory\",\"key\":\"%s\",\"value\":\"probe wiki memory %s\"}\n" "$1" "$1" >> "$import_file"; }
for i in 1 2 3 4 5 6 7; do add_memory "alpha-$i"; done
for i in 1 2 3 4 5 6; do add_memory "beta-$i"; add_memory "gamma-$i"; done
i=1; while [ "$i" -le 38 ]; do add_memory "filler-$i"; i=$((i + 1)); done
add_memory "Alpha-1"; add_memory "Beta-1"
(cd "$probe" && bd import "$import_file" >/dev/null 2>&1) || probe_fail "cannot import the probe memories"
rm -f "$import_file" || probe_fail "cannot clean the probe memory file"
out=$(HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" bash "$root/scripts/build-wiki.sh" 2>&1) || probe_fail "build failed above threshold"
echo "$out" | grep -q "7 topics, 61 keys" || probe_fail "build never reported its topics and keys"
[ -f "$probe/harness/wiki/index.md" ] || probe_fail "build wrote no index"
[ -f "$probe/harness/wiki/Alpha.md" ] || probe_fail "no page for colliding topic Alpha"
[ -f "$probe/harness/wiki/alpha-2.md" ] || probe_fail "no suffixed page for colliding topic alpha"
[ -f "$probe/harness/wiki/Beta.md" ] || probe_fail "no page for colliding topic Beta"
[ -f "$probe/harness/wiki/beta-2.md" ] || probe_fail "no suffixed page for colliding topic beta"
for k in alpha-1 beta-6 filler-38 gamma-1 alpha-7 Alpha-1 alpha-2 Beta-1 beta-2; do grep -rqF "$k" "$probe/harness/wiki/" || probe_fail "key $k reachable from no page"; done
out=$(HARNESS_HOME="$PWD" HARNESS_PROJECT="$probe" "$probe/scripts/harness" brief 2>&1) || probe_fail "brief failed above threshold"
echo "$out" | grep -q "wiki topics (7 topics, 61 keys)" || probe_fail "brief never switched to topics"
if echo "$out" | grep -q "known traps ("; then probe_fail "brief still printed the flat key list"; fi
cp -R "$probe/harness/wiki" "$probe/wiki-backup" || probe_fail "cannot back up the probe wiki"
rm -rf "$probe/harness/wiki" || probe_fail "cannot delete the probe wiki"
out=$(HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" bash "$root/scripts/build-wiki.sh" 2>&1) || probe_fail "rebuild failed"
diff -r "$probe/wiki-backup" "$probe/harness/wiki" || probe_fail "delete plus rebuild lost data"
rm -rf "$probe/wiki-backup" || probe_fail "cannot clean the wiki backup"
out=$(HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" WIKI_INDEX_MAX_PCT=0 bash "$root/scripts/build-wiki.sh" 2>&1) && probe_fail "breached rebuild passed" || true
echo "$out" | grep -q "cap breach" || probe_fail "breach never said cap"
[ ! -e "$probe/harness/wiki" ] || probe_fail "breached rebuild left the stale wiki"
fake="$probe/fakeharness"
mkdir -p "$fake/.claude" "$fake/scripts" "$probe/harness/wiki" "$probe/fakehome" || probe_fail "cannot shape the fake harness"
printf "<!-- tracks: scripts/build-wiki.sh -->\n# probe harness\n" > "$fake/.claude/HARNESS.md" || probe_fail "cannot plant the fake HARNESS.md"
printf "#!/bin/bash\necho probe generator\n" > "$fake/scripts/build-wiki.sh" || probe_fail "cannot plant the fake generator"
printf "<!-- tracks: scripts/build-wiki.sh -->\n<!-- wiki: topics=1 keys=1 -->\n# probe index\n" > "$probe/harness/wiki/index.md" || probe_fail "cannot plant the fake index"
printf "<!-- tracks: scripts/build-wiki.sh -->\n# probe topic\n" > "$probe/harness/wiki/probe.md" || probe_fail "cannot plant the fake page"
out=$(cd "$probe" && HOME="$probe/fakehome" HARNESS_PROJECT="$probe" HARNESS_ROOT="$fake" python3 "$root/scripts/context.py" bless 2>&1) || probe_fail "bless failed over the fake harness"
grep -q "harness/wiki/index.md" "$probe/.claude/context.lock" || probe_fail "bless never recorded the wiki index"
out=$(cd "$probe" && HOME="$probe/fakehome" HARNESS_PROJECT="$probe" HARNESS_ROOT="$fake" python3 "$root/scripts/context.py" check 2>&1) || probe_fail "blessed check failed"
echo "$out" | grep -q "^  ok " || probe_fail "blessed check never said ok"
printf "# probe generator, moved\n" >> "$fake/scripts/build-wiki.sh" || probe_fail "cannot move the fake generator"
out=$(cd "$probe" && HOME="$probe/fakehome" HARNESS_PROJECT="$probe" HARNESS_ROOT="$fake" python3 "$root/scripts/context.py" check 2>&1) && probe_fail "check passed a moved generator" || true
echo "$out" | grep -q "STALE" || probe_fail "moved generator failed without a STALE line"
echo "$out" | grep -q "harness/wiki/probe.md" || probe_fail "STALE line never named the wiki page"
'


# No [verdict] section is the common case — every fresh install — so the
# default must be served silently: no complaint on stderr, match-nothing
# pattern from the reader.
probe_step --when "template/scripts/dashboard.py template/scripts/dashboard-persist.sh template/dashboard/* dashboard.toml" "dashboard serves the default verdict silently with no verdict section" bash -c '
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
probe_step --when "template/scripts/dashboard.py template/scripts/dashboard-persist.sh template/dashboard/* dashboard.toml" "dashboard serves theme, board, and assets from the toml" bash -c '
  golden_probe || exit 1
  mod="$(probe_shared_root "$probe")/scripts/dashboard.py" || exit 1
  probe_dashboard_config "$probe" "$mod" || exit 1'

# Only an allowlisted file resolves, with a fixed content-type; an unlisted
# file and every traversal shape read as missing, which the handler 404s.
probe_step --when "template/scripts/dashboard.py template/scripts/dashboard-persist.sh template/dashboard/* dashboard.toml" "dashboard serves allowlisted assets and 404s the rest" bash -c '
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
probe_step --when "template/scripts/dashboard.py template/scripts/dashboard-persist.sh template/dashboard/* dashboard.toml" "dashboard vercel unlinked serves no vercel key" bash -c '
  golden_probe || exit 1
  mod="$(probe_shared_root "$probe")/scripts/dashboard.py" || exit 1
  probe_dashboard_vercel_unlinked "$probe" "$mod" || exit 1'

# A linked checkout missing the token or the upstream ref reads as
# unconfigured with why, never an exception.
probe_step --when "template/scripts/dashboard.py template/scripts/dashboard-persist.sh template/dashboard/* dashboard.toml" "dashboard vercel misconfigured reads unconfigured with why" bash -c '
  golden_probe || exit 1
  mod="$(probe_shared_root "$probe")/scripts/dashboard.py" || exit 1
  probe_dashboard_vercel_misconfigured "$probe" "$mod" || exit 1'

# API states map to chip labels; a dead API reads unreachable with the token
# nowhere in what the reader serves.
probe_step --when "template/scripts/dashboard.py template/scripts/dashboard-persist.sh template/dashboard/* dashboard.toml" "dashboard vercel maps api states to chip labels" bash -c '
  golden_probe || exit 1
  mod="$(probe_shared_root "$probe")/scripts/dashboard.py" || exit 1
  probe_dashboard_vercel_labels "$probe" "$mod" || exit 1'

# A broken table keeps serving its last good values and says so on stderr,
# while a good table beside it keeps updating.
probe_step --when "template/scripts/dashboard.py template/scripts/dashboard-persist.sh template/dashboard/* dashboard.toml" "dashboard keeps last good config on a broken table" bash -c '
  golden_probe || exit 1
  mod="$(probe_shared_root "$probe")/scripts/dashboard.py" || exit 1
  probe_dashboard_broken_config "$probe" "$mod" || exit 1'

# A pattern with the wrong group shape never reaches the reader: log_ok pulls
# the verdict word out of exactly one group, so zero groups serve permanent
# red and two hand back tuples, which have no .upper. The toml keeps serving
# the default instead, with the complaint on stderr.
probe_step --when "template/scripts/dashboard.py template/scripts/dashboard-persist.sh template/dashboard/* dashboard.toml" "dashboard keeps the default over a misshapen verdict pattern" bash -c '
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
probe_step --when "bin/* commands/add.sh commands/lib/* template/scripts/harness template/scripts/h template/harness/stacks/*" "add records stacks without copying guidance" bash -c '
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
probe_step --when "bin/* commands/add.sh commands/lib/* template/scripts/harness template/scripts/h template/harness/stacks/*" "an edited stacks.txt survives a re-add" bash -c '
  fresh_probe || exit 1
  touch "$probe/Package.swift" || { echo "error: cannot mark the probe as swift"; exit 1; }
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: harness add failed"; exit 1; }
  printf "web\n" > "$probe/harness/stacks.txt" || { echo "error: cannot edit stacks.txt"; exit 1; }
  bin/harness add "$probe" >/dev/null 2>&1 || { echo "error: re-add failed"; exit 1; }
  [ "$(grep -v "^#" "$probe/harness/stacks.txt")" = "web" ] ||
    { echo "error: re-add rewrote stacks.txt"; exit 1; }'

# A stack name with no guidance behind it warns loudly: reviewers would
# otherwise miss the platform checks and nothing would say so.
probe_step --when "bin/* commands/add.sh commands/lib/* template/harness/stacks/*" "add warns loudly on unknown stack names" bash -c '
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
probe_step --when "template/scripts/models.py template/scripts/harness scripts/harness" "models.py budget resolves explicit and default budgets" bash -c '
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
  [ "$(HARNESS_HOME="$PWD" "$probe/scripts/harness" models budget reviewer-taste)" = "12345" ] ||
    { echo "error: explicit context not honored"; exit 1; }
  [ "$(HARNESS_HOME="$PWD" "$probe/scripts/harness" models budget reviewer-design)" = "1048576" ] ||
    { echo "error: default is not the pin window"; exit 1; }
  # if-form, not trailing &&: a failed && as the last line exits the step 1.
  if HARNESS_HOME="$PWD" "$probe/scripts/harness" models budget nobody >/dev/null 2>&1; then
    echo "error: budget passed for an unknown role"; exit 1;
  fi
  if HARNESS_HOME="$PWD" "$probe/scripts/harness" models budget librarian >/dev/null 2>&1; then
    echo "error: budget passed for a foreign roster entry"; exit 1;
  fi'

# An over-budget packet refuses with the binding role and the narrower command
# — a truncated packet reporting confidently on its first pages is the failure.
# The shared review runs through the probe's finder; the dirtied stub stands in
# for any tracked change, since review reads the whole working tree.
probe_step --when "template/scripts/review.sh template/scripts/models.py scripts/review.scope.sh" "review.sh refuses a packet over the smallest reviewer budget" bash -c '
  golden_probe || exit 1
  cat > "$probe/harness/models.json" <<EOF ||
{"reviewer-taste": {"model": "opencode-go/muse-spark-1.3-contributor", "variant": "xhigh", "context": 100},
 "reviewer-correctness": {"model": "opencode-go/muse-spark-1.3-contributor", "variant": "xhigh", "context": 100},
 "reviewer-design": {"model": "opencode-go/muse-spark-1.3-contributor", "variant": "xhigh", "context": 100}}
EOF
    { echo "error: cannot write test roster"; exit 1; }
  echo "# change" >> "$probe/AGENTS.md" ||
    { echo "error: cannot dirty a tracked file"; exit 1; }
  out=$(HARNESS_HOME="$PWD" "$probe/scripts/harness" review 2>&1) &&
    { echo "error: review passed an over-budget packet"; echo "$out"; exit 1; }
  echo "$out" | grep -q "reviewer-taste" ||
    { echo "error: refusal never named the binding role"; echo "$out"; exit 1; }
  echo "$out" | grep -q "scripts/harness review <commit>" ||
    { echo "error: refusal never said how to narrow"; echo "$out"; exit 1; }'

# A packet within budget still prints its path — the refusal must not fire on
# ordinary changes.
probe_step --when "template/scripts/review.sh template/scripts/models.py scripts/review.scope.sh" "review.sh passes a packet within budget" bash -c '
  golden_probe || exit 1
  cat > "$probe/harness/models.json" <<EOF ||
{"reviewer-taste": {"model": "opencode-go/muse-spark-1.3-contributor", "variant": "xhigh", "context": 1000000},
 "reviewer-correctness": {"model": "opencode-go/muse-spark-1.3-contributor", "variant": "xhigh", "context": 1000000},
 "reviewer-design": {"model": "opencode-go/muse-spark-1.3-contributor", "variant": "xhigh", "context": 1000000}}
EOF
    { echo "error: cannot write test roster"; exit 1; }
  echo "# change" >> "$probe/AGENTS.md" ||
    { echo "error: cannot dirty a tracked file"; exit 1; }
  out=$(HARNESS_HOME="$PWD" "$probe/scripts/harness" review 2>&1) || {
    echo "error: review refused a fitting packet"; echo "$out"; exit 1; }
  echo "$out" | grep -q "review-packet" ||
    { echo "error: review never printed the packet"; echo "$out"; exit 1; }'

# A fresh install runs opencode on the pin and nothing else (har-wbbe): the
# stub pins the session model, the linked shared agents carry it, and there
# is no local roster — ensure writes the pinned one with no terminal, the pin
# check passes the install as it stands, and a foreign roster planted
# afterwards fails it.
probe_step --when "bin/* commands/add.sh commands/lib/* template/stubs/opencode.json template/.opencode/agent/* template/scripts/opencode-agents.py template/scripts/opencode-pin.py template/scripts/models.py template/harness/evals/*" "a fresh install pins opencode to one model" bash -c '
  PROBE_SCENARIO="a fresh install pins opencode to one model"
  golden_probe || probe_fail "no golden fixture"
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
  (HARNESS_HOME="$PWD" "$probe/scripts/harness" models ensure </dev/null >/dev/null 2>&1) ||
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
  fi
  # The reference install carries the eval cases too, so the fresh-install shape is proved here rather than in its own probe.
  for f in harness/evals/commit-bead/task.md harness/evals/commit-bead/base harness/evals/commit-bead/check.sh harness/evals/verify-gate/task.md harness/evals/verify-gate/base harness/evals/verify-gate/check.sh; do
    [ -f "$probe/$f" ] || probe_fail "reference install missed $f"
  done
  [ -x "$probe/harness/evals/commit-bead/check.sh" ] || probe_fail "commit-bead check.sh lost its executable bit"
  [ -x "$probe/harness/evals/verify-gate/check.sh" ] || probe_fail "verify-gate check.sh lost its executable bit"
  [ ! -e "$probe/harness/evals/results.jsonl" ] || probe_fail "results.jsonl shipped — it is runtime data"
  [ -f "$modroot/scripts/eval.sh" ] || probe_fail "shared checkout has no scripts/eval.sh"'

# `harness add` merges the root instructions into an existing shadow instead
# of leaving AGENTS.md unloaded: the shadow keeps its own entries and its
# plugin, and gains whatever root entries it was missing. Add never
# overwrites, so the planted shadow survives the install to be merged.
probe_step --when "bin/* commands/add.sh commands/lib/* template/stubs/opencode.json" "add merges root instructions into a shadowing opencode.json" bash -c '
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
probe_step --when "bin/* commands/add.sh commands/lib/*" "add refuses a copied install and points at migrate" bash -c '
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
  if [ -e "$probe/AGENTS.md" ] || [ -e "$probe/scripts/harness" ]; then
    echo "error: add wrote reference files into the refused copy"; exit 1;
  fi'

# A target that is already a reference install — scripts/harness, no copies —
# re-runs idempotently instead of refusing.
probe_step --when "bin/* commands/add.sh commands/lib/* template/scripts/harness template/scripts/h" "add re-runs idempotently over a reference install" bash -c '
  golden_probe || exit 1
  out=$(bin/harness add "$probe" 2>&1) || { echo "error: re-add failed"; echo "$out"; exit 1; }
  if echo "$out" | grep -q "copied install"; then
    echo "error: re-add mistook a reference install for a copy"; echo "$out"; exit 1;
  fi'

# A pre rename tree carries the old finder at scripts/h with no harness.
# Migrate writes the finder and leaves the shim in its place, and a second
# apply changes nothing.
probe_step --when "bin/* commands/migrate.sh commands/lib/* template/scripts/harness template/scripts/h" "migrate converts a project with scripts/h" bash -c '
  fresh_probe || exit 1
  mkdir -p "$probe/scripts" || { echo "error: cannot make scripts"; exit 1; }
  # Genuinely old finder text: the newest historic blob under either finder
  # path that matches neither the current finder nor the current shim, so the
  # probe exercises the historic-stub branches instead of the harness-bytes one.
  harness_txt="$PWD/template/scripts/harness"
  shim_txt="$PWD/template/scripts/h"
  cands="$(git -C "$PWD" log --all --format="%H" --follow -- template/scripts/harness 2>/dev/null)"
  [ -n "$cands" ] || cands="$(git -C "$PWD" log --all --format="%H" -- template/scripts/h 2>/dev/null)"
  old_found=""
  for c in $cands; do
    for p in template/scripts/harness template/scripts/h; do
      if git -C "$PWD" show "$c:$p" >"$probe/scripts/h" 2>/dev/null; then
        if ! cmp -s "$probe/scripts/h" "$harness_txt" && ! cmp -s "$probe/scripts/h" "$shim_txt"; then old_found="$c:$p"; break 2; fi
      fi
    done
  done
  [ -n "$old_found" ] || { echo "error: no genuinely old finder text in history - shallow clone?"; exit 1; }
  chmod +x "$probe/scripts/h" || { echo "error: cannot chmod old finder"; exit 1; }
  (cd "$probe" && git add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit --no-verify -qm "seed old finder" >/dev/null 2>&1) || { echo "error: cannot commit old finder"; exit 1; }
  out=$(bin/harness migrate --apply "$probe" 2>&1) || { echo "error: migrate failed"; echo "$out"; exit 1; }
  [ -f "$probe/scripts/harness" ] || { echo "error: migrate never wrote the finder"; exit 1; }
  [ -x "$probe/scripts/harness" ] || { echo "error: finder not executable"; exit 1; }
  [ -x "$probe/scripts/h" ] || { echo "error: shim not executable"; exit 1; }
  cmp -s "$shim_txt" "$probe/scripts/h" || { echo "error: scripts/h is not the shim"; exit 1; }
  (cd "$probe" && git add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit --no-verify -qm "migrate old finder" >/dev/null 2>&1) || { echo "error: cannot commit migration"; exit 1; }
  out2=$(bin/harness migrate --apply "$probe" 2>&1) || { echo "error: second migrate failed"; echo "$out2"; exit 1; }
  if [ -n "$(git -C "$probe" status --porcelain)" ]; then
    echo "error: second migrate dirtied an already migrated tree"; exit 1;
  fi'

# A plugin-only .opencode/opencode.json shadows the root one — opencode reads
# only the deeper file — so without its instructions AGENTS.md never loads.
# The pin check fails it loudly rather than passing a tree that unloads the
# contract.
probe_step --when "template/scripts/opencode-pin.py template/stubs/opencode.json opencode.json .opencode/opencode.json" "a plugin-only opencode shadow fails the pin check" bash -c '
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
probe_step --when "bin/* commands/add.sh commands/lib/*" "add initialises a missing git repository" bash -c '
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
probe_step --when "bin/* commands/add.sh commands/lib/*" "add refuses a subdirectory of a repository" bash -c '
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
probe_step --when "bin/* commands/add.sh commands/lib/*" "add refuses a broken .git entry" bash -c '
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
probe_step --when "bin/* commands/add.sh commands/lib/*" "add refuses a bare repository" bash -c '
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
probe_step --when "bin/* commands/add.sh commands/lib/*" "add accepts a linked worktree" bash -c '
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
probe_step --when "template/scripts/hooks/commit-msg template/stubs/scripts/hooks/commit-msg commands/lib/*" "the commit-msg hook rejects a bead-less commit" bash -c '
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
probe_step --when "template/scripts/harness scripts/harness scripts/verify.steps.sh scripts/review.scope.sh" "doctor names edited seeds as overlays, not shadows" bash -c '
  golden_probe || exit 1
  echo "# local steps" >> "$probe/scripts/verify.steps.sh" ||
    { echo "error: cannot edit the steps file"; exit 1; }
  echo "# local scope" >> "$probe/scripts/review.scope.sh" ||
    { echo "error: cannot edit the scope file"; exit 1; }
  out=$(HARNESS_HOME="$PWD" "$probe/scripts/harness" doctor 2>&1) ||
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
probe_step --when "template/scripts/review.sh scripts/review.scope.sh" "review honors the scope overlay" bash -c '
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
  out=$(HARNESS_HOME="$PWD" "$probe/scripts/harness" review </dev/null 2>&1) ||
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
probe_step --when "template/scripts/verify.sh scripts/verify.steps.sh" "a missing steps overlay fails the gate loudly" bash -c '
  golden_probe || exit 1
  rm "$probe/scripts/verify.steps.sh" || { echo "error: cannot remove the steps file"; exit 1; }
  out=$(HARNESS_HOME="$PWD" "$probe/scripts/harness" verify --quick 2>&1) &&
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
probe_step --when "bin/* commands/add.sh commands/lib/*" "a fresh install hydrates the committed ledger export" bash -c '
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
probe_step --when "template/scripts/ledger-export-check.sh template/scripts/hooks/pre-commit template/stubs/scripts/hooks/pre-commit commands/lib/*" "a stale ledger export fails the gate naming the bead" bash -c '
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
probe_step --when "template/scripts/ledger-export-check.sh template/scripts/hooks/pre-commit template/stubs/scripts/hooks/pre-commit commands/lib/*" "a commit refreshes the ledger export without a manual regen" bash -c '
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
probe_step --when "template/scripts/ledger-export-check.sh template/scripts/hooks/pre-commit template/stubs/scripts/hooks/pre-commit commands/lib/*" "a deleted bead still exported fails the gate naming the bead" bash -c '
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
probe_step --when "template/scripts/ledger-export-check.sh template/scripts/hooks/pre-commit template/stubs/scripts/hooks/pre-commit commands/lib/*" "an untracked ledger export fails the gate saying to track it" bash -c '
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
probe_step --when "template/scripts/ledger-export-check.sh template/scripts/hooks/pre-commit template/stubs/scripts/hooks/pre-commit commands/lib/*" "an empty install passes the ledger export check" bash -c '
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
probe_step --when "template/scripts/ledger-export-check.sh template/scripts/hooks/pre-commit template/stubs/scripts/hooks/pre-commit commands/lib/*" "a clone with no live ledger skips the export check" bash -c '
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

# Static lane through the real gate lane: unrelated silence, clean pass, duplicate fail, nested and untracked duplicates, and deletion credit.
probe_step --when "template/scripts/lib/knowledge_layer.py template/scripts/context.py AGENTS.md CLAUDE.md AGENTS.local.md template/AGENTS.md template/CLAUDE.md template/AGENTS.local.md template/.claude/skills/* template/.claude/agents/*" "knowledge static lane" bash -c '
PROBE_SCENARIO="knowledge static lane"
golden_probe || probe_fail "no golden fixture"
top="$PWD"
(cd "$probe" && git add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit --no-verify -qm init) || probe_fail "probe init commit failed"
run_static_lane() {
(cd "$probe" && HARNESS_HOME="$top" "$probe/scripts/harness" verify --lane knowledge-static 2>&1)
}
echo "probe" > "$probe/probe-unrelated.txt" || probe_fail "cannot dirty an unrelated file"
out=$(run_static_lane) || probe_fail "lane failed on an unrelated diff"
echo "$out" | grep -q "no knowledge-layer change" || probe_fail "lane never stayed silent on an unrelated diff"
rm "$probe/probe-unrelated.txt" || probe_fail "cannot clean the unrelated file"
printf "%s\n" "# probe knowledge line" >> "$probe/AGENTS.md" || probe_fail "cannot dirty AGENTS.md"
out=$(run_static_lane) || probe_fail "lane failed a clean knowledge diff"
echo "$out" | grep -q "cost and duplicates clean" || probe_fail "lane never passed a clean knowledge diff"
(cd "$probe" && git checkout -- AGENTS.md >/dev/null 2>&1) || probe_fail "cannot restore AGENTS.md"
mkdir -p "$probe/.claude/skills/probe-dup" || probe_fail "cannot make the probe skill"
printf "%s\n" "---" "description: probe dup skill" "---" "" "The probe duplicate fact about harness layers is intentionally repeated here verbatim for the static lane." > "$probe/.claude/skills/probe-dup/SKILL.md" || probe_fail "cannot plant the probe skill"
printf "%s\n" "The probe duplicate fact about harness layers is intentionally repeated here verbatim for the static lane." >> "$probe/AGENTS.md" || probe_fail "cannot dirty AGENTS.md with the duplicate"
out=$(run_static_lane) && probe_fail "lane passed a duplicate fact" || true
echo "$out" | grep -q "duplicate facts" || probe_fail "failure never said duplicate"
echo "$out" | grep -q "probe duplicate fact" || probe_fail "failure never named the copied sentence"
rm -rf "$probe/.claude/skills/probe-dup" || probe_fail "cannot clean the probe skill"
(cd "$probe" && git checkout -- AGENTS.md >/dev/null 2>&1) || probe_fail "cannot restore AGENTS.md"
printf "%s\n" "# probe knowledge line" "The nested probe sentence about harness layering repeats here verbatim for the nested static check" >> "$probe/CLAUDE.md" || probe_fail "cannot dirty CLAUDE.md"
mkdir -p "$probe/.claude/skills/suite/probe-nested" || probe_fail "cannot make the nested skill"
printf "%s\n" "---" "description: probe nested static skill" "---" "" "The nested probe sentence about harness layering repeats here verbatim for the nested static check" > "$probe/.claude/skills/suite/probe-nested/SKILL.md" || probe_fail "cannot plant the nested skill"
out=$(run_static_lane) && probe_fail "lane passed a nested duplicate" || true
echo "$out" | grep -q "suite/probe-nested" || probe_fail "failure never named the nested skill"
echo "$out" | grep -q "nested probe sentence about harness layering" || probe_fail "failure never named the copied sentence"
rm -rf "$probe/.claude/skills/suite" || probe_fail "cannot clean the nested skill"
(cd "$probe" && git checkout -- CLAUDE.md >/dev/null 2>&1) || probe_fail "cannot restore CLAUDE.md"
printf "%s\n" "the probe layer sentence about harness budgets repeats here verbatim for the untracked duplicate check" >> "$probe/CLAUDE.md" || probe_fail "cannot plant the probe sentence"
(cd "$probe" && git add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit --no-verify -qm "probe sentence" >/dev/null 2>&1) || probe_fail "cannot commit the probe sentence"
mkdir -p "$probe/.claude/skills/probe-new" || probe_fail "cannot make the probe skill"
printf "%s\n" "---" "description: probe new skill for the untracked duplicate check" "---" "" "the probe layer sentence about harness budgets repeats here verbatim for the untracked duplicate check" > "$probe/.claude/skills/probe-new/SKILL.md" || probe_fail "cannot plant the untracked skill"
out=$(run_static_lane) && probe_fail "lane passed an untracked duplicate" || true
echo "$out" | grep -q "repeats here verbatim" || probe_fail "failure never named the copied sentence"
rm -rf "$probe/.claude/skills/probe-new" || probe_fail "cannot clean the probe skill"
mkdir -p "$probe/.claude/skills/probe-big" || probe_fail "cannot make the probe skill"
desc=$(python3 -c "print(chr(120) * 12000)") || probe_fail "cannot size the probe description"
printf "%s\n" "---" "description: $desc" "---" "" "Probe big body." > "$probe/.claude/skills/probe-big/SKILL.md" || probe_fail "cannot plant the probe skill"
(cd "$probe" && git add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit --no-verify -qm "probe big" >/dev/null 2>&1) || probe_fail "cannot commit the probe skill"
rm -rf "$probe/.claude/skills/probe-big" || probe_fail "cannot delete the probe skill"
pad=$(python3 -c "print(chr(121) * 9000)") || probe_fail "cannot size the probe addition"
printf "%s\n" "# probe costly line" "$pad" >> "$probe/CLAUDE.md" || probe_fail "cannot dirty CLAUDE.md"
out=$(run_static_lane) || probe_fail "lane failed a net-negative knowledge diff"
echo "$out" | grep -q "tokens (-" || probe_fail "cost line never showed the deletion credit"
'

# Eval runner in one copy: two runs prove lines, worktree, append, pin; then one spaced name, missing dir fails, empty suite skips.
probe_step --when "template/scripts/eval.sh template/harness/evals/*" "eval runner" bash -c '
PROBE_SCENARIO="eval runner"
golden_probe || probe_fail "no golden fixture"
top="$PWD"
root="$(probe_shared_root "$probe")" || probe_fail "finder cannot resolve the harness"
printf "%s\n" "step \"probe build\" true" > "$probe/scripts/verify.steps.sh" || probe_fail "cannot plant trivial steps"
(cd "$probe" && git add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit --no-verify -qm init) || probe_fail "probe init commit failed"
fake="$probe/opencode"
printf "%s\n" "#!/usr/bin/env python3" "import json,os,sys" "a=sys.argv[1:]" "if a[:1]==[\"--version\"]:" "    print(\"opencode 2.0.0\")" "else:" "    open(\"msg.txt\",\"w\").write(\"probe work for har-000\n\")" "    open(\"gate-cmd.txt\",\"w\").write(\"scripts/harness verify\n\")" "    print(json.dumps({\"type\":\"text\",\"part\":{\"text\":\"probe reply\"},\"sessionID\":\"ses_probe\"}))" > "$fake" || probe_fail "cannot plant fake opencode"
chmod +x "$fake" || probe_fail "cannot chmod the fake"
rev="$(cd "$probe" && git rev-parse HEAD)" || probe_fail "cannot read the probe HEAD"
before=$(git -C "$probe" worktree list 2>/dev/null | wc -l | tr -d " ") || probe_fail "cannot list worktrees"
out=$(cd "$probe" && env -u OPENCODE_SESSION_ID -u OPENCODE_BIN HARNESS_HOME="$top" PATH="$probe:$PATH" HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" bash "$root/scripts/eval.sh" 2>&1) || probe_fail "eval failed on a clean layer"
n=$(echo "$out" | grep -c "^ok eval " || true)
[ "$n" = "2" ] || probe_fail "want one ok line per case"
after=$(git -C "$probe" worktree list 2>/dev/null | wc -l | tr -d " ") || probe_fail "cannot relist worktrees"
[ "$after" = "$before" ] || probe_fail "eval left a worktree behind"
rows=$(grep -c "\"case\":" "$probe/harness/evals/results.jsonl" 2>/dev/null || true)
[ "$rows" = "2" ] || probe_fail "want 2 result rows"
python3 - "$probe/harness/evals/results.jsonl" "$rev" <<PYEOF || probe_fail "stamped rev is not the pinned HEAD"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip() and not l.startswith("#")]
assert rows, "no rows stamped"
assert all(row.get("harness_rev") == sys.argv[2] for row in rows), rows
PYEOF
cp "$probe/harness/evals/results.jsonl" "$probe/results-backup.jsonl" || probe_fail "cannot back up results"
mkdir -p "$probe/gitlog" || probe_fail "cannot make the git log dir"
realgit="$(command -v git)" || probe_fail "cannot locate git"
printf "%s\n" "#!/bin/bash" "printf \"%s\\n\" \"git \$*\" >> \"$probe/gitlog/calls\"" "exec \"$realgit\" \"\$@\"" > "$probe/gitlog/git" || probe_fail "cannot plant fake git"
chmod +x "$probe/gitlog/git" || probe_fail "cannot chmod the fake git"
out=$(cd "$probe" && env -u OPENCODE_SESSION_ID -u OPENCODE_BIN HARNESS_HOME="$top" PATH="$probe/gitlog:$probe:$PATH" HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" bash "$root/scripts/eval.sh" --case commit-bead 2>&1) || probe_fail "second eval failed"
echo "$out" | grep -q "^ok eval commit-bead" || probe_fail "second run never passed commit-bead"
grep -q "show $rev:" "$probe/gitlog/calls" || probe_fail "verdict never read its baseline at the pinned rev"
if grep -q "show HEAD:" "$probe/gitlog/calls"; then probe_fail "verdict read its baseline at live HEAD"; fi
rows=$(grep -c "\"case\":" "$probe/harness/evals/results.jsonl" 2>/dev/null || true)
[ "$rows" = "3" ] || probe_fail "second run never appended"
n=$(wc -l < "$probe/results-backup.jsonl" | tr -d " ") || probe_fail "cannot count backup lines"
head -n "$n" "$probe/harness/evals/results.jsonl" > "$probe/results-head.jsonl" || probe_fail "cannot slice the rerun"
cmp -s "$probe/results-backup.jsonl" "$probe/results-head.jsonl" || probe_fail "second run rewrote earlier rows"
rm -f "$probe/results-backup.jsonl" "$probe/results-head.jsonl" || probe_fail "cannot clean the comparison files"
mkdir -p "$probe/harness/evals/my case" || probe_fail "cannot make the spaced case"
cp "$probe/harness/evals/commit-bead/task.md" "$probe/harness/evals/commit-bead/check.sh" "$probe/harness/evals/commit-bead/base" "$probe/harness/evals/my case/" || probe_fail "cannot seed the spaced case"
out=$(cd "$probe" && env -u OPENCODE_SESSION_ID -u OPENCODE_BIN HARNESS_HOME="$top" PATH="$probe:$PATH" HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" bash "$root/scripts/eval.sh" --case "my case" 2>&1) || probe_fail "eval failed on a spaced case name"
n=$(echo "$out" | grep -c "^ok eval " || true)
[ "$n" = "1" ] || probe_fail "want one ok line for the spaced case"
python3 - "$probe/harness/evals/results.jsonl" <<PYEOF || probe_fail "no valid passing row for the spaced case"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip() and not l.startswith("#")]
assert any(row.get("case") == "my case" and row.get("pass") is True for row in rows), rows
PYEOF
rm -rf "$probe/harness/evals/my case" || probe_fail "cannot clean the spaced case"
mv "$probe/harness/evals" "$probe/harness/evals-away" || probe_fail "cannot hide the probe evals"
out=$(cd "$probe" && HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" bash "$root/scripts/eval.sh" 2>&1) && probe_fail "eval passed with no evals dir" || true
echo "$out" | grep -q "no evals dir" || probe_fail "eval never named the missing dir"
echo "$out" | grep -q "harness/evals" || probe_fail "eval never said which dir"
mv "$probe/harness/evals-away" "$probe/harness/evals" || probe_fail "cannot restore the probe evals"
rm -rf "$probe/harness/evals/commit-bead" "$probe/harness/evals/verify-gate" || probe_fail "cannot wipe the probe cases"
rm -f "$probe/harness/evals/results.jsonl" || probe_fail "cannot clear the probe rows"
out=$(cd "$probe" && env -u OPENCODE_SESSION_ID -u OPENCODE_BIN HARNESS_HOME="$top" HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" bash "$root/scripts/eval.sh" 2>&1) || probe_fail "eval failed an empty suite with no baseline"
echo "$out" | grep -q "SKIP" || probe_fail "empty run never said SKIP"
echo "$out" | grep -q "harness/evals" || probe_fail "SKIP never named the evals dir"
if echo "$out" | grep -q "^FAIL eval "; then probe_fail "empty skip failed a case"; fi
[ ! -e "$probe/harness/evals/results.jsonl" ] || probe_fail "empty skip wrote result rows"
'

# Behavioural lane through the real gate lane: one case keeps each run cheap while the trigger and verdict prove memory-only skip, break naming the case, benign pass, body-prose skip and deleted skill fail.
probe_step --when "template/scripts/eval.sh template/harness/evals/* template/scripts/lib/knowledge_layer.py template/.claude/skills/* AGENTS.md CLAUDE.md AGENTS.local.md template/AGENTS.md template/CLAUDE.md template/AGENTS.local.md" "knowledge behavioural lane" bash -c '
PROBE_SCENARIO="knowledge behavioural lane"
golden_probe || probe_fail "no golden fixture"
top="$PWD"
root="$(probe_shared_root "$probe")" || probe_fail "finder cannot resolve the harness"
mkdir -p "$probe/.claude/skills/probe-victim" || probe_fail "cannot make the probe victim skill"
mkdir -p "$probe/.claude/skills/probe-trigger" || probe_fail "cannot make the probe trigger skill"
printf "%s\n" "---" "description: probe victim skill the eval cases depend on" "---" "" "Probe victim body." > "$probe/.claude/skills/probe-victim/SKILL.md" || probe_fail "cannot plant the probe victim skill"
printf "%s\n" "---" "description: probe trigger skill for the behavioural lane" "---" "" "Probe trigger body." > "$probe/.claude/skills/probe-trigger/SKILL.md" || probe_fail "cannot plant the probe trigger skill"
(cd "$probe" && git add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit --no-verify -qm init) || probe_fail "probe init commit failed"
rm -rf "$probe/harness/evals/verify-gate" || probe_fail "cannot trim to one case"
# One case keeps each lane run cheap; the eval runner scenario covers the multi-case verdict.
fake="$probe/opencode"
printf "%s\n" "#!/usr/bin/env python3" "import json,os,sys" "a=sys.argv[1:]" "if a[:1]==[\"--version\"]:" "    print(\"opencode 2.0.0\")" "else:" "    bad=False" "    try:" "        bad=\"BREAK\" in open(\"CLAUDE.md\").read()" "    except OSError:" "        bad=False" "    good=os.path.isfile(\".claude/skills/probe-victim/SKILL.md\")" "    ok=(not bad) and good" "    open(\"msg.txt\",\"w\").write(\"probe work for har-000\n\" if ok else \"no bead here\n\")" "    open(\"gate-cmd.txt\",\"w\").write(\"scripts/harness verify\n\" if ok else \"make check\n\")" "    print(json.dumps({\"type\":\"text\",\"part\":{\"text\":\"probe reply\"},\"sessionID\":\"ses_probe\"}))" > "$fake" || probe_fail "cannot plant fake opencode"
chmod +x "$fake" || probe_fail "cannot chmod the fake"
out=$(cd "$probe" && env -u OPENCODE_SESSION_ID -u OPENCODE_BIN HARNESS_HOME="$top" PATH="$probe:$PATH" HARNESS_PROJECT="$probe" HARNESS_ROOT="$root" bash "$root/scripts/eval.sh" 2>&1) || probe_fail "baseline eval failed on a clean layer"
n=$(echo "$out" | grep -c "^ok eval " || true)
[ "$n" = "1" ] || probe_fail "want one ok line at baseline"
(cd "$probe" && git add harness/evals/results.jsonl >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit --no-verify -qm "probe baseline results" >/dev/null 2>&1) || probe_fail "cannot commit the baseline results"
run_behavioural_lane() {
(cd "$probe" && env -u OPENCODE_SESSION_ID -u OPENCODE_BIN HARNESS_HOME="$top" PATH="$probe:$PATH" "$probe/scripts/harness" verify --lane knowledge-behavioural 2>&1)
}
(cd "$probe" && bd remember "probe memory trap for the behavioural lane" --key "probe-memory-trap" >/dev/null 2>&1) || probe_fail "cannot remember a probe memory"
tries=0
while ! (cd "$probe" && bd recall probe-memory-trap >/dev/null 2>&1); do tries=$((tries + 1)); [ "$tries" -ge 60 ] && probe_fail "probe memory never landed"; sleep 0.5; done
(cd "$probe" && bd export --include-memories -o .beads/issues.jsonl >/dev/null 2>&1) || probe_fail "cannot regen the probe export"
(cd "$probe" && git add .beads/issues.jsonl >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit --no-verify -qm "probe memory export" >/dev/null 2>&1) || probe_fail "cannot commit the probe export"
rows0=$(grep -c "\"case\":" "$probe/harness/evals/results.jsonl" 2>/dev/null || true)
out=$(run_behavioural_lane) || probe_fail "lane failed on a memory-only change"
echo "$out" | grep -q "no always-loaded change" || probe_fail "lane never skipped on a memory-only change"
rows1=$(grep -c "\"case\":" "$probe/harness/evals/results.jsonl" 2>/dev/null || true)
[ "$rows0" = "$rows1" ] || probe_fail "an eval ran on a memory-only change"
printf "%s\n" "BREAK the always-loaded layer for the probe" >> "$probe/CLAUDE.md" || probe_fail "cannot break CLAUDE.md"
out=$(run_behavioural_lane) && probe_fail "lane passed a breaking CLAUDE.md change" || true
echo "$out" | grep -q "FAIL  knowledge behavioural" || probe_fail "failure never named the behavioural lane"
echo "$out" | grep -q "commit-bead" || probe_fail "failure never named the case"
(cd "$probe" && git checkout -- CLAUDE.md >/dev/null 2>&1) || probe_fail "cannot restore CLAUDE.md"
printf "%s\n" "# probe local line" >> "$probe/AGENTS.local.md" || probe_fail "cannot dirty AGENTS.local.md"
out=$(run_behavioural_lane) || probe_fail "lane failed a benign AGENTS.local.md change"
echo "$out" | grep -q "  ok    knowledge behavioural" || probe_fail "lane never passed the benign change"
(cd "$probe" && git checkout -- AGENTS.local.md >/dev/null 2>&1) || probe_fail "cannot restore AGENTS.local.md"
printf "%s\n" "See the description: field above for the full contract." >> "$probe/.claude/skills/probe-trigger/SKILL.md" || probe_fail "cannot dirty the probe skill body"
rows0=$(grep -c "\"case\":" "$probe/harness/evals/results.jsonl" 2>/dev/null || true)
out=$(run_behavioural_lane) || probe_fail "lane failed on skill body prose"
echo "$out" | grep -q "no always-loaded change" || probe_fail "lane never skipped skill body prose"
rows1=$(grep -c "\"case\":" "$probe/harness/evals/results.jsonl" 2>/dev/null || true)
[ "$rows0" = "$rows1" ] || probe_fail "an eval ran on skill body prose"
(cd "$probe" && git checkout -- .claude/skills/probe-trigger/SKILL.md >/dev/null 2>&1) || probe_fail "cannot restore the probe skill"
rm -rf "$probe/.claude/skills/probe-victim" || probe_fail "cannot delete the probe skill"
out=$(run_behavioural_lane) && probe_fail "lane passed a deleted dependent skill" || true
echo "$out" | grep -q "FAIL  knowledge behavioural" || probe_fail "failure never named the behavioural lane"
echo "$out" | grep -q "commit-bead" || probe_fail "failure never named the case"
'

if [ "$mode" != "--quick" ]; then
  step "cli lists commands" bash -c 'bin/harness | grep -q "^  add"'
fi

