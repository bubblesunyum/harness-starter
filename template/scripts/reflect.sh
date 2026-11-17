#!/bin/bash
# Builds the reflect packet: everything the reflector needs about one close,
# in one file, so it proposes from evidence instead of from the caller's
# summary.
#
#   scripts/reflect.sh [--packet-only] [--note-file harness/handoffs/<ts>.md]
#     [--nominate "one line"]... [--candidates-file <path>]
#
# Prints a PACKET line with the packet path, then runs the reflector: through
# scripts/harness agent on the pinned model everywhere except inside opencode,
# where the calling session spawns the reflector natively against the printed
# packet (a shell script cannot spawn a native subagent). --packet-only builds
# the packet and stops. --candidates-file reuses a reviewed candidates file
# instead of running the reflector, so --keep-lesson keeps the reviewed list
# rather than a fresh nondeterministic rerun. Zero candidates is normal.
#
# Output contract, which wrap-up.sh reads back: a `PACKET <path>` line, a
# `CANDIDATES <path>` line (raw JSON lines, one per candidate, empty when
# none), and one human `N. [tier] target - text` line per candidate. A failed
# reflector prints `REFLECTOR_FAILED <reason>` and leaves CANDIDATES empty.
# A reused candidates file is validated like a live reply (at most 3 lines,
# same tier/target/text/evidence schema) and reads as a failed reflector when
# it does not parse. Only a packet that cannot be built exits non-zero — a
# failed reflector never blocks a close.
set -euo pipefail

ROOT="${HARNESS_PROJECT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# Where this script was loaded from: the shared checkout, whose scripts/ holds
# the copy a project file shadows. Same as ROOT when run as an installed copy.
HARNESS="${HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

. "$HARNESS/scripts/lib/paths.sh"
. "$HARNESS/scripts/lib/journal.sh"

PACKET_ONLY=0 NOTE_FILE="" CANDIDATES_FILE=""
NOMINATIONS=()

usage() {
  awk '/^#/{sub(/^# ?/, ""); print; next} {exit}' "$0"
  exit "${1:-0}"
}

need() { # need COUNT REMAINING FLAG -- fail when fewer than COUNT args remain
  if [ "$1" -gt "$2" ]; then echo "reflect: $3 needs a value" >&2; exit 1; fi
}

# Validate candidate JSON lines from a file into OUT, printing one numbered
# human line per candidate on stdout. MODE strict fails past 3 lines (a
# reviewed list must match what the session saw); fresh truncates (a live run
# may over-propose). Zero candidates stays success. Non-zero with a stderr
# reason otherwise; OUT is only written once the whole file validates.
emit_candidates() { # emit_candidates OUT MODE SRC
  python3 - "$1" "$2" "$3" <<'PYEOF'
import json, sys
out_path, mode, src = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(src) as handle:
        raw = handle.read().splitlines()
except OSError as exc:
    sys.stderr.write("cannot read %s: %s\n" % (src, exc))
    sys.exit(1)
kept = []
for line in raw:
    line = line.strip()
    if not line:
        continue
    try:
        cand = json.loads(line)
    except ValueError:
        sys.stderr.write("candidates file holds invalid JSON: %s\n" % line[:80])
        sys.exit(1)
    if not isinstance(cand, dict):
        sys.stderr.write("candidates file holds a non-object line\n")
        sys.exit(1)
    if cand.get("tier") not in ("memory", "reviewer-trap", "skill", "claude-md"):
        sys.stderr.write("candidates file holds a bad tier: %s\n" % line[:80])
        sys.exit(1)
    if not all(isinstance(cand.get(k), str) and cand[k].strip() for k in ("target", "text", "evidence")):
        sys.stderr.write("candidates file holds a candidate missing target/text/evidence\n")
        sys.exit(1)
    kept.append({k: " ".join(str(cand[k]).split()) for k in ("tier", "target", "text", "evidence")})
if mode == "strict" and len(kept) > 3:
    sys.stderr.write("candidates file holds %d candidates, at most 3\n" % len(kept))
    sys.exit(1)
kept = kept[:3]
with open(out_path, "w") as handle:
    for cand in kept:
        handle.write(json.dumps(cand, sort_keys=True) + "\n")
for pos, cand in enumerate(kept, 1):
    print("%d. [%s] %s - %s" % (pos, cand["tier"], cand["target"], cand["text"]))
PYEOF
}

