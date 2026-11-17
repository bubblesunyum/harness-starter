# Per-session live journal and review findings log.
#
# Loop boundaries (verify, review, the commit hook) append machine-written
# lines to a per-session live file under harness/handoffs/ — never model
# prose, never per turn. The committed handoff note stays the one immutable
# file per close; the close removes only its own live file.
#
# Sourced (provides journal_session_id, journal_event, journal_close,
# journal_finding, journal_lesson, journal_orphan) or executed:
#
#   lib/journal.sh session-id
#   lib/journal.sh event <kind> <detail...>
#   lib/journal.sh finding --category <slug> --reviewer <role> --bead <id> --outcome accepted|rejected [--note <line>]
#   lib/journal.sh lesson --tier <tier> --target <target> --text <line> --evidence <bead|commit|finding> --outcome kept|dropped|unreviewed|failed [--why <line>]
#   lib/journal.sh close
#   lib/journal.sh orphan
#
# The journal files under HARNESS_PROJECT (the project, defaulting to the
# enclosing git toplevel). Readers of harness/learning.jsonl skip blank lines
# and lines starting with `#`, which is what the seed's schema comment is.
#
# Bash 3.2 only (macOS /bin/bash): no associative arrays, no mapfile, and no
# bare "$@" on an empty argument list under `set -u` — every expansion below
# is guarded, because this file is sourced into scripts that run that way.

# The id every journal line in this session files under: the explicit
# override first, then the tool's own session id, so two parallel sessions
# never share a file. Sanitised to filename-safe characters (a traversal in
# an id must never become a path); neighbours that differ only in stripped
# characters share, which beats failing. Fails loudly when nothing usable is
# set — callers skip the write rather than sharing a file.
journal_session_id() {
  local id v val
  id="${HARNESS_SESSION_ID:-}"
  if [ -z "$id" ]; then
    for v in OPENCODE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID; do
      val="$(eval "printf '%s' \"\${$v:-}\"")"
      if [ -n "$val" ]; then id="$val"; break; fi
    done
  fi
  id="$(printf '%s' "$id" | tr -cd 'A-Za-z0-9_.-' | cut -c1-80)"
  case "$id" in
    ""|.|..)
      echo "journal: cannot derive a session id — export HARNESS_SESSION_ID to something unique per session; writing nothing rather than sharing a file" >&2
      return 1;;
  esac
  printf '%s\n' "$id"
}

# The project this journal belongs to, on stdout. HARNESS_PROJECT when the
# dispatcher set it, else the enclosing git toplevel.
journal_project() {
  local top
  if [ -n "${HARNESS_PROJECT:-}" ]; then printf '%s\n' "$HARNESS_PROJECT"; return 0; fi
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "journal: cannot find the project — set HARNESS_PROJECT or run inside a git checkout" >&2
    return 1
  }
  printf '%s\n' "$top"
}

# The live file for a session id, on stdout. Fails (not an error the caller
# reports) when harness/handoffs/ is absent: the journal must never create
# project structure as a side effect — an untracked dir would read as work in
# the next status.
journal_live_file() {
  local proj="$1" id="$2" dir
  dir="$proj/harness/handoffs"
  [ -d "$dir" ] || return 1
  printf '%s/.live-%s.md\n' "$dir" "$id"
}

# The session's start rev from the live file header, on stdout. Fails when
# there is no live file or no rev recorded — the caller falls back to HEAD,
# labelled as a fallback.
journal_start_rev() {
  local id proj file rev
  id="$(journal_session_id)" || return 1
  proj="$(journal_project)" || return 1
  file="$(journal_live_file "$proj" "$id")" || return 1
  [ -f "$file" ] || return 1
  rev="$(sed -n 's/^# start-rev: //p' "$file" 2>/dev/null | head -1)" || return 1
  case "$rev" in ""|none) return 1;; esac
  printf '%s\n' "$rev"
}

journal_now() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u; }

