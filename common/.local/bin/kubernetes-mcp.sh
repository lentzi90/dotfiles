#!/bin/bash
# Wrapper script for containers/kubernetes-mcp-server
# (https://github.com/containers/kubernetes-mcp-server).
#
# The server is configured to be (as close to) read-only (as possible) through
# ${XDG_CONFIG_HOME:-~/.config}/kubernetes-mcp-server/config.toml (see
# common/.config/kubernetes-mcp-server/config.toml in this repo). That is a
# best-effort guardrail, use a read-only kubeconfig user/context for the real
# boundary.
#
# Requirements:
#   - kubernetes-mcp-server binary installed, either a release binary from
#     https://github.com/containers/kubernetes-mcp-server/releases or
#     go install github.com/containers/kubernetes-mcp-server/cmd/kubernetes-mcp-server@latest
#   - a kubeconfig ($KUBECONFIG or ~/.kube/config)
#
# Usage (in Zed settings.json):
#   "context_servers": {
#     "kubernetes-mcp": {
#       "command": "kubernetes-mcp.sh"
#     }
#   }

set -euo pipefail

CONFIG_FILE="${KUBERNETES_MCP_CONFIG:-${XDG_CONFIG_HOME:-${HOME}/.config}/kubernetes-mcp-server/config.toml}"

if ! command -v kubernetes-mcp-server &>/dev/null; then
  echo "Error: kubernetes-mcp-server is not installed (see the header of $0)" >&2
  exit 1
fi

# Never fall back to the server defaults, they include write tools.
if [[ ! -r "${CONFIG_FILE}" ]]; then
  echo "Error: ${CONFIG_FILE} is not readable. Refusing to start without the read-only configuration (run setup.sh)" >&2
  exit 1
fi

exec kubernetes-mcp-server --config "${CONFIG_FILE}"
