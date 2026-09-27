# Your project's gate steps: build, test, smoke — whatever proves the work.
# Sourced by scripts/verify.sh, which defines `step`, `mode`, `LOGS`, and the
# pass/fail footer around this file, so use those rather than redefining them.
#
# This file is yours. The harness installs it once and never compares or
# overwrites it — `harness update` stays silent about it, and scaffolding fixes
# still arrive in scripts/verify.sh. Keep every check going through `step
# <name> <cmd...>`: it swallows the log and prints one line, which is the whole
# point of the gate.

# Replace these with your project's real commands. `step <name> <cmd...>` runs
# it, logs it, and prints one line. Nothing else in this file needs to change.

step "build" false   # e.g. cargo build / npm run build / xcodebuild ... build

if [ "$mode" != "--quick" ]; then
  step "tests" false # e.g. cargo test / npm test / pytest -q

  # Test counts are the one detail worth surfacing on success — "ok" alone
  # can't distinguish a green suite from a suite that ran nothing. Point this
  # grep at whatever your runner prints.
  if [ -f "$LOGS/tests.log" ]; then
    grep -oE "[0-9]+ (passed|tests?)[^.]*" "$LOGS/tests.log" | tail -1 | sed -e 's/^/        /'
  fi
fi

if [ "$mode" = "--full" ]; then
  # Anything slow, or anything needing a GUI session: a second platform's
  # build, an integration suite, a smoke check that launches the app and
  # asserts it came up. Delete this block if the project has none.
  :
fi
