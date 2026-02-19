#!/bin/bash
# Wrapper script for github-mcp-server that reads the GitHub PAT
# from the gh CLI's credential store.
#
# Requirements:
#   - gh CLI installed and authenticated (gh auth login)
#   - github-mcp-server binary installed
#
# Usage (in Zed settings.json):
#   "context_servers": {
#     "github-mcp": {
#       "command": "github-mcp.sh"
#     }
#   }

set -euo pipefail

if ! command -v gh &>/dev/null; then
  echo "Error: gh CLI is not installed" >&2
  exit 1
fi

if ! command -v github-mcp-server &>/dev/null; then
  echo "Error: github-mcp-server is not installed" >&2
  exit 1
fi

token=$(gh auth token 2>/dev/null) || true
if [[ -z "${token}" ]]; then
  echo "Error: not authenticated with gh. Run: gh auth login" >&2
  exit 1
fi

export GITHUB_PERSONAL_ACCESS_TOKEN="${token}"
exec github-mcp-server stdio