# One machine-written line. Creates the file with a header on first write.
# Loud on failure, silent on success — the gate's tiny output stays tiny.
journal_event() {
  local kind detail id proj file now _sr
  [ $# -ge 1 ] || { echo "journal: event needs a kind" >&2; return 1; }
  kind="$1"; shift
  detail=""
  if [ $# -gt 0 ]; then detail="$*"; fi
  id="$(journal_session_id)" || return 1
  proj="$(journal_project)" || return 1
  file="$(journal_live_file "$proj" "$id")" || {
    if [ -d "$proj/harness" ]; then
      echo "journal: no harness/handoffs/ in $proj — skipping the live journal" >&2
    fi
    return 1
  }
  if [ ! -f "$file" ]; then
    # The session's start rev, so a later reflect diffs session-start..work
    # instead of HEAD..work and sees what the session already committed.
    # Recorded once, at first write; none when not a repo or no commits yet.
    _sr="$(git -C "$proj" rev-parse HEAD 2>/dev/null || true)"
    [ -n "$_sr" ] || _sr="none"
    {
      printf '# live journal %s — gitignored; removed when this session closes with a handoff\n' "$id"
      printf '# start-rev: %s\n' "$_sr"
    } > "$file" || {
      echo "journal: cannot write $file" >&2; return 1
    }
  fi
  now="$(journal_now)"
  detail="$(printf '%s' "$detail" | tr '\n\t' '  ')"
  printf '%s %s %s\n' "$now" "$kind" "$detail" >> "$file" || {
    echo "journal: cannot append to $file" >&2; return 1
  }
}

# Remove this session's own live file, on a close. It names only its own file —
# a close never touches another session's. Missing file or dir is success:
# there is nothing to remove.
journal_close() {
  local id proj file
  id="$(journal_session_id)" || return 1
  proj="$(journal_project)" || return 1
  file="$(journal_live_file "$proj" "$id")" || return 0
  rm -f "$file"
}

# One review finding the session accepted or rejected, appended to
# harness/learning.jsonl. Category is a short slug the session chose.
journal_finding() {
  local category reviewer bead outcome note now log proj
  category=""; reviewer=""; bead=""; outcome=""; note=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --category) [ $# -ge 2 ] || { echo "journal: --category needs a value" >&2; return 1; }; category="$2"; shift 2;;
      --reviewer) [ $# -ge 2 ] || { echo "journal: --reviewer needs a value" >&2; return 1; }; reviewer="$2"; shift 2;;
      --bead) [ $# -ge 2 ] || { echo "journal: --bead needs a value" >&2; return 1; }; bead="$2"; shift 2;;
      --outcome) [ $# -ge 2 ] || { echo "journal: --outcome needs a value" >&2; return 1; }; outcome="$2"; shift 2;;
      --note) [ $# -ge 2 ] || { echo "journal: --note needs a value" >&2; return 1; }; note="$2"; shift 2;;
      --) shift; break;;
      *) echo "journal: unknown finding arg $1" >&2; return 1;;
    esac
  done
  [ -n "$category" ] || { echo "journal: finding needs --category" >&2; return 1; }
  [ -n "$reviewer" ] || { echo "journal: finding needs --reviewer" >&2; return 1; }
  [ -n "$bead" ] || { echo "journal: finding needs --bead" >&2; return 1; }
  case "$outcome" in
    accepted|rejected) ;;
    *) echo "journal: --outcome must be accepted or rejected" >&2; return 1;;
  esac
  printf '%s' "$category" | grep -qE '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' || {
    echo "journal: --category is a short slug (letters, digits, - and _)" >&2; return 1
  }
  command -v python3 >/dev/null 2>&1 || {
    echo "journal: python3 is needed for the findings log" >&2; return 1
  }
  proj="$(journal_project)" || return 1
  if [ ! -d "$proj/harness" ]; then
    echo "journal: no harness/ in $proj — skipping the findings log" >&2; return 1
  fi
  log="$proj/harness/learning.jsonl"
  now="$(journal_now)"
  python3 - "$category" "$reviewer" "$bead" "$outcome" "$note" "$now" "$log" <<'PYEOF' || {
import json
import sys
category, reviewer, bead, outcome, note, now, path = sys.argv[1:8]
entry = {"kind": "finding", "category": category, "reviewer": reviewer,
         "bead": bead, "outcome": outcome, "ts": now}
if note:
    entry["note"] = " ".join(note.split())
with open(path, "a") as handle:
    handle.write(json.dumps(entry, sort_keys=True) + "\n")
PYEOF
    echo "journal: cannot append to $log" >&2; return 1
  }
}

