#!/bin/bash
# Probe for `harness add --reference`: a reference install writes the stubs,
# the seeds, CLAUDE.md and the finder — and nothing else — links the shared
# skills, and wires a working commit hook, all without copying the harness.
#
# Self-contained: every fixture lives under mktemp -d, HOME points at a temp
# dir so the real ~/.harness is never consulted, and HARNESS_HOME points at
# this checkout. One `ok <case>` / `FAIL <case>: why` line per case, plus a
# `BLOCKED <case>: ...` line when the finder's session/hook side (another
# worker's) is absent; BLOCKED never fails the run.
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

FAILS=0
pass() { printf 'ok %s\n' "$1"; }
failcase() { FAILS=$((FAILS + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

# Every install below links into this checkout's template/. A tool that writes
# into a linked path (bd init writes .agents/skills/beads/SKILL.md) lands in
# the SHARED harness, so hash the tree now and prove nothing wrote through.
shared_hash() {
  (cd "$REPO/template" && find . -type f ! -path '*/__pycache__/*' -print0 \
    | sort -z | xargs -0 shasum) | shasum | cut -d' ' -f1
}
SHARED_BEFORE="$(shared_hash)"
blocked() { printf 'BLOCKED %s: %s\n' "$1" "$2"; }

# The finder side this probe exercises through the installed project. When
# its session/hook subcommands are absent the cases below cannot run — report
# that rather than failing on another worker's half.
hook_supported=0
session_supported=0
if grep -qE '^[[:space:]]*hook\)' "$REPO/template/scripts/h" 2>/dev/null; then
  hook_supported=1
fi
if grep -qE '^[[:space:]]*session\)' "$REPO/template/scripts/h" 2>/dev/null; then
  session_supported=1
fi

# The box-rule marker, built from escapes rather than spelled out: a literal
# here would read as a fill-in block to any scan of this file.
box="$(printf '\342\224\200\342\224\200 FILL THIS IN')"

# --- 1: the file list ---
PROJ="$TMP/proj"
mkdir -p "$PROJ" || { echo "FAIL setup: cannot make the probe project"; exit 1; }
if ! "$REPO/bin/harness" add --reference "$PROJ" >"$TMP/add.log" 2>&1; then
  failcase "reference writes stubs seeds and finder" "add --reference exited non-zero"
else
  # Every reference path exists, stubs byte-identical to template/stubs and
  # the rest byte-identical to the template — seeds "as today". The two hook
  # files are the exception: bd init plants its own hooks on the way in and
  # the installer's tidier removes them, so those are checked semantically
  # below rather than byte-for-byte.
  missing=""
  drift=""
  while IFS= read -r rel; do
    case "$rel" in
      .claude/settings.json|.codex/hooks.json) want="" ;;
      AGENTS.md|opencode.json|scripts/hooks/commit-msg|scripts/hooks/pre-commit)
        want="$REPO/template/stubs/$rel" ;;
      *) want="$REPO/template/$rel" ;;
    esac
    if [ ! -e "$PROJ/$rel" ] && [ ! -L "$PROJ/$rel" ]; then
      missing="$missing $rel"
    elif [ -n "$want" ] && ! cmp -s "$want" "$PROJ/$rel"; then
      drift="$drift $rel"
    fi
  done <<'EOF'
AGENTS.md
.claude/settings.json
opencode.json
.codex/hooks.json
scripts/hooks/commit-msg
scripts/hooks/pre-commit
scripts/h
harness/seat.md
AGENTS.local.md
scripts/verify.steps.sh
scripts/review.scope.sh
dashboard.toml
harness/diverged.txt
harness/laurels.jsonl
harness/handoffs/.gitkeep
EOF
  if [ -n "$missing" ]; then
    failcase "reference writes stubs seeds and finder" "missing:$missing"
  elif [ -n "$drift" ]; then
    failcase "reference writes stubs seeds and finder" "differs from source:$drift"
  elif ! python3 - "$PROJ/.claude/settings.json" "$PROJ/.codex/hooks.json" <<'PYEOF' 2>"$TMP/hooks.err"; then
