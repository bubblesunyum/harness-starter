# What a review is allowed to see. Sourced by scripts/review.sh, which defines
# `_harness_prefix` above this point, so CAPTURES can use it.
#
# This file is the starter's own (a seed): shared packet fixes still arrive in
# the checkout's scripts/review.sh.

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
# bin/* and commands/* are listed by path because the two most important files
# here carry no extension at all — a glob-by-suffix scope leaves the dispatcher
# unreviewable, which is how it kept its path-traversal bug through a full pass.
# The docs are in scope too: in this project the prose is half the product.
SCOPE=('*.py' '*.sh' '*.md' '*.html' '*.json' '*.jsonl' 'bin/*' 'commands/*' 'scripts/hooks/*'
       'template/scripts/harness' 'template/scripts/hooks/*' '.gitignore'
       ':(exclude).beads/*' ':(exclude)dashboard/vendor/*')

# Screenshots the design reviewer looks at. Whatever drives your app should
# write its captures to /tmp with this prefix — the ledger's, resolved above.
CAPTURES="$(_harness_prefix)-*.png"
