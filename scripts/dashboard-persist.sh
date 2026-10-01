#!/bin/bash
# dashboard-persist.sh — start the dashboard so it stays up after the session.
#
# Usage: dashboard-persist.sh [--port N]
#
# The SessionEnd hook runs `dashboard.py down` and the server times itself out
# when idle; this launcher opts out of both by starting the server with
# DASHBOARD_PERSIST=1. An already-serving board is taken over first: a plain
# `down` stops a hook-started one (a persistent survivor is left alone), so
# the board left behind is always persistent. No nohup here: `up` already
# spawns the server in a session of its own, which is what outlives the hook.
# Stop it explicitly when you are done with it:
#
#   scripts/dashboard.py down --force
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
port=""
if [ $# -eq 2 ] && [ "${1:-}" = "--port" ]; then
  port="$2"
elif [ $# -ne 0 ]; then
  echo "usage: dashboard-persist.sh [--port N]" >&2
  exit 1
fi

# Take over a hook-started board, if there is one. A persistent board
# survives this and is reported as such below.
python3 "$here/dashboard.py" down
if [ -n "$port" ]; then
  out=$(DASHBOARD_PERSIST=1 python3 "$here/dashboard.py" up --port "$port" 2>&1)
else
  out=$(DASHBOARD_PERSIST=1 python3 "$here/dashboard.py" up 2>&1)
fi
echo "$out"
case "$out" in
  *started*|*already\ serving*)
    echo "stop it with: scripts/dashboard.py down --force"
    ;;
  *)
    exit 1
    ;;
esac
