#!/bin/bash
# Installs the harness into a project.
#
#   ./install.sh <target-repo> [--name "<project name>"] [--prefix <p>] [--seat <name>]
#
# Copies the template in, substitutes the placeholders, wires the commit-msg
# hook, and initialises the ledger. Never overwrites a file that already exists
# in the target — it prints what it skipped, so a re-run is a safe way to pick
# up pieces added since.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$HERE/template"

target=""; name=""; prefix=""; seat=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name)   name="$2";   shift 2 ;;
    --prefix) prefix="$2"; shift 2 ;;
    --seat)   seat="$2";   shift 2 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) target="$1"; shift ;;
  esac
done

[ -n "$target" ] || { echo "usage: ./install.sh <target-repo> [--name …] [--prefix …] [--seat …]" >&2; exit 1; }
target="$(cd "$target" && pwd)"
[ -d "$target/.git" ] || { echo "✗ $target is not a git repository — the commit-msg hook and the review packet both need one." >&2; exit 1; }

# Defaults derived from the target, so the common case needs no flags. The
# prefix has to be short: it prefixes every bead id you will ever type.
name="${name:-$(basename "$target")}"
prefix="${prefix:-$(basename "$target" | tr -cd '[:alnum:]' | tr 'A-Z' 'a-z' | cut -c1-3)}"
seat="${seat:-$(basename "$target")}"

echo "installing the harness into $target"
echo "  project: $name"
echo "  prefix:  $prefix-"
echo "  seat:    $seat"
echo

copied=0; skipped=0
while IFS= read -r src; do
  rel="${src#$TEMPLATE/}"
  dst="$target/$rel"
  if [ -e "$dst" ]; then
    echo "  skip  $rel (already there)"
    skipped=$((skipped + 1))
    continue
  fi
  mkdir -p "$(dirname "$dst")"
  # Binaries and vendored assets are copied whole; only text gets substituted.
  case "$rel" in
    dashboard/vendor/*) cp "$src" "$dst" ;;
    *) sed -e "s/{{PROJECT}}/$name/g" \
           -e "s/{{PREFIX_UPPER}}/$(echo "$prefix" | tr 'a-z' 'A-Z')/g" \
           -e "s/{{PREFIX}}/$prefix/g" \
           -e "s/{{SEAT}}/$seat/g" "$src" > "$dst" ;;
  esac
  [ -x "$src" ] && chmod +x "$dst"
  echo "  add   $rel"
  copied=$((copied + 1))
done < <(find "$TEMPLATE" -type f | sort)

echo
echo "  $copied added, $skipped skipped"
echo

# The hook lives in scripts/ and is pointed at, rather than copied into
# .git/hooks — beads rewrites that directory on upgrade and would eat it.
hook="$target/.git/hooks/commit-msg"
if [ -e "$hook" ]; then
  echo "  ! $target/.git/hooks/commit-msg exists — add this line to it yourself:"
  echo "      exec \"\$(git rev-parse --show-toplevel)\"/scripts/hooks/commit-msg \"\$@\""
else
  printf '#!/bin/bash\nexec "$(git rev-parse --show-toplevel)"/scripts/hooks/commit-msg "$@"\n' > "$hook"
  chmod +x "$hook"
  echo "  wired the commit-msg hook"
fi

if command -v bd >/dev/null 2>&1; then
  if [ -d "$target/.beads" ]; then
    echo "  ledger already initialised"
  else
    (cd "$target" && bd init --prefix "$prefix") && echo "  initialised the ledger ($prefix-)"
  fi
else
  echo "  ! bd is not installed — the ledger, the brief, and the commit hook all need it."
  echo "    See https://github.com/steveyegge/beads"
fi

(cd "$target" && ./scripts/context.py bless >/dev/null 2>&1) && echo "  blessed the doc hashes" || true

cat <<EOF

done. Four things are yours to fill in before this is really running:

  1. CLAUDE.snippet.md      paste its three sections into your CLAUDE.md, delete it
  2. scripts/verify.sh      the PROJECT STEPS block — your build and test commands
  3. harness/seat.md        who the seat is and what it's for
  4. the reviewers          .claude/agents/reviewer-{taste,correctness,design}.md
                            each has a FILL THIS IN block for this project's
                            language, framework, and actual recurring bugs

Then: scripts/verify.sh, and open localhost:7391.
EOF
