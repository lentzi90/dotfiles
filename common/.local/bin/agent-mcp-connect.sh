#!/bin/bash
# Stdio bridge to an MCP server that runs on the host, outside the nono
# sandbox. Used as the MCP "command" of sandboxed agents (kiro-cli, goose), so
# the credentials the server needs never enter the sandbox.
#
# The servers are started and listen on ${XDG_RUNTIME_DIR}/agent-mcp/<name>.sock
# through the kiro-cli/goose shell functions in functions/agents.sh.
#
# Usage: agent-mcp-connect.sh <name>      (name: github, loki)

set -euo pipefail

name="${1:?Usage: $0 <name>}"
sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/agent-mcp/${name}.sock"

if [[ ! -S "${sock}" ]]; then
  echo "Error: ${sock} does not exist. Start the agent through the kiro-cli/goose shell functions (functions/agents.sh) so the host-side MCP servers are running." >&2
  exit 1
fi

# -N: shut down the socket on stdin EOF so the host side sees the client leave.
exec nc -N -U "${sock}"
