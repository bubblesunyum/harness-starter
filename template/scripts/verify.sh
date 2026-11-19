#!/bin/bash
# The gate: build, test, and smoke the app behind a single exit code, so an
# agent can prove its own work without a human reading a screen.
#
#   scripts/harness verify           # the changed paths pick the lane (see below)
#   scripts/harness verify --full    # everything, whatever changed
#   scripts/harness verify --quick   # fast lane only: no throwaway-repo probes
#   scripts/harness verify --lane <name,...>   # only one gate lane (see below)
#   scripts/harness verify --probe "<exact name>"  # one probe, the way the gate runs it
#
# Diff-scoped lanes. The default run looks at what moved: only ledger paths
# (.beads/, harness/handoffs/, harness/laurels.jsonl) mean a bead close or a
# note, which no throwaway-repo probe can observe — so the ledger lane runs
# the export check plus every serial step (the local-ok spec check reads the
# live ledger, which a beads-only diff does move) and skips only the probes,
# loudly, finishing in seconds. Anything else runs everything the default
# lane runs, including the throwaway-repo probes; an explicit --full does
# too, whatever changed. When the scope cannot be determined — not a git
# checkout, git itself failing — the gate runs everything and says so: a
# wrongly narrow gate is the silent failure this project exists to avoid, and
# the same goes for a clean tree, which has nothing to narrow from.
#
# Parallel probes. probe_step runs its body in the background instead of
# inline — at most PROBE_MAX at once (the CPU count, clamped 2..8), with
# slot reuse: when the flight is full the next probe polls the in-flight
# pids with kill -0 and starts as soon as any slot frees (reaping each
# finished pid with wait) instead of waiting on the oldest — and
# every step drains whatever is still flying before it runs, so the
# one-line-per-step output keeps source order: quick checks print while
# probes run, each probe's line lands at the next serial step, and the
# stragglers print at the final drain below. A probe body must stay
# self-contained the way it always had to be for `bash -c`: the background
# subshell starts trap-free, so a fixture-reaping EXIT trap set while
# sourcing the project steps can never fire inside it.
#
# Scoped lanes, one contract. The probe steps below each build a throwaway repo
# and cost seconds apiece, which prices a full run in minutes — too slow for
# the edit-and-check loop. --quick runs only the steps that prove the tree as
# it stands (parses, staleness, contract match, unit checks) and skips the
# probes loudly rather than silently. Run it while iterating, the full gate
# before committing: a quick green is a signal, not proof.
#
# Impact-scoped probes. probe_step --when "<glob> ..." runs only when a
# changed path matches one of its globs (or a gate file moved, which runs
# everything); otherwise it skips loudly as unaffected. Undeclared probes
# always run, and --lane runs ignore --when entirely.
#
# One lane for probes: --lane runs scope detection plus only the named lane(s)
# (knowledge-static, knowledge-behavioural, comma-separated for both) with the
# same lines and exit status as the full gate — no probes, no other serial
# steps, no golden fixture. Probes asserting lane behavior call this instead of
# pasting the lane's python or nesting a full gate.
#
# Single probe. --probe "<exact name>" runs scope detection, every `step`
# (project build and setup included), and only the probe_step with that exact
# name; the harness-ownership checks (ledger export, context docs, knowledge
# static, opencode agents and pin) skip — through the same
# background machinery as the gate, ignoring --when — so a worker proves a
# probe the way the gate runs it instead of pasting a copy of its body (a
# pasted copy once passed in isolation and failed the gate on quoting).
# Every other probe skips silently, and the run ends with one line
# "verify: --probe ran 1 of M probe(s)". An unknown name exits 2 naming close
# matches. Its own scratch log dir (removed on pass, kept and printed on
# failure) and the gate's exit status.
#
# Ledger guard. Probes build throwaway repos but start in the starter's cwd,
# and one probe filed its memory there — writing into the real ledger on every
# gate run with nothing catching it. So every probe subshell runs with a bd
# shim first on PATH: bd from the live checkout hits the log and exits 3,
# while bd anywhere else (a throwaway repo, or under .tmp/ where the golden
# cache lives) execs the real binary. After the final drain a non-empty hits
# file fails "probes left the live ledger untouched" naming the strays; else
# ok. Loud skip with no bd; lane runs skip it entirely (they run inside probe
# copies). No snapshots — a concurrent session's routine ledger write can no
# longer fail this gate.
#
# Output is deliberately tiny. A build tool prints tens of thousands of lines
# and an agent that pipes that into its context has spent a chunk of the day's
# tokens to learn one bit — did it pass. Full logs land in /tmp/<prefix>-verify/
# (the ledger's bead prefix, resolved below) and are worth reading only when
# something fails.
#
# Everything in scripts/verify.steps.sh is yours to replace with your project's
# real build and test commands. Everything here works as-is: keep checks going
# through `step` (`probe_step` for checks too slow for the --quick lane),
# which swallows the log and reports one line — that is the whole point of
# the gate.
set -uo pipefail
mode="--default"
lane_list=""
probe_name=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quick|--full|--default) mode="$1"; shift;;
    --lane)
      [ -n "${2:-}" ] || { echo "verify: --lane needs a lane list (knowledge-static,knowledge-behavioural)" >&2; exit 2; }
      lane_list="$2"; shift 2;;
    --probe)
      [ -n "${2:-}" ] || { echo "verify: --probe needs an exact probe name" >&2; exit 2; }
      probe_name="$2"; shift 2;;
    *) shift;;
  esac
done
# Single-probe mode, read as a question rather than an empty-string test.
in_probe_mode() { [ -n "$probe_name" ]; }
if in_probe_mode && [ -n "$lane_list" ]; then
  echo "verify: --probe and --lane cannot be combined" >&2; exit 2
fi

ROOT="${HARNESS_PROJECT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# Where this script was loaded from: the shared checkout, whose scripts/ holds
# the copy a project file shadows. Same as ROOT when run as an installed copy.
HARNESS="${HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

. "$HARNESS/scripts/lib/paths.sh"
. "$HARNESS/scripts/lib/journal.sh"