import json
import sys
settings = json.load(open(sys.argv[1]))
codex = json.load(open(sys.argv[2]))
starts = settings["hooks"]["SessionStart"][0]["hooks"]
assert starts[0]["command"] == 'cd "$CLAUDE_PROJECT_DIR" && scripts/h session --hook', starts[0]
assert starts[0]["timeout"] == 60, starts[0]
cmds = [h["command"] for group in settings["hooks"].values() for entry in group for h in entry["hooks"]]
assert 'cd "$CLAUDE_PROJECT_DIR" && scripts/h session --hook' in cmds, cmds
assert not [c for c in cmds if "dashboard" in c], "a dashboard hook survived in the stubs: %s" % (cmds,)
assert settings["permissions"] == {"allow": ["Bash(scripts/h:*)"]}, settings.get("permissions")
assert "bd prime" not in open(sys.argv[1]).read(), "bd prime survived in settings.json"
centries = [h["command"] for group in codex["hooks"]["SessionStart"] for h in group["hooks"]]
assert 'bash "$(git rev-parse --show-toplevel)/scripts/h" session --hook' in centries, centries
assert "codex-hook" not in open(sys.argv[2]).read(), "bd codex-hook survived in hooks.json"
assert "bd prime" not in open(sys.argv[2]).read(), "bd prime survived in hooks.json"
PYEOF
    failcase "reference writes stubs seeds and finder" "hook stubs lost their substance: $(head -1 "$TMP/hooks.err" 2>/dev/null)"
  else
    # Nothing under scripts/ besides the finder, the shim, and the seeds.
    scripts="$(cd "$PROJ" && find scripts | sort)"
    want_scripts="scripts
scripts/h
scripts/hooks
scripts/hooks/commit-msg
scripts/hooks/pre-commit
scripts/review.scope.sh
scripts/verify.steps.sh"
    if [ "$scripts" != "$want_scripts" ]; then
      failcase "reference writes stubs seeds and finder" "scripts/ holds more than h, hooks/ and the seeds"
    elif [ ! -x "$PROJ/scripts/h" ] || [ ! -x "$PROJ/scripts/hooks/commit-msg" ] || [ ! -x "$PROJ/scripts/hooks/pre-commit" ]; then
      failcase "reference writes stubs seeds and finder" "h or a shim lost its executable bit"
    elif ! grep -qF '@AGENTS.md' "$PROJ/CLAUDE.md" 2>/dev/null; then
      failcase "reference writes stubs seeds and finder" "CLAUDE.md never imports AGENTS.md"
    else
      pass "reference writes stubs seeds and finder"
    fi
  fi
fi

# --- 2: the skills are links into the shared checkout ---
if [ ! -d "$PROJ/.claude/skills" ]; then
  failcase "reference links shared skills" "no .claude/skills dir after link"
else
  before2=$FAILS
  for e in "$REPO"/template/.claude/skills/*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    n="${e##*/}"
    if [ ! -L "$PROJ/.claude/skills/$n" ]; then
      failcase "reference links shared skills" "$n is not a symlink"
    else
      got="$(readlink "$PROJ/.claude/skills/$n")"
      case "$got" in
        "$REPO/template/"*) ;;
        *) failcase "reference links shared skills" "$n points outside the shared template ($got)" ;;
      esac
    fi
  done
  if [ "$FAILS" -eq "$before2" ]; then
    pass "reference links shared skills"
  fi
fi

# --- 3: no fill-in block outside the seeds ---
if [ ! -f "$PROJ/AGENTS.md" ]; then
  failcase "reference keeps fill-in blocks in seeds" "no AGENTS.md to check"
else
  outside="$(cd "$PROJ" && grep -rlF -- "$box" . 2>/dev/null \
    --exclude-dir=.git --exclude-dir=.beads \
    | grep -vxF -e ./harness/seat.md -e ./AGENTS.local.md \
      -e ./scripts/verify.steps.sh -e ./scripts/review.scope.sh \
      -e ./dashboard.toml || true)"
  if [ -n "$outside" ]; then
    failcase "reference keeps fill-in blocks in seeds" "marker outside seeds in:$outside"
  else
    pass "reference keeps fill-in blocks in seeds"
  fi
fi

# --- 4: the stub pin block matches the template ---
if ! python3 - "$REPO/template/stubs/opencode.json" "$PROJ/opencode.json" <<'PYEOF' 2>"$TMP/pin.err"; then
import json
import sys
full = json.load(open(sys.argv[1]))
stub = json.load(open(sys.argv[2]))
for key in ("model", "small_model", "agent", "permission", "$schema"):
    assert full.get(key) == stub.get(key), "pin key differs: %s" % key