# Reuse a reviewed candidates file: validate it into $candidates and print
# the output contract, never running the reflector. Failure reads as a failed
# reflector and never blocks the close.
reuse_candidates() {
  local _cerr _reason _cout
  _cerr="$(mktemp)" || { echo "REFLECTOR_FAILED cannot stage the candidates error"; echo "CANDIDATES $candidates"; return 0; }
  if _cout="$(emit_candidates "$candidates" strict "$CANDIDATES_FILE" 2>"$_cerr")"; then
    echo "CANDIDATES $candidates"
    if [ -n "$_cout" ]; then
      printf '%s\n' "$_cout"
    else
      echo "(reflector proposed nothing — zero candidates is normal)"
    fi
  else
    _reason="$(tail -1 "$_cerr" 2>/dev/null | sed 's/^ *//')"
    [ -n "$_reason" ] || _reason="cannot reuse $CANDIDATES_FILE"
    echo "REFLECTOR_FAILED $_reason"
    echo "CANDIDATES $candidates"
  fi
  rm -f "$_cerr"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --packet-only) PACKET_ONLY=1; shift;;
    --note-file) need 2 "$#" "--note-file"; NOTE_FILE="$2"; shift 2;;
    --nominate) need 2 "$#" "--nominate"; NOMINATIONS+=("$2"); shift 2;;
    --candidates-file) need 2 "$#" "--candidates-file"; CANDIDATES_FILE="$2"; shift 2;;
    -h|--help) usage 0;;
    *) echo "reflect: unknown arg $1" >&2; usage 1;;
  esac
done

if [ -n "$NOTE_FILE" ]; then
  [ -f "$NOTE_FILE" ] || { echo "reflect: no such note file $NOTE_FILE" >&2; exit 1; }
fi

