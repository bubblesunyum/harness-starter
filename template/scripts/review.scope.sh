# What a review is allowed to see. Sourced by scripts/review.sh, which defines
# `_harness_prefix` above this point, so CAPTURES can use it.
#
# This file is yours. The harness installs it once and never compares or
# overwrites it — `harness update` stays silent about it, and packet fixes
# still arrive in scripts/review.sh.

# What a review is allowed to see: the app's source, and the harness that builds
# it. Include the harness — it grows enough code of its own to have bugs, and a
# scope that omits it means those never get reviewed. Exclude generated churn: a
# lockfile or project file whose ids got reshuffled, and the ledger export, are
# noise that dilutes the read. Config files are in scope: opencode.json is
# three lines that decide what every session in the project loads, and it went
# through a full review pass invisible because the scope had no *.json.
# Add this project's own source globs. The docs are here from the start: a
# CLAUDE.md or a skill that quietly stopped being true is a defect the reviewers
# should see, and a suffix-only scope is also how a file with no extension at all
# stays unreviewable — list such files by path.
SCOPE=('*.py' '*.sh' '*.md' '*.html' '*.json' 'scripts/hooks/*'
       ':(exclude).beads/*' ':(exclude)dashboard/vendor/*')

# Screenshots the design reviewer looks at. Whatever drives your app should
# write its captures to /tmp with this prefix — the ledger's, resolved above.
CAPTURES="$(_harness_prefix)-*.png"
