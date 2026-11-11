# Run AI agents inside nono sandboxes, with MCP servers kept on the host.
#
# The MCP servers (github-mcp.sh, loki-mcp.sh) need credentials (gh keyring,
# ~/.config/loki-mcp/env) that the sandboxed agent must not be able to read.
# So they run outside the sandbox, behind Unix sockets in
# ${XDG_RUNTIME_DIR}/agent-mcp/, one server process per connection
# (systemd-socket-activate, inetd style). The sandbox is only granted
# connect() on that directory (filesystem.unix_socket_dir in the nono
# profiles) and the agents' MCP config runs agent-mcp-connect.sh <name>,
# which is just `nc -U` on the socket.
#
# Pid files and logs live in a sibling directory the sandbox has no access to.

_agent_mcp_sock_dir() {
    echo "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/agent-mcp"
}

_agent_mcp_host_dir() {
    echo "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/agent-mcp-host"
}

# _agent_mcp_serve <name> <wrapper-command>
# Start the host-side listener for one MCP server, unless already running.
_agent_mcp_serve() {
    local name=$1 cmd serve sockdir hostdir pidfile sock i
    cmd=$(command -v "$2") || return 0 # server not installed on this machine
    serve=$(command -v agent-mcp-serve.sh) || {
        echo "agent-mcp-serve.sh not found, run setup.sh" >&2
        return 1
    }
    sockdir=$(_agent_mcp_sock_dir)
    hostdir=$(_agent_mcp_host_dir)
    pidfile="${hostdir}/${name}.pid"
    sock="${sockdir}/${name}.sock"

    mkdir -p -m 700 "${sockdir}" "${hostdir}"
    if [[ -f "${pidfile}" ]] && kill -0 "$(<"${pidfile}")" 2>/dev/null && [[ -S "${sock}" ]]; then
        return 0
    fi

    rm -f "${sock}"
    setsid systemd-socket-activate --listen "${sock}" --accept --inetd -- "${serve}" "${cmd}" \
        >"${hostdir}/${name}.log" 2>&1 </dev/null &
    echo $! >"${pidfile}"
    disown

    for i in {1..30}; do
        [[ -S "${sock}" ]] && return 0
        sleep 0.1
    done
    echo "Failed to start host-side MCP server '${name}', see ${hostdir}/${name}.log" >&2
    return 1
}

# agent-mcp-stop: stop the host-side MCP listeners.
agent-mcp-stop() {
    local f
    for f in "$(_agent_mcp_host_dir)"/*.pid; do
        [[ -f "${f}" ]] || continue
        kill "$(<"${f}")" 2>/dev/null
        rm -f "${f}" "$(_agent_mcp_sock_dir)/$(basename "${f%.pid}").sock"
    done
}

# agent-sandbox <nono-profile> <command> [args...]
# Run an agent in the current directory under the given nono profile.
agent-sandbox() {
    local profile=$1
    shift
    _agent_mcp_serve github github-mcp.sh || return
    _agent_mcp_serve loki loki-mcp.sh || return
    nono run --profile "${profile}" --allow-cwd -- "$@"
}

# These intentionally shadow the real binaries so the sandbox cannot be
# forgotten. Use `command kiro-cli` / `command goose` to bypass it.
kiro-cli() { agent-sandbox kiro kiro-cli "$@"; }
goose() { agent-sandbox goose goose "$@"; }