assert stub.get("instructions") == [".harness-contract.md", "AGENTS.md", "CLAUDE.md"], \
    "stub instructions: %r" % (stub.get("instructions"),)
PYEOF
  failcase "reference pin block matches the template" "$(head -1 "$TMP/pin.err" 2>/dev/null || echo 'pin comparison failed')"
else
  pass "reference pin block matches the template"
fi

# --- 5: the stubs are well-formed ---
if ! bash -n "$PROJ/scripts/hooks/commit-msg" 2>/dev/null; then
  failcase "reference stubs are well-formed" "the commit-msg shim does not parse"
elif ! bash -n "$PROJ/scripts/hooks/pre-commit" 2>/dev/null; then
  failcase "reference stubs are well-formed" "the pre-commit shim does not parse"
elif ! python3 -c 'import json,sys; [json.load(open(p)) for p in sys.argv[1:]]' \
    "$PROJ/.claude/settings.json" "$PROJ/.codex/hooks.json" "$PROJ/opencode.json" 2>/dev/null; then
  failcase "reference stubs are well-formed" "a stub json does not parse"
else
  pass "reference stubs are well-formed"
fi

# Everything below goes through the finder's session/hook subcommands, which
# land from another worker. The commit under test needs an identity and a
# HARNESS_HOME the hook inherits — hooks run with the committer's env.
export GIT_AUTHOR_NAME=probe GIT_AUTHOR_EMAIL=probe@t
export GIT_COMMITTER_NAME=probe GIT_COMMITTER_EMAIL=probe@t
git -C "$PROJ" config user.email probe@t >/dev/null 2>&1 || true
git -C "$PROJ" config user.name probe >/dev/null 2>&1 || true

# --- 6: a bead-less commit is rejected ---
if [ "$hook_supported" -eq 0 ]; then
  blocked "commit-msg rejects a bead-less commit" "no hook subcommand in template/scripts/h yet"
else
  (cd "$PROJ" && git add -A >/dev/null 2>&1)
  if (cd "$PROJ" && git -c commit.gpgsign=false commit -m "probe with no bead" >"$TMP/reject.log" 2>&1); then
    failcase "commit-msg rejects a bead-less commit" "exit 0 on a bead-less message"
  elif grep -q "names no bead" "$TMP/reject.log" 2>/dev/null; then
    pass "commit-msg rejects a bead-less commit"
  else
    failcase "commit-msg rejects a bead-less commit" "rejected without naming the bead"
  fi
fi

# --- 7: a commit naming a bead is accepted ---
if [ "$hook_supported" -eq 0 ]; then
  blocked "commit-msg accepts a commit naming a bead" "no hook subcommand in template/scripts/h yet"
else
  if ! bid="$(cd "$PROJ" && bd create "probe work" --design "d" --acceptance "a" --silent 2>"$TMP/bead.err")"; then
    failcase "commit-msg accepts a commit naming a bead" "cannot file a probe bead: $(head -1 "$TMP/bead.err" 2>/dev/null)"
  else
    # The ledger reads its own writes: wait out the lag before committing.
    tries=0
    while ! (cd "$PROJ" && bd show "$bid" >/dev/null 2>&1); do
      tries=$((tries + 1))
      [ "$tries" -ge 15 ] && break
      sleep 1
    done
    if (cd "$PROJ" && git -c commit.gpgsign=false commit -m "probe with bead $bid" >"$TMP/accept.log" 2>&1); then
      pass "commit-msg accepts a commit naming a bead"
    else
      failcase "commit-msg accepts a commit naming a bead" "rejected a commit naming $bid"
    fi
  fi
fi

# --- 7b: a commit lands a fresh export without a manual regen ---
if [ "$hook_supported" -eq 0 ]; then
  blocked "pre-commit lands a fresh export without a manual regen" "no hook subcommand in template/scripts/h yet"