# The ledger's bead prefix, asked of the ledger itself at runtime — baked into
# this file once per install, which made every copy differ and un-updatable.
# Falls back to the directory name, derived the same way `harness add` does.
_harness_prefix() {
  local p=""
  if command -v bd >/dev/null 2>&1; then
    # Never `bd config get` or `bd info` here: both auto-import a stale
    # .beads/issues.jsonl when the ledger looks stale to them, resurrecting
    # deleted beads — and this lookup runs before the ledger-export check that
    # exists to catch that drift, so it must never be the thing that heals it
    # (har-67c). `bd list` never imports, so the prefix comes from the first
    # bead id instead; an empty ledger has no ids and falls through below.
    p="$(bd list --json --all 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); i=(d[0].get("id","") if d else ""); print(i.split("-",1)[0] if "-" in i else "")' 2>/dev/null)" || true
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
if [ -n "$lane_list" ] || in_probe_mode; then
  # Lane runs happen inside probe copies that share the gate log dir, and a
  # --probe run beside a full gate would clobber its fixed filenames the same
  # way: point both at scratch. Lane removes its dir on its own path below;
  # --probe removes its on pass and keeps it (printed) on failure. Probe
  # bodies reset EXIT traps, so no trap here would reliably run there.
  LOGS="$(mktemp -d 2>/dev/null)" || { echo "verify: cannot create a scratch log dir" >&2; exit 1; }
fi
# Per-step seconds for the last run, in run order (`sort -rn` for
# slowest-first): har-ckm showed the gate's total cost with no breakdown, so
# the next slowdown gets measured rather than guessed at. Truncated here so
# the file describes one run.
rm -f "$LOGS/timings"

failed=0
# Every failure names its step for the summary before the verdict: report()
# records serial steps here, drain_probes records failed probes.
failed_names=()
note_failed() {
  failed=1
  local want="$1" e
  # The ${arr[@]+...} form expands to nothing when the array is empty: under
  # set -u a bare empty array expansion fails, so the loop needs the guard.
  for e in ${failed_names[@]+"${failed_names[@]}"}; do
    [ "$e" = "$want" ] && return 0
  done
  failed_names+=("$want")
}
started=$SECONDS
probes_run=0
probes_skipped_unaffected=0
# Single-probe runs: every probe_step counts itself for the ran-of-M summary,
# and only the exact match runs. probe_all_names feeds the exit-2 candidates.
probe_total=0
probe_matched=0
probe_all_names=()
probe_pids=()
probe_bases=()
probe_names=()

# How many probes fly at once: the machine's CPUs, clamped 2..8. Probes are
# subprocess-bound (bd, git, python in throwaway repos), so core count is the
# right bound and 8 keeps a big machine from fork-bombing itself.
_probe_cpus() {
  local n=""
  n="$(sysctl -n hw.ncpu 2>/dev/null)" || n=""
  if [ -z "$n" ]; then
    n="$(getconf _NPROCESSORS_ONLN 2>/dev/null)" || n=""
  fi
  printf '%s' "$n"
}
PROBE_MAX="$(_probe_cpus)"
case "$PROBE_MAX" in ''|*[!0-9]*) PROBE_MAX=4;; esac
if [ "$PROBE_MAX" -lt 2 ]; then PROBE_MAX=2; fi
if [ "$PROBE_MAX" -gt 8 ]; then PROBE_MAX=8; fi

# Probe and step names are prose and may carry slashes; file stems cannot, so
# slashes become dashes alongside spaces.
slug() { printf '%s' "${1// /-}" | tr '/' '-'; }

# Everything interesting in a build log is on a line saying "error:" — the rest
# is compile invocations. Keep the first few, deduplicated, and say where the
# whole thing is. Widen the pattern if your toolchain words failures differently.
report() {
  local name="$1" log="$2" status="$3"
  if [ "$status" -eq 0 ]; then
    echo "  ok    $name"
  else
    note_failed "$name"
    echo "  FAIL  $name"
    grep -E "(error|failed):" "$log" | sed -e 's/^/        /' | sort -u | head -8
    echo "        full log: $log"
  fi
}

# One capture path for the check-style failures below (context docs,
# opencode agents, opencode pin, project steps): write the .log and .status,
# echo the output, and report the FAIL line. Keeps the four call sites one
# line each instead of a copied four-liner.
capture_report() {
  local name="$1" output="$2" status="$3"
  local log="$LOGS/$(slug "$name").log"
  printf '%s\n' "$output" > "$log"
  echo "$status" > "$log.status"
  echo "$output"
  report "$name" "$log" "$status"
}

# Wait out every probe still flying and print their one-liners in the order
# they were enqueued — never in completion order, so the log reads the same
# every run. Statuses come from each step's .status file rather than from
# wait, because the printed report is what names the failure. Length-guarded
# rather than the ${arr[@]+...} idiom: the arrays below are always set, and
# an empty expansion under `set -u` is the failure being avoided.
drain_probes() {
  if [ "${#probe_pids[@]}" -gt 0 ]; then
    local pid
    for pid in "${probe_pids[@]}"; do
      wait "$pid" 2>/dev/null || true
    done
    probe_pids=()
  fi
  if [ "${#probe_bases[@]}" -gt 0 ]; then
    local base st i
    for i in "${!probe_bases[@]}"; do
      base="${probe_bases[$i]}"
      if [ -f "$LOGS/$base.report" ]; then
        cat "$LOGS/$base.report"
        rm -f "$LOGS/$base.report"
      fi
      st=""
      if [ -f "$LOGS/$base.log.status" ]; then
        st="$(cat "$LOGS/$base.log.status")"
      fi
      if [ "$st" != "0" ]; then
        note_failed "${probe_names[$i]}"
      fi
      probes_run=$((probes_run + 1))
    done
    probe_bases=()
    probe_names=()
  fi
}

# Bound the flight without wait -n (bash 3.2 has none): poll the in-flight
# pids with kill -0 and reap each finished pid with wait, so the next
# probe starts as soon as any slot frees (slot reuse) instead of waiting
# on the oldest. probe_pids is an unordered in-flight set;
# probe_bases/probe_names stay in enqueue order for drain_probes.
wait_for_probe_slot() {
  local slot_pid live_pids
  while [ "${#probe_pids[@]}" -ge "$PROBE_MAX" ]; do
    live_pids=()
    for slot_pid in ${probe_pids[@]+"${probe_pids[@]}"}; do
      if kill -0 "$slot_pid" 2>/dev/null; then
        live_pids+=("$slot_pid")
      else
        wait "$slot_pid" 2>/dev/null || true
      fi
    done
    probe_pids=(${live_pids[@]+"${live_pids[@]}"})
    if [ "${#probe_pids[@]}" -ge "$PROBE_MAX" ]; then
      sleep 0.2
    fi
  done
}

step() {
  # A serial step is a barrier: whatever is still flying prints first, so the
  # output keeps source order even though probes finish out of order. Skipped
  # inside a probe's own subshell (PROBE_CHILD), which holds a copy of queues
  # it must neither wait on nor print.
  if [ -z "${PROBE_CHILD:-}" ]; then
    drain_probes
  fi
  local name="$1"; shift
  local log="$LOGS/$(slug "$name").log"
  local t0=$SECONDS
  "$@" > "$log" 2>&1
  local status=$?
  # The exit code alongside the log, so readers need not guess the verdict
  # from the text: a passing step often logs nothing at all.
  echo "$status" > "$log.status"
  echo "$((SECONDS - t0)) $name" >> "$LOGS/timings"
  report "$name" "$log" $status
}

