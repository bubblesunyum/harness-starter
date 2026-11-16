#!/bin/bash
# convert a copy install into a reference install
#
#   harness migrate [--apply] [path]
#
# A copy install carries the whole harness; a reference install keeps the
# contract in the shared checkout and reaches it through scripts/h. This
# classifies every file the copy carries and converts it:
#
#   remove  an unedited copy of the shared file — today's or any older starter
#           revision's — the link or dispatch covers it
#   lift    a customised reviewer prompt — its own lines move into
#           harness/reviewers/<role>.md, then the prompt goes
#   keep    seeds, project data, acknowledged forks, own files, the reference
#           files themselves — never touched
#   stub    matches the shared contract — replaced with the reference stub
#   write   a missing reference file — installed from the shared harness
#   name    differs — left in place and named, never deleted. A project-specific
#           change to a shared script stays as a same-path shadow; reviewer
#           answers belong in harness/reviewers/<role>.md; anything else moves
#           into AGENTS.local.md or upstream to the starter
#
# Dry run by default: every file with its fate, nothing written. --apply
# writes, then runs `scripts/h link` (after any bd command — this runs none,
# so the order holds trivially). A second --apply is a no-op. Never touches
# a repo with uncommitted changes: names them and exits 1.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMPLATE="$HERE/template"
# shellcheck source=lib/install.sh
. "$HERE/commands/lib/install.sh"
# shellcheck source=lib/migrate.sh
. "$HERE/commands/lib/migrate.sh"

usage() {
  cat <<USAGE
Converts a copy install of the harness into a reference install.

  harness migrate [--apply] [path]   (path defaults to .)

Dry run by default: lists every carried file with its fate and writes
nothing. --apply converts: unedited copies go (today's or any older starter
revision's), reviewer lines lift into harness/reviewers/, stubs replace the
contract, missing reference files are installed — then scripts/h link runs.
A file that differs is left in place and named: a project-specific change to
a shared script stays as a same-path shadow (scripts/h and the shared scripts
already resolve project-first); project answers in reviewer prompts belong in
harness/reviewers/<role>.md; anything else, move into AGENTS.local.md or
upstream it to the starter. Files listed in harness/diverged.txt stay as
acknowledged shadows.

Refuses a dirty tree: with --apply, uncommitted changes name themselves and
this exits 1. Needs HARNESS_HOME or ~/.harness for --apply, checked before
anything is written.
USAGE
}

apply=0
target=""
for arg in ${1+"$@"}; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --apply) apply=1 ;;
    -*) echo "✗ unknown option: $arg" >&2; echo >&2; usage >&2; exit 1 ;;
    *)
      [ -z "$target" ] || { echo "✗ more than one path given: $target and $arg" >&2; exit 1; }
      target="$arg"
      ;;
  esac
done

target="$(harness_resolve_target "${target:-$PWD}")"
harness_require_python3 || exit 1
# A starter checkout converts itself to reference: its root files against its
# own template/, which migrate never writes under, so the source stays intact.
# Any other target equalling this checkout is a mistake, so it still refuses.
if [ "$target" = "$HERE" ] && [ ! -f "$target/template/.harness-root" ]; then
  echo "✗ cannot migrate the starter checkout itself ($HERE)." >&2
  echo "  Migrate a project that installed it instead." >&2
  exit 1
fi

diverged_want=""
if [ -f "$target/harness/diverged.txt" ]; then
  diverged_want="$(harness_diverged_want "$target")" || {
    echo "✗ harness/diverged.txt exists but is not readable — fix it and re-run." >&2
    exit 1
  }
fi
if [ -e "$target/harness/stacks.txt" ] && ! harness_stacks_want "$target" >/dev/null; then
  echo "✗ harness/stacks.txt exists but is not readable — fix it and re-run." >&2
  exit 1
fi
files="$(harness_files_for "$HERE" "$target")" || exit 1
# Every stub path, named once: the force-include loop below and the classify
# dispatch both read this, so a new stub cannot land in one but not the other.
# The stubs are classified whatever today's template holds: their old shared
# counterparts (.claude/settings.json, opencode.json, ...) left template/
# when installs went by reference, but every copied install still carries them
# and they still need replacing with the stub.
MIGRATE_STUBS="AGENTS.md opencode.json .claude/settings.json .codex/hooks.json scripts/hooks/commit-msg"
for stub_rel in $MIGRATE_STUBS; do
  printf '%s\n' "$files" | grep -qxF "$stub_rel" || files="$files
