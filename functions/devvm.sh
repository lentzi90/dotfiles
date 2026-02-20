#!/usr/bin/env bash
# devvm — manage development VMs on OpenStack
#
# Usage:
#   devvm create <name> [--flavor <flavor>] [--image <image>] [--volume-size <GB>]
#   devvm delete <name>
#   devvm list
#   devvm ssh <name>
#   devvm status <name>
#   devvm provision <name>
#
# Configuration via environment variables (defaults match devpod-provider-openstack):
#   DEVVM_OS_CLOUD      OpenStack cloud name          (override; falls back to OS_CLOUD, then xerces-dev)
#   DEVVM_NETWORK       Network ID                    (default: c259b545-...)
#   DEVVM_KEY_PAIR      SSH key pair name             (default: lennart-ed25519)
#   DEVVM_FLAVOR        Default flavor                (default: c4m16-est)
#   DEVVM_IMAGE         Default image                 (default: Ubuntu-24.04)
#   DEVVM_JUMPHOST      SSH jump host                 (default: xerces-dev)
#   DEVVM_SSH_USER      SSH user on the VM            (default: ubuntu)
#   DEVVM_PERSONA       Dotfiles persona              (default: work)
#   DEVVM_DOTFILES_REPO Dotfiles git repo URL         (default: git@github.com:lentzi90/dotfiles.git)
#   WORKSTATION_REPO_PATH Path to workstation repo    (default: ~/workspace/workstation)

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DEVVM_OS_CLOUD="${DEVVM_OS_CLOUD:-${OS_CLOUD:-xerces-dev}}"
DEVVM_NETWORK="${DEVVM_NETWORK:-c259b545-d683-4925-becd-860a9286ce1d}"
DEVVM_KEY_PAIR="${DEVVM_KEY_PAIR:-lennart-ed25519}"
DEVVM_FLAVOR="${DEVVM_FLAVOR:-c4m16-est}"
DEVVM_IMAGE="${DEVVM_IMAGE:-Ubuntu-24.04}"
DEVVM_JUMPHOST="${DEVVM_JUMPHOST:-xerces-dev}"
DEVVM_SSH_USER="${DEVVM_SSH_USER:-ubuntu}"
DEVVM_PERSONA="${DEVVM_PERSONA:-work}"
DEVVM_DOTFILES_REPO="${DEVVM_DOTFILES_REPO:-git@github.com:lentzi90/dotfiles.git}"
WORKSTATION_REPO_PATH="${WORKSTATION_REPO_PATH:-${HOME}/workspace/workstation}"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_devvm_log() {
    echo "==> $*"
}

_devvm_err() {
    echo "ERROR: $*" >&2
}

# Run openstack CLI with the configured cloud.
_devvm_openstack() {
    OS_CLOUD="${DEVVM_OS_CLOUD}" openstack "$@"
}

# Get the IP address of a server.
_devvm_get_ip() {
    local name="$1"
    _devvm_openstack server show "${name}" -f json | \
        jq -r '.addresses | to_entries[0].value[0]'
}

# Get volume IDs attached to a server (empty string if none).
_devvm_get_volumes() {
    local name="$1"
    _devvm_openstack server show "${name}" -f json | \
        jq -r '.volumes_attached[].id // empty' 2>/dev/null
}

# Write an SSH config block with agent and GPG forwarding.
_devvm_inject_ssh_config() {
    local name="$1"
    local ip="$2"
    local user="${3:-${DEVVM_SSH_USER}}"
    local jumphost="${4:-${DEVVM_JUMPHOST}}"
    local config_file="${HOME}/.ssh/config"

    # Ensure .ssh directory and config file exist.
    mkdir -p "${HOME}/.ssh"
    touch "${config_file}"

    if grep -q "# devvm Start ${name}" "${config_file}"; then
        _devvm_err "SSH config for '${name}' already exists."
        return 1
    fi

    _devvm_log "Adding SSH config for ${name} (${ip})"
    {
        echo "# devvm Start ${name}"
        echo "Host ${name}"
        echo "  HostName ${ip}"
        echo "  User ${user}"
        if [[ -n "${jumphost}" ]]; then
            echo "  ProxyJump ${jumphost}"
        fi
        echo "  ForwardAgent yes"
        echo "  StreamLocalBindUnlink yes"
        echo "  RemoteForward /run/user/1000/gnupg/S.gpg-agent /run/user/1000/gnupg/S.gpg-agent.extra"
        echo "# devvm End ${name}"
    } >> "${config_file}"
}

# Remove the SSH config block for a VM.
_devvm_remove_ssh_config() {
    local name="$1"
    local config_file="${HOME}/.ssh/config"

    if [[ ! -f "${config_file}" ]]; then
        return 0
    fi

    if ! grep -q "# devvm Start ${name}" "${config_file}"; then
        _devvm_log "No SSH config for '${name}' found — nothing to remove."
        return 0
    fi

    sed -i.bak "/# devvm Start ${name}/,/# devvm End ${name}/d" "${config_file}"
    _devvm_log "Removed SSH config for ${name}"
}