# A step too slow for the --quick lane: throwaway-repo probes and heavy
# suites. Skipped there, loudly: a green suite that silently ran nothing is
# the failure the steps file warns about, so skips print as skips. Otherwise
# the body runs in the background (bounded above with slot reuse) and its line prints at the
# next drain, in enqueue order — same contract, just not inline. The ledger
# lane skips the same way: a beads-only diff moves nothing a throwaway-repo
# probe can observe, while every serial step still runs — the local-ok check
# reads the live ledger, which that diff does move. Composable: a
# ledger-scoped --quick run skips on the first check above.
# One enqueue path for every probe: bound the flight, then run the body in a
# background subshell with the ledger-guard shim armed, its line printing at
# the next drain in enqueue order.
enqueue_probe() {
  local name="$1"; shift
  wait_for_probe_slot
  local base
  base="$(slug "$name")"
  ( trap - EXIT; PROBE_CHILD=1; ledger_guard_arm "$name"; step "$name" "$@" >"$LOGS/$base.report" 2>&1 ) &
  probe_pids+=("$!")
  probe_bases+=("$base")
  probe_names+=("$name")
}

probe_step() {
  local when=""
  if [ "${1:-}" = "--when" ]; then
    when="${2:-}"
    shift 2
  fi
  if [ "$mode" = "--quick" ]; then
    echo "  skip  $1 (--quick lane)"
    return 0
  fi
  if [ "$scope" = "ledger" ]; then
    echo "  skip  $1 (ledger lane)"
    return 0
  fi
  local name="$1"; shift
  # Single-probe runs count every probe for the ran-of-M summary, then run
  # only the exact match through the same machinery — ignoring --when and
  # the quick/ledger lanes above, so the worker proves the probe the way the
  # gate runs it. Everything else skips silently.
  probe_total=$((probe_total + 1))
  probe_all_names+=("$name")
  if in_probe_mode; then
    if [ "$name" != "$probe_name" ]; then
      return 0
    fi
    probe_matched=$((probe_matched + 1))
    enqueue_probe "$name" "$@"
    return 0
  fi
  if [ -n "$when" ] && [ "$mode" != "--full" ] && [ -z "${lane_list:-}" ]; then
    case "$scope_reason" in
      *not\ a\ git\ checkout*|*git\ status\ failed*|*clean\ tree*|*explicit\ --full*)
        : # scope cannot be narrowed — run everything
        ;;
      *)
        local _ps_path _ps_glob _ps_matched=0 _ps_file="$LOGS/changed-paths.nul"
        if [ -f "$_ps_file" ]; then
          set -f
          while IFS= read -r -d '' _ps_path; do
            [ -n "$_ps_path" ] || continue
            case "$_ps_path" in
              template/scripts/verify.sh|scripts/verify.steps.sh|template/scripts/verify.steps.sh|template/scripts/lib/paths.sh)
                _ps_matched=1; break;;
            esac
            for _ps_glob in $when; do
              # shellcheck disable=SC2254: the glob must stay unquoted to match
              case "$_ps_path" in
                $_ps_glob) _ps_matched=1; break 2;;
              esac
            done
          done < "$_ps_file"
          set +f
          if [ "$_ps_matched" -eq 0 ]; then
            echo "  skip  $name (unaffected — none of its paths changed)"
            probes_skipped_unaffected=$((probes_skipped_unaffected + 1))
            return 0
          fi
        else
          : # no changed list — run
        fi
        ;;
    esac
  fi
  enqueue_probe "$name" "$@"
}

