#!/bin/bash
# Wrapper script for grafana/loki-mcp (https://github.com/grafana/loki-mcp).
#
# Installing the server:
#   The repo moved to grafana/ but still declares the original module path,
#   and the binary lives in ./cmd/server, so it needs renaming after install:
#
#     GOBIN="$(mktemp -d)" go install github.com/scottlepp/loki-mcp/cmd/server@latest
#     mv "${GOBIN}/server" ~/go/bin/loki-mcp-server
#
# Credentials are read from ${HOME}/.config/loki-mcp/env (deliberately outside
# this repo). The env file is a plain shell
# snippet:
#
#     LOKI_URL=https://grafana.example.com/api/datasources/proxy/uid/<datasource-uid>
#     LOKI_USERNAME=<username>
#     LOKI_PASSWORD=<password>

set -euo pipefail

ITEM_NAME="Grafana MCP"
ENV_FILE="${LOKI_MCP_ENV_FILE:-${XDG_CONFIG_HOME:-${HOME}/.config}/loki-mcp/env}"

if ! command -v loki-mcp-server &>/dev/null; then
  echo "Error: loki-mcp-server is not installed (see the header of $0)" >&2
  exit 1
fi

if [[ -r "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi


if [[ -z "${LOKI_URL:-}" ]]; then
  echo "Error: LOKI_URL is not set. Create ${ENV_FILE}" >&2
  exit 1
fi

# The server unconditionally starts an HTTP listener next to the stdio one and
# calls log.Fatalf if the port is taken. Port 0 makes the kernel pick a free
# one so concurrent Zed windows cannot collide.
export PORT="${PORT:-0}"

exec loki-mcp-server