# Wait until SSH is reachable on the VM.
_devvm_wait_for_ssh() {
    local name="$1"
    local max_attempts="${2:-30}"
    local attempt=1

    _devvm_log "Waiting for SSH on ${name} ..."
    while [[ ${attempt} -le ${max_attempts} ]]; do
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
               -o BatchMode=yes "${name}" true 2>/dev/null; then
            _devvm_log "SSH is ready."
            return 0
        fi
        printf "  attempt %d/%d\r" "${attempt}" "${max_attempts}"
        attempt=$((attempt + 1))
        sleep 5
    done
    _devvm_err "SSH did not become available after ${max_attempts} attempts."
    return 1
}

# Provision the VM with Ansible.
_devvm_provision_ansible() {
    local name="$1"
    local ansible_playbook="${WORKSTATION_REPO_PATH}/.venv/bin/ansible-playbook"
    local playbook="${WORKSTATION_REPO_PATH}/setup.yml"

    if [[ ! -x "${ansible_playbook}" ]]; then
        _devvm_err "Ansible venv not found at ${WORKSTATION_REPO_PATH}/.venv/"
        _devvm_err "Run: workstation_venv setup"
        return 1
    fi

    if [[ ! -f "${playbook}" ]]; then
        _devvm_err "Playbook not found at ${playbook}"
        _devvm_err "Run: workstation_clone"
        return 1
    fi

    _devvm_log "Provisioning ${name} with Ansible ..."
    "${ansible_playbook}" \
        "${playbook}" \
        -i "${name}," \
        -e "ansible_user=${DEVVM_SSH_USER}" \
        --tags "base,docker,golang,binaries"
}

# Install dotfiles on the VM.
_devvm_install_dotfiles() {
    local name="$1"

    _devvm_log "Installing dotfiles on ${name} ..."
    ssh "${name}" bash -s <<REMOTE
set -euo pipefail
if [[ -d ~/dotfiles ]]; then
    cd ~/dotfiles && git pull
else
    git clone "${DEVVM_DOTFILES_REPO}" ~/dotfiles
fi
cd ~/dotfiles && PERSONA="${DEVVM_PERSONA}" ./setup.sh
REMOTE
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

_devvm_create() {
    local name=""
    local flavor="${DEVVM_FLAVOR}"
    local image="${DEVVM_IMAGE}"
    local volume_size=""

    # --- Parse arguments ---------------------------------------------------
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --flavor)
                flavor="$2"; shift 2 ;;
            --image)
                image="$2"; shift 2 ;;
            --volume-size)
                volume_size="$2"; shift 2 ;;
            -*)
                _devvm_err "Unknown option: $1"
                return 1 ;;
            *)
                if [[ -z "${name}" ]]; then
                    name="$1"; shift
                else
                    _devvm_err "Unexpected argument: $1"
                    return 1
                fi
                ;;
        esac
    done

    if [[ -z "${name}" ]]; then
        _devvm_err "Usage: devvm create <name> [--flavor <f>] [--image <i>] [--volume-size <GB>]"
        return 1
    fi

    # --- Create the OpenStack VM -------------------------------------------
    _devvm_log "Creating VM '${name}' (flavor=${flavor}, image=${image})..."

    local cmd=(_devvm_openstack server create
        --image "${image}"
        --flavor "${flavor}"
        --network "${DEVVM_NETWORK}"
        --key-name "${DEVVM_KEY_PAIR}"
        --security-group default
        --wait
    )

    if [[ -n "${volume_size}" ]]; then
        cmd+=(--boot-from-volume "${volume_size}")
        _devvm_log "Using boot volume: ${volume_size} GB"
    fi

    cmd+=("${name}")

    if ! "${cmd[@]}" >/dev/null; then
        _devvm_err "Failed to create VM '${name}'."
        return 1
    fi

    # --- Get the IP --------------------------------------------------------
    local ip
    ip=$(_devvm_get_ip "${name}")
    if [[ -z "${ip}" || "${ip}" == "null" ]]; then
        _devvm_err "Could not determine IP for '${name}'."
        return 1
    fi
    _devvm_log "VM IP: ${ip}"

    # --- Inject SSH config -------------------------------------------------
    _devvm_inject_ssh_config "${name}" "${ip}" || return 1

    # --- Wait for SSH ------------------------------------------------------
    if ! _devvm_wait_for_ssh "${name}"; then
        _devvm_err "VM created but SSH is not reachable. You may need to debug manually."
        _devvm_err "  openstack server show ${name}"
        return 1
    fi

    # --- Provision with Ansible --------------------------------------------
    if ! _devvm_provision_ansible "${name}"; then
        _devvm_err "Ansible provisioning failed. The VM is still running."
        _devvm_err "Fix the issue and re-run: devvm provision ${name}"
    fi

    # --- Install dotfiles --------------------------------------------------
    if ! _devvm_install_dotfiles "${name}"; then
        _devvm_err "Dotfiles installation failed. The VM is still running."
        _devvm_err "Fix the issue and re-run: devvm provision ${name}"
    fi

    # --- Summary -----------------------------------------------------------
    echo ""
    _devvm_log "VM '${name}' is ready!"
    echo "  SSH:   ssh ${name}"
    echo "  IP:    ${ip}"
    echo "  User:  ${DEVVM_SSH_USER}"
    echo "  Jump:  ${DEVVM_JUMPHOST}"
    echo ""
}