else
  if ! bid2="$(cd "$PROJ" && bd create "second probe work" --design "d" --acceptance "a" --silent 2>"$TMP/bead2.err")"; then
    failcase "pre-commit lands a fresh export without a manual regen" "cannot file a second probe bead: $(head -1 "$TMP/bead2.err" 2>/dev/null)"
  else
    tries=0
    while ! (cd "$PROJ" && bd show "$bid2" >/dev/null 2>&1); do
      tries=$((tries + 1))
      [ "$tries" -ge 15 ] && break
      sleep 1
    done
    if ! (cd "$PROJ" && bd remember "probe precommit knowledge" >/dev/null 2>&1); then
      failcase "pre-commit lands a fresh export without a manual regen" "cannot remember probe knowledge"
    else
      echo "probe source" > "$PROJ/probe-precommit.txt" || { echo "FAIL setup: cannot dirty a probe file"; exit 1; }
      (cd "$PROJ" && git add -A >/dev/null 2>&1) || { echo "FAIL setup: cannot stage"; exit 1; }
      if ! (cd "$PROJ" && git -c commit.gpgsign=false commit -m "probe commit for $bid2" >"$TMP/precommit.log" 2>&1); then
        failcase "pre-commit lands a fresh export without a manual regen" "commit failed: $(head -1 "$TMP/precommit.log" 2>/dev/null)"
      elif ! (cd "$PROJ" && git show HEAD:.beads/issues.jsonl > "$TMP/precommit-committed.jsonl" 2>/dev/null); then
        failcase "pre-commit lands a fresh export without a manual regen" "the commit carries no ledger export"
        elif ! grep -qF "$bid2" "$TMP/precommit-committed.jsonl"; then
          failcase "pre-commit lands a fresh export without a manual regen" "the committed export missed the probe bead"
        elif ! grep -q "probe precommit knowledge" "$TMP/precommit-committed.jsonl"; then
          failcase "pre-commit lands a fresh export without a manual regen" "the committed export missed the probe memory"
        elif ! cmp -s "$TMP/precommit-committed.jsonl" "$PROJ/.beads/issues.jsonl"; then
          failcase "pre-commit lands a fresh export without a manual regen" "the hook left the worktree export dirty"
        else
          pass "pre-commit lands a fresh export without a manual regen"
        fi
    fi
  fi
fi

# --- 8: session prints the contract and the brief ---
if [ "$session_supported" -eq 0 ]; then
  blocked "session prints the contract and the brief" "no session subcommand in template/scripts/h yet"
else
  if ! "$PROJ/scripts/h" session >"$TMP/session.log" 2>&1; then
    failcase "session prints the contract and the brief" "non-zero exit"
  elif ! grep -q "Working on this project" "$TMP/session.log" 2>/dev/null; then
    failcase "session prints the contract and the brief" "the contract never printed"
  else
    pass "session prints the contract and the brief"
  fi
fi

# --- 9: session --hook emits the SessionStart object ---
if [ "$session_supported" -eq 0 ]; then
  blocked "session --hook emits the SessionStart object" "no session subcommand in template/scripts/h yet"
else
  if ! "$PROJ/scripts/h" session --hook >"$TMP/hook.log" 2>&1; then
    failcase "session --hook emits the SessionStart object" "non-zero exit"
  elif ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["hookSpecificOutput"]["hookEventName"]=="SessionStart"' \
      "$TMP/hook.log" 2>/dev/null; then
    failcase "session --hook emits the SessionStart object" "not a SessionStart JSON object"
  else
    pass "session --hook emits the SessionStart object"
  fi
fi

# --- 10: an unresolvable harness fails before writing anything ---
BAD="$TMP/bad-target"
mkdir -p "$BAD" || { echo "FAIL setup: cannot make the failure fixture"; exit 1; }
printf 'sentinel\n' > "$BAD/keep.txt" || { echo "FAIL setup: cannot plant the sentinel"; exit 1; }
before_ls="$(cd "$BAD" && find . | sort)"
if HARNESS_HOME="$TMP/nowhere" "$REPO/bin/harness" add --reference "$BAD" >"$TMP/bad.log" 2>&1; then
  failcase "unresolvable harness fails before writing" "exit 0 with HARNESS_HOME pointing nowhere"
elif ! grep -q "HARNESS_HOME" "$TMP/bad.log" 2>/dev/null; then
  failcase "unresolvable harness fails before writing" "stderr never names the fix"
