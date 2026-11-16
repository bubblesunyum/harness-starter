# Your project's gate steps: build, test, smoke — whatever proves the work.
# Sourced by scripts/verify.sh, which defines `step`, `probe_step`,
# `drain_probes`, `mode`, `LOGS`, and the pass/fail footer around this file,
# so use those rather than redefining them.
#
# This file is yours (a seed): `harness add` installs it once and never touches
# it again, and shared scaffolding fixes still arrive in the checkout's
# scripts/verify.sh with the starter. Keep every check going through `step
# <name> <cmd...>`: it swallows the log and prints one line, which is the whole
# point of the gate. A check too slow for every few minutes — throwaway-repo
# probes, heavy suites — goes through `probe_step` instead: same contract,
# but skipped in the --quick lane, which is what keeps iteration fast.

# Replace these with your project's real commands. `step <name> <cmd...>` runs
# it, logs it, and prints one line. A check that needs a throwaway repo uses
# `probe_step` instead — same contract, skipped in the --quick lane.
# Nothing else in this file needs to change.

step "build" false  # e.g. cargo build / npm run build / xcodebuild ... build

probe_step "tests" false # e.g. cargo test / npm test / pytest -q — skipped in
                         # the --quick lane with the throwaway-repo probes

# Test counts are the one detail worth surfacing on success — "ok" alone
# can't distinguish a green suite from a suite that ran nothing. Point this
# grep at whatever your runner prints.
# Probe bodies run in the background, so their logs are only valid after a
# drain — without one this grep reads the previous run's log (or a torn
# empty one). A serial `step` also drains, so any later serial step is an
# equivalent barrier.
drain_probes
# In the --quick lane probe_step writes no log (skips print as skips above),
# so there is no count to print there.
if [ "$mode" != "--quick" ] && [ -f "$LOGS/tests.log" ]; then
  grep -oE "[0-9]+ (passed|tests?)[^.]*" "$LOGS/tests.log" | tail -1 | sed -e 's/^/        /'
fi

if [ "$mode" = "--full" ]; then
  # Anything slow, or anything needing a GUI session: a second platform's
  # build, an integration suite, a smoke check that launches the app and
  # asserts it came up. Delete this block if the project has none.
  :
fi
