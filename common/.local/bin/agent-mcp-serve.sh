#!/bin/bash
# Run an MCP stdio server and make sure that it terminates when the client
# disconnects (stdin EOF), and that the connection is closed when the server
# exits. Some servers (loki-mcp-server) keep running after stdin is closed,
# which would leak a process per agent session.
#
# Usage: agent-mcp-serve.sh <command> [args...]

set -uo pipefail

fifo=$(mktemp -u "${XDG_RUNTIME_DIR:-/tmp}/agent-mcp-serve.XXXXXX")
mkfifo -m 600 "${fifo}"
server=
pump=
cleanup() {
  kill "${server}" "${pump}" 2>/dev/null
  rm -f "${fifo}"
}
trap cleanup EXIT
trap 'exit 143' TERM INT HUP

"$@" <"${fifo}" &
server=$!
cat <&0 >"${fifo}" &
pump=$!

# Whichever side finishes first ends the session.
wait -n
