# Sibling-script resolution for dispatched runs: the project's copy when it
# shadows this file, else the harness copy.
#
# Sourced, never run. Derives nothing on its own: ROOT (the project) and
# HARNESS (the shared checkout) must already be set by the sourcing script,
# right before the source line. Two directions, one rule: project-first is
# how a project overrides a step, so it is the default — and the gate's own
# hermetic probes (test-*.py) resolve harness-first instead, so a project
# file of the same name can never stand in for them. Never a bare relative
# scripts/<f>: it only resolves when the copy lives here, which a dispatched
# shared copy does not.
harness_script() {
  if [ -f "$ROOT/scripts/$1" ]; then printf '%s' "$ROOT/scripts/$1"
  else printf '%s' "$HARNESS/scripts/$1"; fi
}
harness_shared_script() {
  printf '%s' "$HARNESS/scripts/$1"
}