$stub_rel"
done
# A broken diverged list fails before anything is written — in the dry run as
# well as --apply — or a typo silently un-acknowledges the fork it meant.
migrate_validate_diverged "$files" "$diverged_want" || exit 1

if [ "$apply" -eq 1 ]; then
  # Clean tree, or nothing is written: a migrate deletes files, and deleting
  # into uncommitted work strands it. Names the changes and exits 1.
  dirty="$(git -C "$target" status --porcelain)" || exit 1
  if [ -n "$dirty" ]; then
    echo "✗ $target has uncommitted changes — migrate only runs on a clean tree:" >&2
    printf '%s\n' "$dirty" | sed 's/^/  /' >&2
    echo "  Commit or stash them, then re-run." >&2
    exit 1
  fi
  # The harness has to resolve before anything is written: the run ends with
  # scripts/h link, and a link that cannot resolve is a half-migrated tree.
  resolved_root="$(migrate_reference_root "$target")" || exit 1
  # Stubs come from this checkout's template/ and links from whatever the
  # finder resolves; two different checkouts would be a version-skewed install
  # that reports success. Refuse, naming both.
  here_root="$(cd "$TEMPLATE" && pwd -P)"
  if [ "$resolved_root" != "$here_root" ]; then
    echo "✗ this migrate runs from $here_root, but the project's finder resolves $resolved_root." >&2
    echo "  Run the migrate from that checkout, or point HARNESS_HOME at this one." >&2
    exit 1
  fi
fi

plan="$(mktemp)" || { echo "✗ mktemp failed" >&2; exit 1; }
rendered="$(mktemp)" || { echo "✗ mktemp failed" >&2; exit 1; }
expected="$(mktemp)" || { echo "✗ mktemp failed" >&2; exit 1; }
histcache="$(mktemp -d)" || { echo "✗ mktemp failed" >&2; exit 1; }
trap 'rm -f "$plan" "$rendered" "$expected"; rm -rf "$histcache"' EXIT

target_real="$(cd "$target" && pwd -P)" || { echo "✗ cannot resolve $target" >&2; exit 1; }