# A path the ledger lane owns: the live export, the capture locations a
# bead close or a handoff note moves, and the findings log sessions append
# to. Everything else widens the scope.
is_ledger_path() {
  case "$1" in
    .beads|.beads/*|harness/handoffs|harness/handoffs/*|harness/laurels.jsonl|harness/learning.jsonl) return 0;;
    *) return 1;;
  esac
}

# Which lane this run takes, from the changed paths. Prints scope|reason: the
# scope selects what runs below, the reason is the line the session reads.
pick_scope() {
  if [ "$mode" = "--full" ]; then
    printf 'full|explicit --full runs everything\n'
    return 0
  fi
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'full|not a git checkout, so there is nothing to scope from — running everything\n'
    return 0
  fi
  local st
  st="$(git status --porcelain 2>/dev/null)" || {
    printf 'full|git status failed, so the scope is undeterminable — running everything\n'
    return 0
  }
  if [ -z "$st" ]; then
    printf 'full|clean tree, so there is nothing to narrow from — running everything\n'
    return 0
  fi
  # The changed path list for --when probes, NUL-separated like the knowledge
  # lane's scratch file (newlines and quotes in names must not split or hide
  # a path). Both sides of a rename, quotes stripped — git's, not the name's.
  rm -f "$LOGS/changed-paths.nul"
  local _rp_line _rp_p _rp_old _rp_new _rp_side
  while IFS= read -r _rp_line; do
    [ -n "$_rp_line" ] || continue
    _rp_p="${_rp_line#???}"
    case "$_rp_p" in
      *" -> "*)
        _rp_old="${_rp_p%% -> *}"; _rp_new="${_rp_p##* -> }"
        for _rp_side in "$_rp_old" "$_rp_new"; do
          case "$_rp_side" in
            \"*\") _rp_side="${_rp_side#\"}"; _rp_side="${_rp_side%\"}";;
          esac
          printf '%s\0' "$_rp_side" >> "$LOGS/changed-paths.nul"
        done
        continue;;
    esac
    case "$_rp_p" in
      \"*\") _rp_p="${_rp_p#\"}"; _rp_p="${_rp_p%\"}";;
    esac
    printf '%s\0' "$_rp_p" >> "$LOGS/changed-paths.nul"
  done <<EOF
$st
EOF
  local line p old new side ledger_only=1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    p="${line#???}"
    case "$p" in
      *" -> "*)
        # Renames carry both sides, and either side outside the ledger
        # widens the scope: a move into the ledger still deletes a source
        # the export check cannot observe, and a move out still adds one.
        old="${p%% -> *}"; new="${p##* -> }"
        for side in "$old" "$new"; do
          case "$side" in
            \"*\") side="${side#\"}"; side="${side%\"}";; # quotes are git's, not the name's
          esac
          is_ledger_path "$side" || { ledger_only=0; break 2; }
        done
        continue;;
    esac
    case "$p" in
      \"*\") p="${p#\"}"; p="${p%\"}";; # quotes are git's, not the name's
    esac
    is_ledger_path "$p" || { ledger_only=0; break; }
  done <<EOF
$st
EOF
  if [ "$ledger_only" = 1 ]; then
    printf 'ledger|only ledger paths changed — serial steps plus the export check, probes skip\n'
  else
    printf 'full|changes outside the ledger paths — running everything\n'
  fi
}

# Split in two helpers — cost and duplicates — sharing one detection and one
# lane library, so the halves cannot drift apart.
# One loader for the lane library: every python heredoc below execs through
# here with the lib on PYTHONPATH, so no call site pastes its own import
# block. Any extra argv the inline code reads travels after the script.
kl_python() {
  PYTHONPATH="$HARNESS/scripts/lib" python3 - "$@"
}
knowledge_cost() {
  local out st
  if out="$(kl_python <<'PYEOF'
import knowledge_layer as kl

# Tune here: the static lanes one number, beside the logic that reads it. A
# knowledge diff growing the always-loaded layer past this many tokens fails
# — the layer is a budget, and a session that will not argue with it needs
# the gate to do it instead.
COST_DELTA_MAX = 2000

parts, now = kl.cost_now()
base = kl.cost_base(parts)
delta = now - base
print("  knowledge static: cost %d tokens (%+d since HEAD)" % (now, delta))
if delta > COST_DELTA_MAX:
    print("error: always-loaded cost grew %+d tokens in one diff"
          " (max %d)" % (delta, COST_DELTA_MAX))
    print("  move the text behind a skill instead, or tune COST_DELTA_MAX above")
    sys.exit(1)
PYEOF
)"; then
    st=0
  else
    st=$?
  fi
  printf '%s\n' "$out"
  return "$st"
}

knowledge_duplicates() {
  # $1 carries the changed knowledge-layer paths (stripped of any template/
  # prefix) as a NUL-separated file, written by the detection in
  # knowledge_static below — never flattened to lines, so a newline inside a
  # skill name cannot split one path into two phantom filters.
  local changed_file="$1" out st
  if out="$(kl_python "$changed_file" <<'PYEOF'
import knowledge_layer as kl
import os
import sys

texts, memo_note = kl.duplicate_texts()
if memo_note:
    print(memo_note, end="")

# Sentence granularity, not file granularity: a benign touch to a file that
# already carries a settled duplicate must not fail. Only a sentence
# duplicated now that was not duplicated at HEAD is introduced by this diff;
# the rest stays with the librarian. Memories have no HEAD version, so both
# sides read them live: a file sentence matching a memory still counts, and
# only a sentence already duplicated at HEAD stays silent.
base_entries, base_note = kl.duplicate_base_texts()
if base_note:
    print(base_note, end="")
base_entries.extend((name, text) for name, text in texts if name.startswith("memory:"))

changed_keys = set()
with open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
    for entry in handle.read().split("\0"):
        if entry:
            changed_keys.add(entry)

duplicates = kl.find_introduced_duplicates(texts, base_entries, changed_keys)
if duplicates:
    print("error: duplicate facts across the knowledge layer:")
    for sent, names in duplicates[:5]:
        print("  - \"%s...\" in %s" % (sent[:80], ", ".join(names)))
    print("  say it once, or let the librarian pass merge them")
    sys.exit(1)
PYEOF
)"; then
    st=0
  else
    st=$?
  fi
  printf '%s\n' "$out"
  return "$st"
}

knowledge_static() {
  local detect st changed_file header cost_out duplicate_out cost_st duplicate_st out
  # The changed set travels NUL-safe in a scratch file, not as
  # newline-joined lines: flattening it would split a newline path in two
  # and the verdict below would never match either half.
  changed_file="$(mktemp)" || {
    capture_report "knowledge static" "  knowledge static: cannot make a scratch file" 1
    return 1
  }
  if detect="$(kl_python "$changed_file" <<'PYEOF'
import knowledge_layer as kl
import sys

rows = kl.git_status_rows()
if rows is None:
    print("  knowledge static: git status failed — checks skip")
    sys.exit(2)
# No commits, no diff: a fresh tree is all untracked, which would read every
# installed file as changed and fail fresh installs on dormant facts the
# librarian owns. Static judges a diff, so without one it skips out loud.
if not kl.has_commits():
    print("  knowledge static: no commits yet — no diff to judge, checks skip")
    sys.exit(2)
paths = sorted({path for _, path in rows if kl.is_knowledge_static(path)})
if not paths:
    print("  knowledge static: no knowledge-layer change — checks skip")
    sys.exit(2)
def safe(path):
    for boundary in ("\t", "\n", "\x0b", "\x0c", "\r",
                     "\x1c", "\x1d", "\x1e"):
        path = path.replace(boundary, " ")
    return path
print("  knowledge static: " + ", ".join(sorted(safe(path) for path in paths)))
stripped = sorted({kl.strip_template_prefix(path) for _, path in rows if kl.is_knowledge_static(path)})
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write("\0".join(stripped) + "\0")
PYEOF
)"; then
    st=0
  else
    st=$?
  fi
  if [ "$st" -eq 2 ]; then
    # A skip, not a verdict: the lane never ran, and says so out loud.
    rm -f "$changed_file"
    capture_report "knowledge static" "$detect" 0
    return 0
  elif [ "$st" -ne 0 ]; then
    rm -f "$changed_file"
    capture_report "knowledge static" "$detect" "$st"
    return "$st"
  fi
  header="$(printf '%s\n' "$detect" | sed -n '1p')"
  if cost_out="$(knowledge_cost)"; then
    cost_st=0
  else
    cost_st=$?
  fi
  if duplicate_out="$(knowledge_duplicates "$changed_file")"; then
    duplicate_st=0
  else
    duplicate_st=$?
  fi
  rm -f "$changed_file"
  if [ "$cost_st" -ne 0 ] || [ "$duplicate_st" -ne 0 ]; then
    st=1
  else
    st=0
  fi
  if [ "$st" -eq 0 ]; then
    out="$header
$cost_out
  knowledge static: cost and duplicates clean"
  else
    out="$header
$cost_out
$duplicate_out"
  fi
  capture_report "knowledge static" "$out" "$st"
  # report above always exits 0 — the verdict travels in the failed flag,
  # which dies with a subshell — so hand the status back explicitly. The bare
  # call below ignores it; the behavioural lane inside probe_step needs it.
  return "$st"
}

# The knowledge layers behavioural half: the eval cases in harness/evals/,
# only when always-loaded text changes — the files in KNOWLEDGE_FILES in
# template/scripts/lib/knowledge_layer.py or a skill description, which is
# the part of a skill every session pays for (compared frontmatter to
# frontmatter, so body prose mentioning the word is not a layer change). Anything else, including a memory-only change, skips
# before the runner is even called. A probe step because the runner takes
# minutes: skipped in the --quick and ledger lanes like every other
# throwaway-repo check. A shell function like the static lane above, so the
# evals one-line-per-case output echoes instead of being swallowed.
knowledge_behavioural() {
  local out st eval_sh
  eval_sh="${HARNESS_ROOT:?harness root is missing}/scripts/eval.sh"
  if out="$(kl_python "$eval_sh" <<'PYEOF'
import knowledge_layer as kl
import re
import subprocess
import sys

eval_sh = sys.argv[1]

rows = kl.git_status_rows()
if rows is None:
    print("  knowledge behavioural: git status failed — evals skip")
    sys.exit(0)
if not kl.has_commits():
    print("  knowledge behavioural: no commits yet — evals skip")
    sys.exit(0)

triggered = []
for code, path in rows:
    if kl.strip_template_prefix(path) in kl.KNOWLEDGE_FILES:
        triggered.append(path)
for code, path in rows:
    cand = kl.strip_template_prefix(path)
    if not cand.startswith(".claude/skills/") or not cand.endswith("/SKILL.md"):
        continue
    if code == "??" or code.strip() == "A":
        triggered.append(path + " (new)")
        continue
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            now_text = handle.read()
    except OSError:
        triggered.append(path + " (deleted)")
        continue
    head_text = kl.read_base(path)
    if head_text is None:
        head_text = ""
    # Frontmatter to frontmatter, never a grep for the word: body prose
    # mentioning description: is not an always-loaded change.
    if kl.skill_description(now_text) != kl.skill_description(head_text):
        triggered.append(path)
seen = []
for item in triggered:
    if item not in seen:
        seen.append(item)
if not seen:
    print("  knowledge behavioural: no always-loaded change — evals skip")
    sys.exit(0)
print("  knowledge behavioural: " + ", ".join(seen))
run = subprocess.run(["bash", eval_sh], capture_output=True, text=True,
                     errors="replace")
sys.stdout.write(run.stdout)
sys.stderr.write(run.stderr)
if run.returncode != 0:
    case_re = re.compile("^eval: regression \u2014 (.*?) "
                         "(passed on the last committed harness|"
                         "has no passing baseline)")
    names = []
    for line in (run.stdout or "").split("\n"):
        found = case_re.match(line)
        if found:
            names.append(found.group(1))
    if names:
        print("error: eval regression in %s"
              " — the eval lines above say which" % ", ".join(sorted(set(names))))
    else:
        print("error: a passing eval case now fails — the eval lines above say which")
    sys.exit(1)
PYEOF
)"; then
    st=0
  else
    st=$?
  fi
  capture_report "knowledge behavioural" "$out" "$st"
  # report above always exits 0 — without this the probe step wrapping this
  # function reads success whatever eval said, and a breaking change sails
  # through.
  return "$st"
}

# One lane for probes: scope detection already ran above; this runs only the
# named lane(s) with the same lines and exit status as the full gate, without
# probes, serial steps, or the golden fixture (the project steps file that
# builds it is never sourced on this path). Names are comma-separated.
verify_lanes_only() {
  local lanes="$1" item st=0
  for item in $(printf '%s' "$lanes" | tr ',' ' '); do
    case "$item" in
      knowledge-static) knowledge_static || st=1;;
      knowledge-behavioural) knowledge_behavioural || st=1;;
      *) echo "verify: unknown lane '$item' (want knowledge-static,knowledge-behavioural)" >&2; return 2;;
    esac
  done
  return "$st"
}

# Ledger guard: a probe that files or remembers without cd-ing into its
# throwaway repo writes into the real ledger. Every probe subshell arms a bd
# shim first on PATH: bd from the live checkout hits the log and exits 3,
# while bd anywhere else execs the real binary. After the final drain a
# non-empty hits file fails "probes left the live ledger untouched". No
# snapshots — a concurrent session's routine ledger write can no longer fail
# this gate.
ledger_guard_active=0
ledger_guard_root=""
ledger_guard_realbd=""
ledger_guard_shimdir=""
ledger_guard_install() {
  # A gate nested inside an armed probe keeps the outer shim: reinstalling
  # would resolve "real bd" to that shim and, sharing a log dir, could remove
  # it from under every probe still running.
  if [ -n "${LEDGER_GUARD_HITS:-}" ]; then
    return 0
  fi
  if ! command -v bd >/dev/null 2>&1; then
    echo "  skip  probes left the live ledger untouched (no bd here)"
    return 0
  fi
  # Resolved once, absolute, before the shim dir exists anywhere on PATH —
  # the shim execs this, never a lookup that could find itself.
  ledger_guard_realbd="$(command -v bd)" || ledger_guard_realbd=""
  case "$ledger_guard_realbd" in
    /*) : ;;
    *) echo "  skip  probes left the live ledger untouched (bd is not a plain binary — nothing to interpose)"; return 0;;
  esac
  # Physical, like the prefix fallback above: through a symlink the logical
  # name could be anything, and the shim compares physical paths.
  ledger_guard_root="$(cd "$ROOT" && pwd -P)" || ledger_guard_root="$ROOT"
  ledger_guard_shimdir="$LOGS/ledger-guard-shim"
  mkdir -p "$ledger_guard_shimdir" || { echo "verify: cannot install the ledger-guard shim" >&2; exit 1; }
  cat > "$ledger_guard_shimdir/bd" <<'SHIMEOF'
#!/bin/bash
# First on PATH inside every probe subshell: bd from the live checkout is a
# probe that never cd-ed into its throwaway repo.
# An undeterminable cwd counts as the live checkout: fail closed, not open.
_here="$(pwd -P 2>/dev/null)" || _here="$LEDGER_GUARD_ROOT"
[ -n "$_here" ] || _here="$LEDGER_GUARD_ROOT"
# Throwaway repos live in mktemp dirs, but the golden cache lives under the
# checkout's .tmp: bd there is fixture work, not a stray write.
case "$_here" in
  "$LEDGER_GUARD_ROOT"/.tmp/*) exec "$LEDGER_GUARD_REALBD" "$@" ;;
esac
case "$_here" in
  "$LEDGER_GUARD_ROOT"|"$LEDGER_GUARD_ROOT"/*)
    printf '%s: bd %s\n' "$LEDGER_GUARD_PROBE" "$*" >> "$LEDGER_GUARD_HITS"
    echo "ledger guard: probe ran bd in the live checkout — cd into the throwaway repo first" >&2
    exit 3 ;;
esac
exec "$LEDGER_GUARD_REALBD" "$@"
SHIMEOF
  chmod +x "$ledger_guard_shimdir/bd" || { echo "verify: cannot install the ledger-guard shim" >&2; exit 1; }
  rm -f "$LOGS/ledger-guard.hits"
  ledger_guard_active=1
}

# Armed inside each probe's background subshell: the shim first on PATH with
# this probe's identity, so a hit names the probe that strayed.
ledger_guard_arm() {
  [ "$ledger_guard_active" -eq 1 ] || return 0
  LEDGER_GUARD_ROOT="$ledger_guard_root"
  LEDGER_GUARD_REALBD="$ledger_guard_realbd"
  LEDGER_GUARD_PROBE="$1"
  LEDGER_GUARD_HITS="$LOGS/ledger-guard.hits"
  export LEDGER_GUARD_ROOT LEDGER_GUARD_REALBD LEDGER_GUARD_PROBE LEDGER_GUARD_HITS
  PATH="$ledger_guard_shimdir:$PATH"
  export PATH
}

# After the final drain: a non-empty hits file fails the step naming the
# strays (at most 10) with the remedy; else ok. The shim dir goes either way.
ledger_guard_check() {
  if [ "$ledger_guard_active" -ne 1 ]; then
    return 0
  fi
  rm -rf "$ledger_guard_shimdir"
  local hits="$LOGS/ledger-guard.hits" out n
  if [ ! -s "$hits" ]; then
    echo "  ok    probes left the live ledger untouched"
    return 0
  fi
  n="$(wc -l < "$hits" | tr -d ' ')" || n=""
  case "$n" in ''|*[!0-9]*) n=10;; esac
  out="$(head -10 "$hits" | sed -e 's/^/        /')"
  if [ "$n" -gt 10 ]; then
    out="$out
        ...and $((n - 10)) more"
  fi
  out="  a probe ran bd in the live checkout:
$out
        remedy: cd into the throwaway repo first (golden_probe and fresh_probe set \$probe for exactly this)"
  capture_report "probes left the live ledger untouched" "$out" 1
  return 1
}

# An unknown --probe name exits 2 naming candidates: close matches first,
# else a sample of the probe list so the name is still guessable.
probe_unknown_exit() {
  local candidates=""
  # The ${arr[@]+...} form expands to nothing when the array is empty: under
  # set -u a bare empty array expansion fails, so the pipeline needs the guard.
  candidates="$(printf '%s\n' ${probe_all_names[@]+"${probe_all_names[@]}"} | python3 -c 'import difflib,sys; want=sys.argv[1]; names=[l.rstrip("\n") for l in sys.stdin if l.rstrip("\n")]; print("\n".join(difflib.get_close_matches(want, names, n=5, cutoff=0.5)))' "$probe_name" 2>/dev/null)"
  echo "verify: unknown probe '$probe_name'" >&2
  if [ -n "$candidates" ]; then
    echo "verify: did you mean:" >&2
    printf '%s\n' "$candidates" | sed -e 's/^/        /' >&2
  else
    echo "verify: no close match among $probe_total probe(s) — for example:" >&2
    printf '%s\n' ${probe_all_names[@]+"${probe_all_names[@]}"} | sort | head -5 | sed -e 's/^/        /' >&2
  fi
  rm -rf "$LOGS"
  exit 2
}

echo "verify: $ROOT"
scope_line="$(pick_scope)"
scope="${scope_line%%|*}"
scope_reason="${scope_line#*|}"
if in_probe_mode; then
  # A single-probe run narrows nothing: the fixture builds and the match runs
  # whatever changed, ignoring the scope and the mode.
  scope="full"
  scope_reason="--probe runs the named probe whatever changed"
  mode="--default"
fi
echo "verify: scope=$scope ($scope_reason)"
# --lane: probe-cheap entry to a single gate lane. Scope detection already ran
# above; this runs only the named lane(s) and exits with the lane status, so
# probes asserting lane behavior call the real code instead of pasting the
# lane's python or nesting a full gate.
if [ -n "$lane_list" ]; then
  verify_lanes_only "$lane_list"
  lane_st=$?
  [ "$lane_st" -eq 0 ] && echo "verify: passed" || echo "verify: FAILED"
  rm -rf "$LOGS"
  exit "$lane_st"
fi
# This runs before every other bd call in the gate — the context check's brief
# included. `bd config`, `bd info`, `bd stats` and friends auto-import a stale
# .beads/issues.jsonl when the ledger looks stale to them, resurrecting deleted
# beads (har-67c); anything that ran first would heal the drift this check
# exists to catch. The only bd call before this point is the prefix lookup up
# top, which reads `bd list` — a command that never imports.
#
# Ledger lane, one contract: when the scope above came back ledger, the probe
# steps below skip loudly (same contract as the --quick lane) while every
# serial step still runs — a beads-only diff moves the live ledger the
# local-ok check reads, but nothing any probe observes.
ledger_guard_install
if ! in_probe_mode; then
  if export_out="$("$(harness_script ledger-export-check.sh)" 2>&1)"; then
    echo "$export_out"
  else
    # The check's own output already carries its FAIL line naming the step; only
    # record the name for the summary below.
    note_failed "ledger export"
    echo "$export_out"
  fi
fi

# Ledger hygiene every install enforces, not just the starter: parked in a
# project's steps file these run only there, while leaf installs carry a
# skeleton that never mentions them. Read-only `bd list` only — the same
# command the prefix lookup above trusts never to import — never export,
# config or info, which auto-import a stale export and would heal the drift
# the export check exists to catch. No live ledger skips out loud. Serial
# steps, so the ledger lane still judges the live ledger a beads-only diff
# moved while every probe skips.
# A bead queued for a local model carries its own spec — --design and
# --acceptance filled in, plus a `local-ok` label — because a small model
# executes well only when the bead says what done looks like. Closed beads
# are history, not queue, so only open work is judged.
step "local-ok beads carry design and acceptance" bash -c '
  python3 - <<PYEOF || exit 1
import json
import os
import subprocess
import sys
try:
    out = subprocess.run(
        ["bd", "list", "--json", "--all", "--limit", "0"],
        capture_output=True, text=True)
except FileNotFoundError:
    print("no bd here, skipping")
    sys.exit(0)
if out.returncode != 0:
    if not os.path.isdir(".beads/embeddeddolt"):
        print("no live ledger, skipping")
        sys.exit(0)
    err = (out.stderr.strip().splitlines() or ["unknown"])[0]
    print("error: cannot list the beads: " + err)
    sys.exit(1)
try:
    issues = json.loads(out.stdout or "[]")
except ValueError:
    print("error: cannot read the bead list")
    sys.exit(1)
bad = []
for issue in issues:
    if "local-ok" not in (issue.get("labels") or []):
        continue
    if (issue.get("status") or "open") == "closed":
        continue
    missing = []
    if not (issue.get("design") or "").strip():
        missing.append("design")
    acceptance = issue.get("acceptance_criteria", issue.get("acceptance"))
    if not (acceptance or "").strip():
        missing.append("acceptance")
    if missing:
        bad.append("%s lacks %s" % (issue.get("id", "?"), " and ".join(missing)))
if bad:
    print("error: local-ok beads without their own spec, no local model can execute these:")
    for line in bad:
        print("  - " + line)
    print("fill --design and --acceptance, or drop the local-ok label")
    sys.exit(1)
PYEOF'

# Closed and backlog are mutually exclusive: a closed bead is finished work,
# not shelved work, so it never renders in the backlog strip and never counts
# as ready. bd itself keeps the label on close, and no hook may strip it
# (hooks are not harness-owned), so the gate fails the bead instead. Own
# labels only: an open child of a shelved parent stays shelved by inheritance
# without carrying the label itself.
step "no closed bead carries backlog" bash -c '
  python3 - <<PYEOF || exit 1
import json
import os
import subprocess
import sys
try:
    out = subprocess.run(
        ["bd", "list", "--json", "--all", "--limit", "0"],
        capture_output=True, text=True)
except FileNotFoundError:
    print("no bd here, skipping")
    sys.exit(0)
if out.returncode != 0:
    if not os.path.isdir(".beads/embeddeddolt"):
        print("no live ledger, skipping")
        sys.exit(0)
    err = (out.stderr.strip().splitlines() or ["unknown"])[0]
    print("error: cannot list the beads: " + err)
    sys.exit(1)
try:
    issues = json.loads(out.stdout or "[]")
except ValueError:
    print("error: cannot read the bead list")
    sys.exit(1)
bad = sorted(
    (issue.get("id", "?") for issue in issues
     if (issue.get("status") or "open") == "closed"
     and "backlog" in (issue.get("labels") or [])))
if bad:
    print("error: closed beads still carry the backlog label — closed and backlog are mutually exclusive:")
    for line in bad:
        print("  - " + line)
    print("clear it on close (bd label remove <id> backlog), or drop the label by hand")
    sys.exit(1)
PYEOF'

step "codex support" python3 "$(harness_script codex-support.py)" check
# Self-tests: hermetic by construction — each builds its own throwaway root —
# so the dispatch environment is unset for them. Inheriting HARNESS_PROJECT
# would point the copied scripts at this checkout instead of their fixture.
# Resolved harness-first, never project-first: a project file named
# test-agent.py must not stand in for the gate's own probe. Real steps stay
# project-first.
step "codex regression" env -u HARNESS_PROJECT -u HARNESS_ROOT python3 "$(harness_shared_script test-codex-support.py)"
# Flies with the probes in a full run; skipped in the --quick and ledger lanes
# with them, per the lane contract above.
probe_step "agent runner" env -u HARNESS_PROJECT -u HARNESS_ROOT python3 "$(harness_shared_script test-agent.py)"
step "model probes" env -u HARNESS_PROJECT -u HARNESS_ROOT python3 "$(harness_shared_script test-models-probe.py)"
step "opencode permissions" env -u HARNESS_PROJECT -u HARNESS_ROOT python3 "$(harness_shared_script test-opencode-permissions.py)"
step "opencode pin probes" env -u HARNESS_PROJECT -u HARNESS_ROOT python3 "$(harness_shared_script test-opencode-pin.py)"

# The knowledge layer gets the same treatment as the code. A doc that quietly
# stopped being true is worse than a missing one, and it can't be caught by
# reviewing a diff — the stale file isn't in the diff, the thing it describes is.
# Runs early because it takes a second and needs no build.
if ! in_probe_mode; then
  if context_out="$(python3 "$(harness_script context.py)" check 2>&1)"; then
    echo "$context_out"
  else
    context_st=$?
    # Routed through capture_report so the failure emits a FAIL line naming the
    # step; the STALE detail stays in the echoed output above. context.py itself
    # is harness-owned elsewhere, so the bless remedy lives here, beside the failure.
    capture_report "context docs" "$context_out" "$context_st"
    echo "        remedy: scripts/harness context bless re-records hashes after updating the doc"
  fi
fi

# Bare, like the context-docs check above: step would swallow the verdict
# lines the probes below grep for, and every probe is already drained by the
# model-probes step further up.
if ! in_probe_mode; then
  knowledge_static
fi

probe_step "knowledge behavioural" knowledge_behavioural
# generated from it — and the generated half drifts silently, because nothing
# about editing the source makes opencode complain. Checked rather than
# regenerated: a gate that quietly fixed this would pass every time and never
# say the two had parted company.
if ! in_probe_mode; then
  if agents_out="$(python3 "$(harness_script opencode-agents.py)" check 2>&1)"; then
    echo "$agents_out"
  else
    agents_st=$?
    capture_report "opencode agents" "$agents_out" "$agents_st"
  fi
fi

# opencode runs on one model at one variant (scripts/harness models), and every
# file that could pick another — the roster, the generated agents,
# opencode.json, the scripts, the docs — is held to it here. The prose rule
# came first and a session with no terminal walked straight past it.
if ! in_probe_mode; then
  if pin_out="$(python3 "$(harness_script opencode-pin.py)" check 2>&1)"; then
    echo "$pin_out"
  else
    pin_st=$?
    capture_report "opencode pin" "$pin_out" "$pin_st"
  fi
fi

# The opencode contract the session reads: opencode.json lists
# .harness-contract.md, a link `scripts/harness link` keeps, and the session
# plugin that injects the brief. A clone or worktree can lose either — the
# link is gitignored, the plugin is committed but a partial copy can drop it —
# so the gate fails loudly naming the fix rather than starting sessions with
# no contract. Projects without opencode skip: no opencode.json, or no
# contract in its instructions, means nothing here applies.
if ! in_probe_mode; then
  if contract_out="$(python3 - "$ROOT" "${HARNESS_ROOT:-}" <<'PYEOF' 2>&1
import json
import os
import sys

root = sys.argv[1]
# The shared contract link_contract keeps, so a resolved link anywhere else —
# a moved root, a hand link — is stale, not ok. Unknown when HARNESS_ROOT is
# unset (undispatched runs); then only the stale check skips, never the rest.
expected = os.path.join(sys.argv[2], "AGENTS.md") if len(sys.argv) > 2 and sys.argv[2] else None
cfg = os.path.join(root, "opencode.json")
if not os.path.exists(cfg):
    print("  opencode contract link: no opencode.json — skipping")
    sys.exit(0)
try:
    with open(cfg) as handle:
        tree = json.load(handle)
except (OSError, ValueError) as exc:
    print("error: %s is unparseable (%s) — fix the JSON" % (cfg, exc))
    sys.exit(1)
instr = tree.get("instructions", []) if isinstance(tree, dict) else []
if not isinstance(instr, list) or ".harness-contract.md" not in instr:
    print("  opencode contract link: contract not listed — skipping")
    sys.exit(0)
link = os.path.join(root, ".harness-contract.md")
if not os.path.islink(link) and not os.path.exists(link):
    print("error: .harness-contract.md missing — run scripts/harness link")
    sys.exit(1)
if os.path.islink(link) and not os.path.exists(link):
    print("error: .harness-contract.md dangles — run scripts/harness link")
    sys.exit(1)
if os.path.islink(link) and os.path.exists(link):
    if expected is not None and os.readlink(link) != expected:
        print("error: .harness-contract.md is stale — run scripts/harness link")
        sys.exit(1)
elif os.path.exists(link):
    print("error: .harness-contract.md is stale — run scripts/harness link")
    sys.exit(1)
plugin = os.path.join(root, ".opencode/plugins/harness-session.js")
if os.path.islink(plugin) and not os.path.exists(plugin):
    print("error: .opencode/plugins/harness-session.js dangles — re-add it with harness add %s from the harness-starter checkout" % root)
    sys.exit(1)
if not os.path.isfile(plugin):
    print("error: .opencode/plugins/harness-session.js missing or not a file — re-add it with harness add %s from the harness-starter checkout" % root)
    sys.exit(1)
if expected is None:
    print("  ok    opencode contract link (stale-link check skipped: run undispatched, shared root unknown)")
else:
    print("  ok    opencode contract link")
PYEOF
)"; then
    echo "$contract_out"
  else
    contract_st=$?
    capture_report "opencode contract link" "$contract_out" "$contract_st"
  fi
fi

# ── PROJECT STEPS ─────────────────────────────────────────────────────────
# Your project's build, test, and smoke steps live in scripts/verify.steps.sh,
# sourced just below. That file is the project's own — installed once by
# `harness add` and never touched again — so shared scaffolding fixes here
# still arrive with the starter.
# Project-only, never the harness copy: the template's placeholder standing in
# for a missing file would hide the loud failure below.
if [ -f "$ROOT/scripts/verify.steps.sh" ]; then
  . "$ROOT/scripts/verify.steps.sh"
else
  # A gate with no project steps would pass vacuously — the green suite that
  # ran nothing — so a missing steps file fails loudly instead. `harness add`
  # installs it; a project from before the split recovers its steps from its
  # old verify.sh by hand.
  steps_msg="  ! no scripts/verify.steps.sh — the gate has no project steps to run."
  capture_report "project steps" "$steps_msg" 1
fi
# ── END PROJECT STEPS ─────────────────────────────────────────────────────

# Whatever is still flying lands here, in enqueue order; only then is the
# fixture (built by the project steps above, if they built one) safe to reap.
drain_probes
if in_probe_mode; then
  # Nothing matched: no probe ran, so exit before the guard and the footer —
  # there is nothing they could judge.
  if [ "$probe_matched" -eq 0 ]; then
    probe_unknown_exit
  fi
  echo "verify: --probe ran $probe_matched of $probe_total probe(s)"
else
  if [ "$probes_run" -gt 0 ]; then
    echo "verify: $probes_run probe(s) in parallel (at most $PROBE_MAX at once)"
  fi
  echo "verify: $probes_run probe(s) ran, $probes_skipped_unaffected skipped as unaffected"
fi
# The guard reports after the final drain above: any probe that ran bd from
# the live checkout fails here, naming the strays.
ledger_guard_check

# The golden probe fixture pays one install per run and every probe copies it
# instead of installing — but probe bodies reset the EXIT trap, so the fixture
# cannot reap itself. Reaped here, once, whatever the outcome — and only when
# this run built it (GOLDEN_MINE is never exported, so a nested --quick gate
# inheriting GOLDEN can never reap the outer run's fixture mid-flight).
if [ "${GOLDEN_MINE:-}" = 1 ] && [ -n "${GOLDEN:-}" ] && [ -d "$GOLDEN" ]; then
  rm -rf "$GOLDEN"
fi

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
print_slowest_steps() {
  local wall_secs="$1" slowest_summary
  echo "$wall_secs" > "$LOGS/elapsed"
  echo "verify: ${wall_secs}s wall"
  if [ -f "$LOGS/timings" ]; then
    slowest_summary="$(sort -rn "$LOGS/timings" | head -5 | awk '{s=$1; $1=""; sub(/^ +/, ""); printf "%s (%ss); ", $0, s}' | sed 's/; $//')"
    if [ -n "$slowest_summary" ]; then
      echo "verify: slowest steps: $slowest_summary"
    fi
  fi
}

print_slowest_steps "$((SECONDS - started))"

# Names, not just a count: a red gate should say which steps to re-run.
if [ "$failed" -ne 0 ] && [ "${#failed_names[@]}" -gt 0 ]; then
  _failed_line=""
  # The ${arr[@]+...} form expands to nothing when the array is empty: under
  # set -u a bare empty array expansion fails, so the loop needs the guard.
  for _failed_e in ${failed_names[@]+"${failed_names[@]}"}; do
    if [ -z "$_failed_line" ]; then
      _failed_line="$_failed_e"
    else
      _failed_line="$_failed_line, $_failed_e"
    fi
  done
  echo "verify: failed steps: $_failed_line"
fi

[ "$failed" -eq 0 ] && echo "verify: passed" || echo "verify: FAILED"
# The session's live journal: one machine-written line per run, never model
# prose. A failure and the pass that followed both land, so the journal shows
# the loop, not just its end. Loud but never fatal — the verdict above stands
# whatever the journal does.
if [ "$failed" -eq 0 ]; then
  if in_probe_mode; then
    journal_event "verify" "--probe $probe_name passed"
  else
    journal_event "verify" "passed"
  fi
else
  journal_event "verify" "${probe_name:+--probe $probe_name }FAILED ${_failed_line:-$failed}"
fi
# A --probe run owns a scratch log dir: gone on pass, kept and printed on
# failure so the report names where to read.
if in_probe_mode; then
  if [ "$failed" -eq 0 ]; then
    rm -rf "$LOGS"
  else
    echo "verify: --probe logs kept in $LOGS"
  fi
fi
exit "$failed"