_devvm_delete() {
    local name="$1"

    if [[ -z "${name}" ]]; then
        _devvm_err "Usage: devvm delete <name>"
        return 1
    fi

    # --- Capture volumes before deleting -----------------------------------
    _devvm_log "Looking up VM '${name}' ..."
    local volumes
    volumes=$(_devvm_get_volumes "${name}" 2>/dev/null) || true

    # --- Delete the server -------------------------------------------------
    _devvm_log "Deleting VM '${name}' ..."
    if ! _devvm_openstack server delete "${name}" --wait; then
        _devvm_err "Failed to delete VM '${name}'."
        return 1
    fi
    _devvm_log "VM '${name}' deleted."

    # --- Delete associated volumes -----------------------------------------
    if [[ -n "${volumes}" ]]; then
        _devvm_log "Cleaning up volumes ..."
        local vol
        for vol in ${volumes}; do
            _devvm_log "  Deleting volume ${vol}"
            _devvm_openstack volume delete "${vol}" || \
                _devvm_err "  Failed to delete volume ${vol} — may need manual cleanup."
        done
    fi

    # --- Remove SSH config -------------------------------------------------
    _devvm_remove_ssh_config "${name}"

    # --- Remove from known hosts -------------------------------------------
    # The host was accessed via name (through SSH config), so remove that.
    ssh-keygen -R "${name}" 2>/dev/null || true

    echo ""
    _devvm_log "VM '${name}' fully cleaned up."
}

# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------

devvm() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "${cmd}" in
        create)
            _devvm_create "$@"
            ;;
        delete)
            _devvm_delete "$@"
            ;;
        list)
            _devvm_err "Not yet implemented."
            return 1
            ;;
        ssh)
            _devvm_err "Not yet implemented."
            return 1
            ;;
        status)
            _devvm_err "Not yet implemented."
            return 1
            ;;
        provision)
            _devvm_err "Not yet implemented."
            return 1
            ;;
        help|--help|-h|*)
            echo "Usage: devvm <command> [args]"
            echo ""
            echo "Commands:"
            echo "  create <name> [options]   Create and provision a dev VM"
            echo "  delete <name>             Delete a dev VM and clean up"
            echo "  list                      List dev VMs (not yet implemented)"
            echo "  ssh <name>                SSH into a dev VM (not yet implemented)"
            echo "  status <name>             Show VM status (not yet implemented)"
            echo "  provision <name>          Re-provision a VM (not yet implemented)"
            echo ""
            echo "Options for create:"
            echo "  --flavor <flavor>         OpenStack flavor (default: ${DEVVM_FLAVOR})"
            echo "  --image <image>           OpenStack image (default: ${DEVVM_IMAGE})"
            echo "  --volume-size <GB>        Boot volume size; omit for ephemeral disk"
            echo ""
            echo "Environment variables:"
            echo "  DEVVM_OS_CLOUD            OpenStack cloud override (current: ${DEVVM_OS_CLOUD})"
            echo "  OS_CLOUD                  Standard OpenStack cloud variable (fallback if DEVVM_OS_CLOUD is unset)"
            echo "  DEVVM_NETWORK             Network ID (default: ${DEVVM_NETWORK})"
            echo "  DEVVM_KEY_PAIR            SSH key pair (default: ${DEVVM_KEY_PAIR})"
            echo "  DEVVM_FLAVOR              Default flavor (default: ${DEVVM_FLAVOR})"
            echo "  DEVVM_IMAGE               Default image (default: ${DEVVM_IMAGE})"
            echo "  DEVVM_JUMPHOST            SSH jumphost (default: ${DEVVM_JUMPHOST})"
            echo "  DEVVM_SSH_USER            SSH user (default: ${DEVVM_SSH_USER})"
            echo "  DEVVM_PERSONA             Dotfiles persona (default: ${DEVVM_PERSONA})"
            echo "  WORKSTATION_REPO_PATH     Workstation repo (default: ${WORKSTATION_REPO_PATH})"
            ;;
    esac
}