# The ledger's bead prefix, asked of the ledger itself at runtime — baked into
# this file once per install, which made every copy differ and un-updatable.
# Falls back to the directory name, derived the same way `harness add` does.
_harness_prefix() {
  local p=""
  if command -v bd >/dev/null 2>&1; then
    # Never `bd config get` or `bd info` here: both auto-import a stale
    # .beads/issues.jsonl when the ledger looks stale to them, resurrecting
    # deleted beads. `bd list` never imports, so the prefix comes from the
    # first bead id instead; an empty ledger has no ids and falls through to
    # the directory name below.
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
packet=/tmp/$(_harness_prefix)-reflect-packet-$$.md
candidates=/tmp/$(_harness_prefix)-reflect-candidates-$$.md
# Namespaced by PID, not just by project prefix: two sessions in one checkout
# otherwise overwrite each other's packet mid-reflect.
: > "$candidates" || { echo "reflect: cannot write $candidates" >&2; exit 1; }

# What a review is allowed to see bounds the diff here too: a reflect packet
# that carried files no reviewer ever reads would propose lessons about code
# nobody looks at. Project-only, like verify.steps.sh.
if [ -f "$ROOT/scripts/review.scope.sh" ]; then
  . "$ROOT/scripts/review.scope.sh"
else
  SCOPE=('*.py' '*.sh' '*.md' '*.json')
fi

diff_cmd() {
  git diff HEAD "$@" -- "${SCOPE[@]}"
}

# A file that isn't tracked yet is still part of the change — read out with
# `--no-index` rather than staged with `add -N`: this script is read-only
# about the repository, and an intent-to-add entry left behind would be picked
# up in full by the next `git commit -a`.
untracked_diff() {
  git ls-files --others --exclude-standard -- "${SCOPE[@]}" | while IFS= read -r file; do
    [ -n "$file" ] && git diff --no-index --no-color -- /dev/null "$file" || true
  done
}

if [ -n "$(git status --porcelain)" ]; then
  label="uncommitted working tree"
else
  label="clean tree (nothing uncommitted)"
fi

_sid="$(journal_session_id 2>/dev/null)" || _sid=""
_live="(no session id — journaling skipped this session)"
if [ -n "$_sid" ]; then
  _livefile="$(journal_live_file "$ROOT" "$_sid" 2>/dev/null)" || _livefile=""
  if [ -n "$_livefile" ] && [ -f "$_livefile" ]; then
    _live="$(cat "$_livefile")"
    [ -n "$_live" ] || _live="(live journal exists but is empty)"
  else
    _live="(no live journal for this session)"
  fi
fi

_pending="${HARNESS_REFLECT_PENDING:-}"
[ -n "$_pending" ] || _pending="(none — this close settles nothing pending)"

_beads="(ledger unreadable)"
if command -v bd >/dev/null 2>&1; then
  _beads="$(bd list --json --all 2>/dev/null | python3 -c '
import json, sys
try:
    issues = json.load(sys.stdin)
except Exception as exc:
    print("(ledger unreadable: %s)" % exc)
    sys.exit(0)
live = [i for i in issues if (i.get("status") or "open") != "closed"]
prog = [i for i in live if i.get("status") == "in_progress"]
print("%d open bead(s), %d in progress" % (len(live), len(prog)))
for i in prog[:10]:
    print("- %s %s" % (i.get("id", "?"), (i.get("title") or "")[:100]))
' 2>/dev/null)" || _beads="(ledger unreadable)"
fi

_findings="(no harness/learning.jsonl)"
if [ -f "$ROOT/harness/learning.jsonl" ]; then
  # `|| true`: a log with no findings yet is normal, and an empty grep match
  # must not fail the packet under `set -e` — nor must the `#` schema comment
  # read as a finding.
  _findings="$(grep '"kind"[[:space:]]*:[[:space:]]*"finding"' "$ROOT/harness/learning.jsonl" 2>/dev/null | grep -v '^[[:space:]]*#' | tail -30 || true)"
  [ -n "$_findings" ] || _findings="(no review findings logged)"
fi

_note="(no handoff note draft)"
if [ -n "$NOTE_FILE" ]; then
  _note="$(cat "$NOTE_FILE")"
fi

_noms="(none)"
if [ "${#NOMINATIONS[@]}" -gt 0 ]; then
  _noms=""
  _n=0
  for _nom in ${NOMINATIONS[@]+"${NOMINATIONS[@]}"}; do
    _n=$((_n + 1))
    _noms="${_noms}${_n}. ${_nom}
"
  done
fi

_digest="(digest unavailable)"
if _digest_path="$(python3 "$(harness_script context.py)" digest 2>/dev/null)"; then
  if [ -n "$_digest_path" ] && [ -f "$_digest_path" ]; then
    _digest="$_digest_path"
  fi
fi

{
  echo "# Reflect packet — $label"
  echo
  echo "## Session diff (working tree vs HEAD, in scope)"
  echo '```diff'
  diff_cmd
  untracked_diff
  echo '```'
  echo
  echo "## Live journal"
  echo
  printf '%s\n' "$_live"
  echo
  echo "## This close settles (wrap-up actions still pending)"
  echo
  printf '%s\n' "$_pending"
  echo
  echo "## Beads"
  echo
  printf '%s\n' "$_beads"
  echo
  echo "## Recent review findings"
  echo
  printf '%s\n' "$_findings"
  echo
  echo "## Handoff note draft"
  echo
  printf '%s\n' "$_note"
  echo
  echo "## Session nominations"
  echo
  printf '%s\n' "$_noms"
  echo
  echo "## Knowledge digest"
  echo
  echo "$_digest"
  echo
  echo "Read the digest before proposing — prefer editing an existing entry"
  echo "over adding a duplicate."
} > "$packet"

lines=$(wc -l < "$packet" | tr -d ' ')
tokens=$(($(wc -c < "$packet" | tr -d ' ') / 3))
if [ "$lines" -gt 3000 ]; then
  echo "warning: packet is large; the reflector may skim it (scripts/reflect.sh with a narrower tree)" >&2
fi

echo "$packet ($label, $lines lines, ~$tokens tokens)"
echo "PACKET $packet"

# A reviewed list, reused verbatim: no fresh run, so model nondeterminism
# cannot keep a lesson the session never saw. A preview validates and prints
# without journaling anything; a close journals the packet first. Both
# preview exits above return before this line, so a pure preview writes
# nothing. Loud never fatal — a missing session id must not fail a reflect.
if [ "$PACKET_ONLY" -eq 0 ]; then
  journal_event "reflect" "packet built: $label" || true
fi
if [ -n "$CANDIDATES_FILE" ]; then
  reuse_candidates
  exit 0
fi

if [ "$PACKET_ONLY" -eq 1 ]; then
  echo "CANDIDATES $candidates"
  echo "(packet only — no reflector run)"
  exit 0
fi

# Inside opencode the reflector runs natively: the generated agent already
# carries the pin, so shelling out buys nothing and a shell cannot spawn a
# native subagent anyway. The session reads this and runs it itself.
if [ -n "${OPENCODE_SESSION_ID:-}" ] || [ "${HARNESS_REFLECT_NATIVE:-}" = 1 ]; then
  echo "CANDIDATES $candidates"
  echo "REFLECTOR_NATIVE inside opencode the reflector runs natively, never through scripts/harness agent"
  echo "spawn the reflector subagent against the packet above with: Read $packet — propose up to 3 lessons from this close"
  echo "apply what you keep as small deltas, then log each candidate with:"
  echo "root=\$(scripts/harness root)"
  echo "bash \"\$root/scripts/lib/journal.sh\" lesson --tier <tier> --target <target> --text <text> --evidence <evidence> --outcome kept|dropped [--why <why>]"
  exit 0
fi

_agent_err="$(mktemp)" || { echo "REFLECTOR_FAILED cannot stage the reflector error" ; echo "CANDIDATES $candidates"; exit 0; }
if ! _reply="$(python3 "$(harness_script agent.py)" reflector "Read $packet — propose up to 3 lessons from this close" 2>"$_agent_err")"; then
  _reason="$(tail -1 "$_agent_err" 2>/dev/null | sed 's/^ *//')"
  [ -n "$_reason" ] || _reason="agent.py failed"
  echo "REFLECTOR_FAILED $_reason"
  echo "CANDIDATES $candidates"
  rm -f "$_agent_err"
  exit 0
fi
rm -f "$_agent_err"

_raw="$(mktemp)" || { echo "REFLECTOR_FAILED cannot stage the reflector reply"; echo "CANDIDATES $candidates"; exit 0; }
printf '%s\n' "$_reply" > "$_raw" || { echo "REFLECTOR_FAILED cannot stage the reflector reply"; echo "CANDIDATES $candidates"; rm -f "$_raw"; exit 0; }
_cand_err="$(mktemp)" || { echo "REFLECTOR_FAILED cannot stage the candidates error"; echo "CANDIDATES $candidates"; rm -f "$_raw"; exit 0; }
if ! _cout="$(emit_candidates "$candidates" fresh "$_raw" 2>"$_cand_err")"; then
  _reason="$(tail -1 "$_cand_err" 2>/dev/null | sed 's/^ *//')"
  [ -n "$_reason" ] || _reason="cannot parse the reflector reply"
  echo "REFLECTOR_FAILED $_reason"
  echo "CANDIDATES $candidates"
  rm -f "$_raw" "$_cand_err"
  exit 0
fi
rm -f "$_raw" "$_cand_err"

echo "CANDIDATES $candidates"
if [ -n "$_cout" ]; then
  printf '%s\n' "$_cout"
else
  echo "(reflector proposed nothing — zero candidates is normal)"
fi