# Whether $1 (project-relative) is reached through a symlink that leaves the
# project — a linked shared skill, say. Such a path is the SHARED harness, not
# a copy: reading it looks "identical", and removing or writing it would edit
# the starter for every project. A second --apply walks straight into this.
migrate_through_link() {
  local dir
  dir="$(dirname "$target/$1")"
  [ -d "$dir" ] || return 1
  dir="$(cd "$dir" && pwd -P)" || return 1
  case "$dir/" in "$target_real"/*) return 1 ;; esac
  return 0
}

migrate_plan_add() {
  if [ "$1" != keep ] && [ "$1" != name ] && migrate_through_link "$2"; then
    printf '%s|%s|%s\n' keep "$2" "reached through a link into the shared harness — not the project's" >> "$plan"
    return 0
  fi
  printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$plan"
}

# A file matching the shared file at an older starter revision, not today's:
# remove, or the stub where a stub replaces the contract. "worktree" means it
# matches the working tree but no commit (a dirty checkout) — today's wording.
migrate_say_older() {
  local fate="$1" rel="$2" sha="$3"
  if [ "$sha" = worktree ]; then
    if [ "$fate" = stub ]; then
      migrate_plan_add "stub" "$rel" "matches the shared contract; the reference stub takes its place"
    else
      migrate_plan_add "remove" "$rel" "identical to the shared file"
    fi
  elif [ "$fate" = stub ]; then
    migrate_plan_add "stub" "$rel" "an unedited copy from an older starter revision ($sha); the reference stub takes its place"
  else
    migrate_plan_add "remove" "$rel" "an unedited copy from an older starter revision ($sha)"
  fi
}

# One customised reviewer prompt: lift its own lines, then drop the prompt
# so the shared one links over it. Identical prompts go, at this revision or
# any older one.
migrate_classify_reviewer() {
  local rel="$1" role overlay count histsha
  role="$(basename "$rel" .md)"
  role="${role#reviewer-}"
  role="$(migrate_role_of "$role")" || {
    echo "✗ $rel is a reviewer prompt with an unknown role — add it to migrate_role_of in commands/lib/migrate.sh." >&2
    exit 1
  }
  overlay="harness/reviewers/$role.md"
  harness_render "$TEMPLATE/$rel" > "$rendered"
  if harness_same "$rel" "$rendered" "$target/$rel"; then
    migrate_plan_add "remove" "$rel" "identical to the shared file"
  elif histsha="$(migrate_historic_sha "$HERE" "$rel" "$target/$rel" "$histcache")"; then
    migrate_say_older remove "$rel" "$histsha"
  else
    count="$(migrate_lift "$target/$rel" "$rendered" "$target/$overlay" "$rel" count)" || {
      echo "✗ cannot compare $rel against the shared prompt." >&2
      exit 1
    }
    migrate_plan_add "lift" "$rel" "$overlay|$count"
  fi
}

# One stub path (AGENTS.md, opencode.json, the hook stubs): already the stub
# stays, a file matching the copy source — today's or any older starter
# revision's — takes the stub, anything else is a customisation kept and named.
migrate_classify_stub() {
  local rel="$1" stubsrc histsha
  stubsrc="$TEMPLATE/$(harness_reference_src "$rel")"
  if harness_same "$rel" "$stubsrc" "$target/$rel"; then
    migrate_plan_add "keep" "$rel" "already the reference file"
  else
    if [ -f "$TEMPLATE/$rel" ]; then
      harness_render "$TEMPLATE/$rel" > "$rendered" 2>/dev/null || : > "$rendered"
    else
      # Gone from template/ since installs went by reference: compare against
      # the last version the starter shipped, content-aware like today's file
      # would be — an install tidies these JSON hooks, so bytes rarely match.
      migrate_last_shipped "$HERE" "$rel" > "$rendered" 2>/dev/null || : > "$rendered"
    fi
    if [ -s "$rendered" ] && harness_same "$rel" "$rendered" "$target/$rel"; then
      migrate_plan_add "stub" "$rel" "matches the shared contract; the reference stub takes its place"
    elif histsha="$(migrate_historic_sha "$HERE" "$rel" "$target/$rel" "$histcache")"; then
      migrate_say_older stub "$rel" "$histsha"
    else
      migrate_plan_add "name" "$rel" "customised — kept; adopt the stub, or move project answers into AGENTS.local.md or upstream them to the starter"
    fi
  fi
}

while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  dst="$target/$rel"
  # A link is already managed — by a previous migrate's link run — so it is
  # never classified. Removing one would strand the shared entry it points at.
  if [ -L "$dst" ]; then
    continue
  fi
  if [ ! -e "$dst" ]; then
    if migrate_is_reference_path "$rel"; then
      migrate_plan_add "write" "$rel" "missing reference file"
    fi
    continue
  fi
  # One dashboard now, run from the starter; a project keeps only its
  # dashboard.toml (a seed, handled below). A dashboard file identical to the
  # starter's goes; a fork — acknowledged or not — is never a shadow and never
  # deleted: it is named, for a person to reconcile into the shared page.
  case "$rel" in
    dashboard/*)
      if harness_render "$TEMPLATE/$rel" 2>/dev/null | cmp -s - "$dst"; then
        migrate_plan_add "remove" "$rel" "identical to the shared file"
      elif histsha="$(migrate_historic_sha "$HERE" "$rel" "$dst" "$histcache")"; then
        migrate_say_older remove "$rel" "$histsha"
      else
        migrate_plan_add "name" "$rel" "a forked dashboard file — there is one dashboard now, the starter's: reconcile this into template/$rel there, then delete it here"
      fi
      continue
      ;;
  esac
  # An acknowledged fork stays in place as a shadow, whatever it looks like.
  if harness_in_diverged_list "$diverged_want" "$rel"; then
    migrate_plan_add "keep" "$rel" "acknowledged in harness/diverged.txt"
    continue
  fi
  if harness_is_seed "$rel" || harness_is_overlay "$rel"; then
    migrate_plan_add "keep" "$rel" "seed — installed once, the project owns it"
    continue
  fi
  if harness_is_data "$rel"; then
    migrate_plan_add "keep" "$rel" "project data — the harness never compares it"
    continue
  fi
  case "$rel" in
    .claude/agents/reviewer-*.md)
      migrate_classify_reviewer "$rel"
      continue
      ;;
  esac
  # One list with the force-include loop above: space-padded, so only a whole
  # path matches and never a prefix of one.
  case " $MIGRATE_STUBS " in
    *" $rel "*) migrate_classify_stub "$rel"; continue ;;
  esac
  if [ "$rel" = "scripts/h" ]; then
    harness_render "$TEMPLATE/$rel" > "$rendered"
    if harness_same "$rel" "$rendered" "$dst"; then
      migrate_plan_add "keep" "$rel" "already the finder"
    else
      migrate_plan_add "name" "$rel" "customised — kept; it runs the final link below"
    fi
    continue
  fi
  harness_render "$TEMPLATE/$rel" > "$rendered"
  if harness_same "$rel" "$rendered" "$dst"; then
    migrate_plan_add "remove" "$rel" "identical to the shared file"
  elif histsha="$(migrate_historic_sha "$HERE" "$rel" "$dst" "$histcache")"; then
    migrate_say_older remove "$rel" "$histsha"
  elif harness_is_contract "$rel" "$TEMPLATE/$rel"; then
    migrate_plan_add "name" "$rel" "merge by hand: a project-specific change to a shared script stays as a same-path shadow, anything else moves into AGENTS.local.md or upstream to the starter"
  else
    migrate_plan_add "keep" "$rel" "carries project answers — the harness never converges it"
  fi
done <<< "$files"

# One generated-output dir (.opencode/agent/*.md, .codex/agents/*.toml):
# derived output the reference regenerates. A file matching what the shared
# generator produces goes; anything else is named and kept — migrating must
# never delete what it cannot reproduce. dir/ext locate the outputs, marker
# names the generator in the file. The identical check differs: opencode
# output ships in the template, codex output is generated from the prompt.
migrate_classify_generated() {
  local gendir="$1" ext="$2" marker="$3"
  local gen name rel histsha
  [ -d "$target/$gendir" ] || return 0
  for gen in "$target/$gendir"/*."$ext"; do
    [ -e "$gen" ] || [ -L "$gen" ] || continue
    [ -L "$gen" ] && continue
    name="$(basename "$gen" ".$ext")"
    rel="$gendir/$name.$ext"
    if [ "$gendir" = ".codex/agents" ]; then
      if [ -f "$TEMPLATE/.claude/agents/$name.md" ]; then
        if migrate_codex_expected "$HERE" "$name" "$expected" &&
           cmp -s "$expected" "$gen"; then
          if git -C "$target" check-ignore -q "$rel" 2>/dev/null; then
            continue
          fi
          migrate_plan_add "remove" "$rel" "identical to the shared generated agent"
        elif grep -q "$marker" "$gen" 2>/dev/null; then
          migrate_plan_add "remove" "$rel" "generated from a customised prompt — the final link regenerates it from the shared one"
        else
          migrate_plan_add "keep" "$rel" "own file — no shared counterpart"
        fi
        continue
      fi
    elif [ -f "$TEMPLATE/$rel" ]; then
      if cmp -s "$TEMPLATE/$rel" "$gen"; then
        # Ignored and identical is already correct derived output — the link
        # below regenerates it anyway, so removing it here is churn that a
        # second --apply would repeat instead of reporting nothing to do.
        if git -C "$target" check-ignore -q "$rel" 2>/dev/null; then
          continue
        fi
        migrate_plan_add "remove" "$rel" "identical to the shared file"
      elif histsha="$(migrate_historic_sha "$HERE" "$rel" "$gen" "$histcache")"; then
        # Same pass as above: ignored derived output stays put either way.
        if git -C "$target" check-ignore -q "$rel" 2>/dev/null; then
          continue
        fi
        migrate_say_older remove "$rel" "$histsha"
      elif grep -q "$marker" "$gen" 2>/dev/null; then
        # Generated output carries a do-not-edit header; whatever made it
        # differ lives in its source prompt, which the lift above preserves.
        migrate_plan_add "remove" "$rel" "generated from a customised prompt — the shared agent is linked in its place"
      elif [ -f "$target/.claude/agents/$name.md" ]; then
        migrate_plan_add "keep" "$rel" "own agent output — no shared counterpart"
      else
        migrate_plan_add "keep" "$rel" "own file — no shared counterpart"
      fi
      continue
    fi
    if [ -f "$target/.claude/agents/$name.md" ]; then
      migrate_plan_add "keep" "$rel" "own agent output — no shared counterpart"
    elif grep -q "$marker" "$gen" 2>/dev/null; then
      migrate_plan_add "name" "$rel" "generated, but its source is gone"
    else
      migrate_plan_add "keep" "$rel" "own file — no shared counterpart"
    fi
  done
}

# Generated files the copy carries: derived output the reference regenerates.
# A file matching what the shared generator produces goes; anything else is
# named and kept — migrating must never delete what it cannot reproduce. The
# opencode marker matches both vintages: older generated agents name
# scripts/opencode-agents.py, newer ones scripts/h opencode-agents.
migrate_classify_generated ".opencode/agent" "md" "opencode-agents"
migrate_classify_generated ".codex/agents" "toml" "scripts/codex-support.py"

# Own files under managed dirs: entries the template has no counterpart for.
# Reported so the dry run names them; never touched either way.
for owndir in .claude/skills .claude/agents; do
  if [ -d "$target/$owndir" ]; then
    while IFS= read -r found; do
      [ -n "$found" ] || continue
      # Links belong to the linker; only real files are owned.
      [ -L "$target/$found" ] && continue
      [ -e "$TEMPLATE/$found" ] && continue
      migrate_plan_add "keep" "$found" "own file — no shared counterpart"
    done <<EOF
$(cd "$target/$owndir" && find . -type f | sed 's|^\./||' | sed "s|^|$owndir/|")
EOF
  fi
done

# A shared skill whose every file goes leaves an empty dir behind, and an
# empty real dir blocks `h link` from symlinking the shared one over it —
# link_entry never replaces a real project file. Those dirs go too.
for entry in "$TEMPLATE"/.claude/skills/*; do
  [ -e "$entry" ] || [ -L "$entry" ] || continue
  [ -d "$entry" ] || continue
  name="$(basename "$entry")"
  dir="$target/.claude/skills/$name"
  [ -d "$dir" ] && [ ! -L "$dir" ] || continue
  members="$(cd "$dir" && find . | sort)" || continue
  [ "$members" = "." ] && continue
  empties=1
  while IFS= read -r member; do
    [ "$member" = "." ] && continue
    member="${member#./}"
    # A stray link vetoes: the linker leaves real entries alone, so a dir
    # that only looks empty still blocks the shared link.
    if [ -L "$dir/$member" ]; then
      empties=0
      break
    fi
    if [ -d "$dir/$member" ]; then
      continue
    fi
    if ! grep -qF "remove|.claude/skills/$name/$member|" "$plan"; then
      empties=0
      break
    fi
  done <<< "$members"
  if [ "$empties" -eq 1 ]; then
    migrate_plan_add "rmdir" ".claude/skills/$name" "emptied shared skill dir"
  fi
done

migrate_print_plan() {
  while IFS='|' read -r fate rel extra; do
    case "$fate" in
      remove) printf '  remove  %s — %s\n' "$rel" "$extra" ;;
      lift)
        overlay="${extra%%|*}"
        count="${extra##*|}"
        if [ "$count" -gt 0 ]; then
          printf '  lift    %s -> %s (%s project line(s))\n' "$rel" "$overlay" "$count"
        else
          printf '  lift    %s — adds nothing over the shared prompt; prompt goes, no overlay\n' "$rel"
        fi
        ;;
      keep) printf '  keep    %s — %s\n' "$rel" "$extra" ;;
      name) printf '  name    %s — differs from the shared file; left in place. %s\n' "$rel" "$extra" ;;
      stub) printf '  stub    %s — %s\n' "$rel" "$extra" ;;
      write) printf '  write   %s — missing reference file; installed from the shared harness\n' "$rel" ;;
      rmdir) printf '  rmdir   %s — emptied shared skill dir\n' "$rel" ;;
    esac
  done < "$plan"
}

migrate_tally() {
  grep -c "^$1|" "$plan" || true
}

if [ "$apply" -eq 0 ]; then
  echo "migrate (dry run): $target"
  echo "  against $TEMPLATE"
  echo
  migrate_print_plan
  echo
  echo "migrate: $(migrate_tally remove) to remove, $(migrate_tally lift) to lift, $(migrate_tally stub) to stub, $(migrate_tally write) to install, $(migrate_tally rmdir) emptied dirs to clear, $(migrate_tally keep) to keep, $(migrate_tally name) still needing a hand merge."
  echo "  Dry run — nothing written; re-run with --apply to write."
  exit 0
fi

# Install one reference file from its shared source, through a temp file so
# a failing read never leaves a 0-byte destination behind. Same modes as
# `add`: 0644, executable when the source is.
migrate_install_ref() {
  local rel="$1" src="$2" dst="$3" tmp
  mkdir -p "$(dirname "$dst")" || { echo "✗ cannot create $(dirname "$dst")" >&2; return 1; }
  tmp="$(mktemp "$target/.harness-migrate-XXXXXX")" || return 1
  if harness_render "$src" > "$tmp"; then
    chmod 644 "$tmp"
    mv "$tmp" "$dst"
  else
    rm -f "$tmp"
    echo "✗ cannot read $src — fix permissions and re-run." >&2
    return 1
  fi
  [ -x "$src" ] && chmod +x "$dst"
  return 0
}

echo "migrate: $target"
echo "  against $TEMPLATE"
echo
while IFS='|' read -r fate rel extra; do
  # Belt and braces for the plan's own guard: nothing that writes or removes
  # may act on a path that resolves into the shared checkout.
  case "$fate" in
    remove|lift|stub|write|rmdir)
      if migrate_through_link "$rel"; then
        echo "✗ refusing to $fate $rel — it resolves outside $target (a link into the shared harness)" >&2
        exit 1
      fi
      ;;
  esac
  case "$fate" in
    remove)
      rm -f "$target/$rel" || { echo "✗ cannot remove $target/$rel" >&2; exit 1; }
      printf '  remove  %s — %s\n' "$rel" "$extra"
      ;;
    lift)
      overlay="${extra%%|*}"
      count="${extra##*|}"
      if [ "$count" -gt 0 ]; then
        migrate_lift "$target/$rel" "$TEMPLATE/$rel" "$target/$overlay" "$rel" write >/dev/null ||
          { echo "✗ cannot lift $rel into $overlay" >&2; exit 1; }
        printf '  lift    %s -> %s (%s project line(s))\n' "$rel" "$overlay" "$count"
      else
        printf '  lift    %s — adds nothing over the shared prompt; prompt goes, no overlay\n' "$rel"
      fi
      rm -f "$target/$rel" || { echo "✗ cannot remove $target/$rel" >&2; exit 1; }
      ;;
    stub)
      migrate_install_ref "$rel" "$TEMPLATE/$(harness_reference_src "$rel")" "$target/$rel" ||
        exit 1
      printf '  stub    %s — %s\n' "$rel" "$extra"
      ;;
    write)
      migrate_install_ref "$rel" "$TEMPLATE/$(harness_reference_src "$rel")" "$target/$rel" ||
        exit 1
      printf '  write   %s — missing reference file; installed from the shared harness\n' "$rel"
      ;;
    rmdir)
      # Nested empties first: a skill dir left with only empty subdirs is
      # still empty for linking purposes, and any real dir blocks link_entry
      # from symlinking the shared one over it.
      find "$target/$rel" -type d -empty -delete 2>/dev/null || true
      if [ ! -e "$target/$rel" ] || [ -L "$target/$rel" ]; then
        printf '  rmdir   %s — emptied shared skill dir\n' "$rel"
      elif [ -z "$(ls -A "$target/$rel")" ]; then
        rmdir "$target/$rel" || { echo "✗ cannot remove $target/$rel" >&2; exit 1; }
        printf '  rmdir   %s — emptied shared skill dir\n' "$rel"
      else
        printf '  keep    %s — not empty; left alone\n' "$rel"
      fi
      ;;
    keep)
      printf '  keep    %s — %s\n' "$rel" "$extra"
      ;;
    name)
      printf '  name    %s — differs from the shared file; left in place. %s\n' "$rel" "$extra"
      ;;
  esac
done < "$plan"
echo

# What `add` tidies on the way in: bd's blocks and hooks are bd's, never the
# project's, so they converge even on kept files. Never adds entries — a kept
# file that still points at removed scripts is named above, for a hand merge.
migrate_tidy_reference "$target" || {
  echo "✗ couldn't tidy the hook files in $target — check them by hand." >&2
  exit 1
}

# The contract import both tools need: Claude Code auto-loads CLAUDE.md,
# opencode auto-loads AGENTS.md, and the import keeps both loaded in both.
claude_md="$target/CLAUDE.md"
if [ -e "$claude_md" ] && grep -qF '@AGENTS.md' "$claude_md"; then
  :
elif [ -e "$claude_md" ]; then
  { printf '@AGENTS.md\n\n'; cat "$claude_md"; } > "$claude_md.tmp" &&
    mv -f "$claude_md.tmp" "$claude_md" ||
    { echo "✗ cannot update $claude_md" >&2; exit 1; }
  echo "  tidy    CLAUDE.md — prepended the @AGENTS.md import"
else
  printf '@AGENTS.md\n\n# %s\n\nProject-specific standards: architecture, naming, testing, the traps\nthis codebase keeps hitting. The harness contract is in AGENTS.md.\n' \
    "$(basename "$target")" > "$claude_md" ||
    { echo "✗ cannot write $claude_md" >&2; exit 1; }
  echo "  write   CLAUDE.md — created with the @AGENTS.md import"
fi

# Derived Codex output is gitignored in a reference install, never committed.
migrate_append_ignore "$target" '.codex/agents/' \
  'Codex agents generated from the shared prompts — scripts/h link regenerates them.' || exit 1
migrate_append_ignore "$target" '.claude/launch.json' \
  'The live dashboard port, rewritten on every bind — machine-local.' || exit 1
migrate_append_ignore "$target" 'dashboard/state.json' \
  'The dashboard snapshot, rewritten on every poll — machine-local.' || exit 1
migrate_append_ignore "$target" '.tmp/' \
  'Agent scratch — created here, removed when done, never committed.' || exit 1

# Linked last, after every write above: bd init writes through links into the
# shared checkout, so links must never predate a bd command. This runs none,
# and the link still lands after all of them.
echo "  linking the shared skills"
if ! "$target/scripts/h" link </dev/null; then
  echo "✗ scripts/h link failed in $target — run it yourself and read the error." >&2
  exit 1
fi
# A .gitignore line does not untrack: the copies the links replaced are still
# in the index, and the next commit would record absolute-path symlinks into
# this machine's starter. Untrack exactly what the link areas now ignore —
# never a tracked file the project ignores elsewhere on purpose. The listing
# itself fails loudly: untracking nothing and continuing would commit those
# same absolute-path symlinks.
ignored_list="$(mktemp)" || { echo "✗ mktemp failed" >&2; exit 1; }
trap 'rm -f "$plan" "$rendered" "$expected" "$ignored_list"; rm -rf "$histcache"' EXIT
if ! git -C "$target" ls-files -z -ci --exclude-standard >"$ignored_list"; then
  echo "✗ cannot list the ignored files in $target — run 'git ls-files -ci --exclude-standard' there and re-run." >&2
  exit 1
fi
untracked=0
while IFS= read -r -d '' rel; do
  case "$rel" in
    .claude/skills/*|.claude/agents/*|.agents/skills/*|.opencode/agent/*|.codex/agents/*|harness/stacks/*|.harness-contract.md) ;;
    *) continue ;;
  esac
  git -C "$target" rm -q --cached -- "$rel" ||
    { echo "✗ cannot untrack $rel — run 'git rm --cached $rel' yourself." >&2; exit 1; }
  untracked=$((untracked + 1))
done < "$ignored_list"
[ "$untracked" -gt 0 ] && echo "  untrack $untracked path(s) now linked or derived — the links stay out of git"
echo

n_named="$(migrate_tally name)"
if [ "$(migrate_tally remove)" -eq 0 ] && [ "$(migrate_tally lift)" -eq 0 ] &&
   [ "$(migrate_tally stub)" -eq 0 ] && [ "$(migrate_tally write)" -eq 0 ] && [ "$n_named" -eq 0 ]; then
  echo "migrate: already a reference install — nothing to do."
  exit 0
fi
echo "migrate: $(migrate_tally remove) removed, $(migrate_tally lift) lifted, $(migrate_tally stub) stubbed,"
echo "  $(migrate_tally write) installed, $(migrate_tally keep) kept, $n_named named."
if [ "$n_named" -gt 0 ]; then
  echo "  Merge the named file(s) by hand: keep a project-specific change to a shared script as a same-path shadow; move anything else into AGENTS.local.md or upstream it to the starter."
fi
