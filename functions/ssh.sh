#!/bin/env bash

# ssh without host key checking and without saving to the known_hosts file
ssh_once() {
  ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "$@"
}

inject_ssh_config() {
    if [ "$#" -lt 2 ]; then
        echo "Usage: inject_ssh_config <user@IP> <Host> [jumphost]" >&2
        return 1
    fi

    local user_at_ip="$1"
    local host="$2"
    local jumphost="$3"

    # Ensure the first argument is in user@IP format
    if [[ "${user_at_ip}" != *@* ]]; then
        echo "Error: First argument must be in the format user@IP" >&2
        return 1
    fi

    local user="${user_at_ip%@*}"
    local ip="${user_at_ip#*@}"
    local config_file="${HOME}/.ssh/config"

    # Ensure .ssh directory exists
    if [ ! -d "${HOME}/.ssh" ]; then
        mkdir -p "${HOME}/.ssh"
    fi

    # Create config file if it doesn't exist
    if [ ! -f "${config_file}" ]; then
        touch "${config_file}"
    fi

    echo "Adding SSH configuration for ${host}"
    if grep -q "# inject_ssh_config Start ${host}" "${config_file}"; then
        echo "SSH configuration for ${host} already exists."
        return 1
    fi

    {
        echo "# inject_ssh_config Start ${host}"
        echo "Host ${host}"
        echo "  HostName ${ip}"
        echo "  User ${user}"
    } >> "${config_file}"

    if [ -n "${jumphost}" ]; then
        {
            echo "  ProxyJump ${jumphost}"
        } >> "${config_file}"
    fi

    echo "# inject_ssh_config End ${host}" >> "${config_file}"
}

remove_ssh_config() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: remove_ssh_config <host>" >&2
        return 1
    fi

    local host="$1"
    local config_file="${HOME}/.ssh/config"

    if [ ! -f "${config_file}" ]; then
        echo "SSH config file not found." >&2
        return 1
    fi

    if ! grep -q "# inject_ssh_config Start ${host}" "${config_file}"; then
        echo "SSH configuration for ${host} does not exists."
        return 1
    fi

    sed -i.bak "/# inject_ssh_config Start ${host}/,/# inject_ssh_config End ${host}/d" "${config_file}"
    echo "Removed SSH configuration for ${host}"
    return 0
}