elif [ "$(cd "$BAD" && find . | sort)" != "$before_ls" ]; then
  failcase "unresolvable harness fails before writing" "the target gained files"
elif [ ! -e "$BAD/.git" ]; then
  pass "unresolvable harness fails before writing"
else
  failcase "unresolvable harness fails before writing" "a git repository was initialised"
fi

# --- 11: .codex/agents is gitignored derived output, never committed ---
before11=$FAILS
if [ ! -d "$PROJ/.codex/agents" ]; then
  failcase "codex agents are derived and gitignored" "no .codex/agents after add --reference"
else
  if [ -n "$(cd "$PROJ" && git ls-files .codex/agents)" ]; then
    failcase "codex agents are derived and gitignored" ".codex/agents is tracked"
  fi
  probe_toml="$(cd "$PROJ" && ls .codex/agents/*.toml 2>/dev/null | head -1)"
  if [ -z "$probe_toml" ]; then
    failcase "codex agents are derived and gitignored" "no generated toml to check"
  elif ! (cd "$PROJ" && git check-ignore -q "$probe_toml"); then
    failcase "codex agents are derived and gitignored" "$probe_toml is not gitignored"
  fi
fi
if [ "$FAILS" -eq "$before11" ]; then
  pass "codex agents are derived and gitignored"
fi

# --- 12: a shared prompt edit passes check and lands in the toml ---
# A scratch shared checkout, never the live tree: editing the starter's own
# prompts mid-test would dirty every parallel session.
SHARED="$TMP/shared"
before12=$FAILS
if ! mkdir -p "$SHARED" 2>/dev/null; then
  failcase "shared prompt edits flow through check" "cannot make the scratch checkout"
elif ! cp -R "$REPO/template" "$SHARED/template" 2>/dev/null; then
  failcase "shared prompt edits flow through check" "cannot copy the template"
else
  PROJ2="$TMP/proj2"
  if ! mkdir -p "$PROJ2" 2>/dev/null; then
    failcase "shared prompt edits flow through check" "cannot make the second project"
  elif ! HARNESS_HOME="$SHARED" "$REPO/bin/harness" add --reference "$PROJ2" >"$TMP/add2.log" 2>&1; then
    failcase "shared prompt edits flow through check" "add --reference failed: $(head -1 "$TMP/add2.log" 2>/dev/null)"
  else
    agent_src="$(ls "$SHARED/template/.claude/agents/"*.md 2>/dev/null | head -1)"
    agent_name="$(basename "$agent_src" .md 2>/dev/null)"
    if [ -z "$agent_name" ]; then
      failcase "shared prompt edits flow through check" "no shared agent prompt to edit"
    else
      printf '\nprobe rule\n' >> "$agent_src" || { echo "FAIL setup: cannot edit the scratch prompt"; exit 1; }
      if ! HARNESS_HOME="$SHARED" "$PROJ2/scripts/h" codex-support check >"$TMP/check2.log" 2>&1; then
        failcase "shared prompt edits flow through check" "check failed after a shared edit: $(head -1 "$TMP/check2.log" 2>/dev/null)"
      elif ! grep -q "probe rule" "$PROJ2/.codex/agents/$agent_name.toml" 2>/dev/null; then
        failcase "shared prompt edits flow through check" "the toml never picked up the shared edit"
      fi
    fi
  fi
fi
if [ "$FAILS" -eq "$before12" ]; then
  pass "shared prompt edits flow through check"
fi

# --- modes: installed files read like any checkout's (mktemp makes 0600) ---
mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }
if [ "$(mode_of "$PROJ/AGENTS.md")" = 644 ] && [ "$(mode_of "$PROJ/scripts/h")" = 755 ]; then
  pass "installed files keep readable modes"
else
  failcase "installed files keep readable modes" "AGENTS.md $(mode_of "$PROJ/AGENTS.md"), scripts/h $(mode_of "$PROJ/scripts/h") — want 644 and 755"
fi

# --- last: no install wrote through a link into the shared checkout ---
if [ "$(shared_hash)" = "$SHARED_BEFORE" ]; then
  pass "installs never write into the shared checkout"
else
  failcase "installs never write into the shared checkout" "template/ changed during the probe — git status template/ shows what"
fi

if [ "$FAILS" -eq 0 ]; then
  exit 0
else
  exit 1
fi