# One reflector candidate with the session's decision, appended to
# harness/learning.jsonl. Tier is one of memory, reviewer-trap, skill,
# claude-md; outcome kept, dropped, unreviewed or failed, with why saying
# what decided it. Fresh candidates the session never reviewed log
# unreviewed, never dropped; dropped is a reviewed list the session declined.
# A kept memory that bd could not store logs failed, loudly, never dropped.
journal_lesson() {
  local tier target text evidence outcome why now log proj
  tier=""; target=""; text=""; evidence=""; outcome=""; why=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tier) [ $# -ge 2 ] || { echo "journal: --tier needs a value" >&2; return 1; }; tier="$2"; shift 2;;
      --target) [ $# -ge 2 ] || { echo "journal: --target needs a value" >&2; return 1; }; target="$2"; shift 2;;
      --text) [ $# -ge 2 ] || { echo "journal: --text needs a value" >&2; return 1; }; text="$2"; shift 2;;
      --evidence) [ $# -ge 2 ] || { echo "journal: --evidence needs a value" >&2; return 1; }; evidence="$2"; shift 2;;
      --outcome) [ $# -ge 2 ] || { echo "journal: --outcome needs a value" >&2; return 1; }; outcome="$2"; shift 2;;
      --why) [ $# -ge 2 ] || { echo "journal: --why needs a value" >&2; return 1; }; why="$2"; shift 2;;
      --) shift; break;;
      *) echo "journal: unknown lesson arg $1" >&2; return 1;;
    esac
  done
  case "$tier" in
    memory|reviewer-trap|skill|claude-md) ;;
    *) echo "journal: --tier must be memory, reviewer-trap, skill or claude-md" >&2; return 1;;
  esac
  [ -n "$target" ] || { echo "journal: lesson needs --target" >&2; return 1; }
  [ -n "$text" ] || { echo "journal: lesson needs --text" >&2; return 1; }
  [ -n "$evidence" ] || { echo "journal: lesson needs --evidence" >&2; return 1; }
  case "$outcome" in
    kept|dropped|unreviewed|failed) ;;
    *) echo "journal: --outcome must be kept, dropped, unreviewed or failed" >&2; return 1;;
  esac
  command -v python3 >/dev/null 2>&1 || {
    echo "journal: python3 is needed for the lessons log" >&2; return 1
  }
  proj="$(journal_project)" || return 1
  if [ ! -d "$proj/harness" ]; then
    echo "journal: no harness/ in $proj — skipping the lessons log" >&2; return 1
  fi
  log="$proj/harness/learning.jsonl"
  now="$(journal_now)"
  python3 - "$tier" "$target" "$text" "$evidence" "$outcome" "$why" "$now" "$log" <<'PYEOF' || {
import json
import sys
tier, target, text, evidence, outcome, why, now, path = sys.argv[1:9]
entry = {"kind": "lesson", "tier": tier, "target": " ".join(target.split()),
         "text": " ".join(text.split()), "evidence": " ".join(evidence.split()),
         "outcome": outcome, "ts": now}
if why.strip():
    entry["why"] = " ".join(why.split())
with open(path, "a") as handle:
    handle.write(json.dumps(entry, sort_keys=True) + "\n")
PYEOF
    echo "journal: cannot append to $log" >&2; return 1
  }
}

# How long ago a journal mtime was, in the board's words. Empty when the
# clock cannot say — the caller then prints the line without an age.
journal_age() {
  local mt="$1" now age
  case "$mt" in ''|*[!0-9]*) return 0;; esac
  now="$(date +%s 2>/dev/null)" || return 0
  case "$now" in ''|*[!0-9]*) return 0;; esac
  [ "$now" -ge "$mt" ] || return 0
  age="$(( (now - mt) / 60 ))"
  case "$age" in ''|*[!0-9]*) return 0;; esac
  if [ "$age" -lt 60 ]; then printf '%sm ago\n' "$age"
  elif [ "$age" -lt 2880 ]; then printf '%sh ago\n' "$((age / 60))"
  else printf '%sd ago\n' "$((age / 1440))"; fi
}

# One line naming another session's unclosed journal, or nothing. The brief
# prints whatever comes back — silence is the common case, one line the most.
journal_orphan() {
  local proj dir own f oldest oldest_mt mt age line rel
  proj="$(journal_project 2>/dev/null)" || return 0
  dir="$proj/harness/handoffs"
  [ -d "$dir" ] || return 0
  own="$(journal_session_id 2>/dev/null)" || own=""
  oldest=""; oldest_mt=""
  for f in "$dir"/.live-*.md; do
    [ -e "$f" ] || continue
    if [ -n "$own" ] && [ "$f" = "$dir/.live-$own.md" ]; then continue; fi
    # BSD and GNU disagree on stat.
    mt="$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null)" || continue
    case "$mt" in ''|*[!0-9]*) continue;; esac
    if [ -z "$oldest_mt" ] || [ "$mt" -lt "$oldest_mt" ]; then
      oldest="$f"; oldest_mt="$mt"
    fi
  done
  [ -n "$oldest" ] || return 0
  age="$(journal_age "$oldest_mt")"
  rel="${oldest#$proj/}"
  if [ -n "$age" ]; then
    line="other journal: $rel (updated $age) — its session never closed with a handoff; read it or remove it if its session is gone"
  else
    line="other journal: $rel — its session never closed with a handoff; read it or remove it if its session is gone"
  fi
  printf '%s\n' "$line"
}

journal_main() {
  local cmd
  cmd="${1:-}"
  case "$cmd" in
    session-id) journal_session_id;;
    event) shift; journal_event "$@";;
    finding) shift; journal_finding "$@";;
    lesson) shift; journal_lesson "$@";;
    close) shift; journal_close;;
    orphan) journal_orphan;;
    *) echo "usage: journal.sh {session-id|event <kind> <detail...>|finding --category ...|lesson --tier ...|close|orphan}" >&2; return 2;;
  esac
}

# Sourced into other scripts above, executed directly below: `return` fails at
# the top level of a run script, so the subshell tells the two apart.
if (return 0 2>/dev/null); then
  :
else
  journal_main "$@"
fi
