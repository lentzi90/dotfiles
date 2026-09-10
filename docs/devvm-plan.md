# Dev VM Plan

A lightweight CLI for spinning up development VMs on OpenStack, provisioned
with the same Ansible playbook used for workstation setup.

## Motivation

The current development workflow uses DevPod to create devcontainers (locally
via Docker or remotely on OpenStack VMs). This works well, but sometimes a bare
VM is more appropriate than a devcontainer — for example when testing with kind
clusters, running heavier workloads, or when the devcontainer abstraction gets
in the way.

Creating VMs manually with `openstack` CLI is tedious: create the server, wait
for it, find the IP, configure SSH with jumphost, install tools, set up
dotfiles, configure agent forwarding... The `devvm` tool automates all of this.

## Design Principles

1. **Single provisioning system.** The workstation Ansible playbook is the
   single source of truth for tool installation. No duplicate scripts.
2. **Transparent.** Shell functions wrapping `openstack` CLI and
   `ansible-playbook`. Easy to debug and customise.
3. **Reuse existing building blocks.** SSH config helpers, dotfiles setup,
   Ansible roles — all already exist.
4. **Complementary to DevPod.** The `devpod-provider-openstack` still works
   for devcontainer-in-VM. `devvm` is for bare VMs.

## Architecture

```text
┌──────────────────────────────────────────────────────┐
│ dotfiles/functions/devvm.sh                          │
│                                                      │
│  devvm create ──► openstack server create            │
│                   wait for SSH                       │
│                   inject SSH config (+ forwarding)   │
│                   ansible-playbook (workstation/)    │
│                   dotfiles setup.sh                  │
│                                                      │
│  devvm delete ──► openstack server delete            │
│                   volume cleanup                     │
│                   remove SSH config                  │
│                                                      │
│  devvm list/ssh/status/provision                     │
└──────────────────────────────────────────────────────┘
         │                          │
         ▼                          ▼
┌─────────────────┐    ┌────────────────────────┐
│ OpenStack CLI   │    │ workstation/ (Ansible)  │
│ (VM lifecycle)  │    │ (tool provisioning)     │
└─────────────────┘    └────────────────────────┘
```

## Components

### 1. `dotfiles/functions/devvm.sh` — CLI entry point (new)

Shell functions sourced in `.bashrc` alongside the other function files.

#### Commands

| Command | Description |
|---------|-------------|
| `devvm create <name> [options]` | Create VM, provision it, configure SSH |
| `devvm delete <name>` | Delete VM, clean up volumes and SSH config |
| `devvm list` | List dev VMs |
| `devvm ssh <name>` | SSH into the VM |
| `devvm status <name>` | Show VM status |
| `devvm provision <name>` | Re-run Ansible + dotfiles on existing VM |

#### Options for `devvm create`

| Option | Default | Description |
|--------|---------|-------------|
| `--flavor` | `c4m16-est` | OpenStack flavor |
| `--image` | `Ubuntu-24.04` | OpenStack image |
| `--volume-size` | (none) | Boot volume size in GB; if omitted, no volume |

#### Configuration (environment variables)

All defaults match the existing devpod OpenStack provider configuration in
`dotfiles/work/.devpod/config.yaml`.

| Variable | Default | Description |
|----------|---------|-------------|
| `DEVVM_OS_CLOUD` | `xerces-dev` | OpenStack cloud from `clouds.yaml` |
| `DEVVM_NETWORK` | `c259b545-d683-4925-becd-860a9286ce1d` | Network ID |
| `DEVVM_KEY_PAIR` | `lennart-ed25519` | SSH key pair name |
| `DEVVM_FLAVOR` | `c4m16-est` | Default flavor |
| `DEVVM_IMAGE` | `Ubuntu-24.04` | Default image |
| `DEVVM_JUMPHOST` | `xerces-dev` | SSH jump host |
| `DEVVM_SSH_USER` | `ubuntu` | SSH user on the VM |
| `DEVVM_PERSONA` | `work` | Dotfiles persona |
| `DEVVM_DOTFILES_REPO` | `git@github.com:lentzi90/dotfiles.git` | Dotfiles repository |
| `WORKSTATION_REPO_PATH` | `${HOME}/workspace/workstation` | Path to workstation repo |

#### `devvm create` flow

1. **Create OpenStack VM**
   ```bash
   openstack server create \
     --image "${DEVVM_IMAGE}" \
     --flavor "${DEVVM_FLAVOR}" \
     --network "${DEVVM_NETWORK}" \
     --key-name "${DEVVM_KEY_PAIR}" \
     --security-group default \
     --wait "${name}"
   ```
   If `--volume-size` is specified, add `--boot-from-volume "${volume_size}"`.

2. **Get IP address**
   ```bash
   ip=$(openstack server show "${name}" -f json | \
     jq -r '.addresses | to_entries[0].value[0].addr')
   ```

3. **Write SSH config** with jumphost, SSH agent forwarding, and GPG agent
   forwarding (see [SSH Config](#ssh-config-with-agent-forwarding) below).

4. **Wait for SSH** to be ready (poll with `ssh -o ConnectTimeout=5`).

5. **Provision with Ansible** — run the workstation playbook targeting the
   VM over SSH (see [Ansible Provisioning](#ansible-provisioning) below).

6. **Install dotfiles** on the VM:
   ```bash
   ssh "${name}" "git clone ${DEVVM_DOTFILES_REPO} ~/dotfiles && \
     cd ~/dotfiles && PERSONA=${DEVVM_PERSONA} ./setup.sh"
   ```

7. **Print summary** with connection info.

#### `devvm delete` flow

1. Capture attached volume IDs (if any).
2. `openstack server delete "${name}" --wait`
3. Delete associated volumes.
4. Remove SSH config entry (sed on `~/.ssh/config`).

#### `devvm provision` flow

This runs steps 5 and 6 from the create flow on an existing VM. Useful for
re-provisioning after updating the workstation playbook or dotfiles.

### 2. `workstation/` — Ansible adjustments (minimal)

The existing Ansible playbook already supports the VM use case through its tag
system. Two small improvements make it more robust:

#### Tag `facts` role with `always`

The `facts` role sets the `arch` variable used by nearly all download tasks.
If a user forgets to include `--tags facts`, downloads silently fail or produce
wrong URLs. Adding the `always` tag makes it impossible to forget.

**Change in `setup.yml`:**
```yaml
- hosts: all
  roles:
  - role: facts
    tags: [facts, always]    # add 'always'
  - role: base
    tags: [base]
  - role: workstation
    tags: [workstation]
```

#### Add `desktop` tag to desktop-only tasks

Makes it explicit which tasks are desktop-specific. Allows both whitelisting
(`--tags "base,docker,binaries"`) and blacklisting
(`--skip-tags desktop`) approaches.

**Changes in `roles/workstation/tasks/main.yml`:**

Add `desktop` tag to:
- "Install workstation packages" (flatpak, virtualbox, qemu, etc.)
- `flatpaks.yml` import
- `appimages.yml` import
- `chrome_fedora.yml` import
- `chrome_ubuntu.yml` import
- `extra_flatpaks.yml` import
- Silverblue-specific package installation

These tasks already have their own tags (e.g. `flatpaks`, `appimages`). The
`desktop` tag is additive and provides a single knob to skip all of them.

#### Why the existing tags already work

When running with `--tags "base,docker,golang,binaries"`:

| Task | Tags | Runs? |
|------|------|-------|
| `facts` role | `always` (after change) | ✅ |
| `base` role | `base` | ✅ |
| "Install workstation packages" | `workstation` (inherited), `desktop` | ❌ skipped |
| `docker.yml` | `workstation`, `docker` | ✅ |
| `golang.yml` | `workstation`, `golang`, `binaries` | ✅ |
| `kubectl.yml` | `workstation`, `binaries`, `kubectl` | ✅ |
| `kind.yml` | `workstation`, `binaries`, `kind` | ✅ |
| `helm.yml` | `workstation`, `binaries`, `helm` | ✅ |
| (all other binary tools) | `workstation`, `binaries`, ... | ✅ |
| `flatpaks.yml` | `workstation`, `flatpaks`, `desktop` | ❌ skipped |
| `appimages.yml` | `workstation`, `appimages`, `desktop` | ❌ skipped |

### 3. SSH config with agent forwarding

The `devvm` functions write SSH config entries with a richer format than
`inject_ssh_config` (which only handles HostName, User, ProxyJump). A
dedicated `devvm_inject_ssh_config` function generates entries like:

```text
# devvm Start myvm
Host myvm
  HostName 10.x.x.x
  User ubuntu
  ProxyJump xerces-dev
  ForwardAgent yes
  StreamLocalBindUnlink yes
  RemoteForward /run/user/1000/gnupg/S.gpg-agent /run/user/1000/gnupg/S.gpg-agent.extra
# devvm End myvm
```

This provides:
- **SSH agent forwarding** (`ForwardAgent yes`) — git clone/push works.
- **GPG agent forwarding** (`RemoteForward`) — commit signing works.
- **Jumphost** (`ProxyJump`) — transparent access to VMs on private networks.

The marker comments (`# devvm Start/End`) follow the same pattern as
`inject_ssh_config` and enable reliable cleanup on `devvm delete`.

### 4. No cloud-init needed

Ubuntu 24.04 cloud images ship with:
- Python 3 (required by Ansible) ✅
- SSH server ✅
- Passwordless sudo for the `ubuntu` user ✅

Ansible connects over SSH and handles all provisioning. No separate bootstrap
step or cloud-init userdata is required.

### 5. Ansible provisioning details

The `devvm` tool runs Ansible from the **local machine** targeting the remote
VM over SSH. This avoids installing Ansible on the VM itself.

```bash
"${WORKSTATION_REPO_PATH}/.venv/bin/ansible-playbook" \
  "${WORKSTATION_REPO_PATH}/setup.yml" \
  -i "${name}," \
  -e "ansible_user=${DEVVM_SSH_USER}" \
  --tags "base,docker,golang,binaries"
```

Key points:
- `-i "${name},"` — ad-hoc inventory with a single host (trailing comma is
  required by Ansible for single-host inventory strings).
- The SSH connection works because `devvm create` already added the host to
  `~/.ssh/config` with the correct jumphost and user.
- `become: true` in the tasks works because Ubuntu cloud images have
  passwordless sudo.
- The Ansible venv must exist at `${WORKSTATION_REPO_PATH}/.venv/`. The
  `devvm` function should check for this and advise running
  `workstation_venv setup` if missing.

### 6. Zed integration

After `devvm create`, the VM is immediately available as an SSH host in
`~/.ssh/config`. Zed can connect to it via its remote SSH feature — no
additional configuration needed beyond what's already in the SSH config.

For convenience, a `devvm_zed_config` helper could generate a JSON snippet
for `settings.json`:

```json
{
  "host": "myvm",
  "args": [],
  "projects": [
    { "paths": ["/home/ubuntu"] }
  ]
}
```

This is a nice-to-have and can be added later.

## End-to-end workflow

```bash
# Create a dev VM — fully provisioned in ~5-8 minutes
devvm create my-test-vm

# SSH in (jumphost transparent, agents forwarded)
devvm ssh my-test-vm

# Inside the VM: git, docker, go, kubectl, kind, helm, clusterctl,
# k9s, tilt, gh, yamlfmt, yq, fzf... all installed.
# Dotfiles applied. Git signing works.

# Connect from Zed: Remote → my-test-vm
# (already in ~/.ssh/config)

# Re-provision after workstation playbook changes
devvm provision my-test-vm

# List VMs
devvm list

# Done — tear down
devvm delete my-test-vm
```

## Comparison with existing approaches

| Aspect | devpod + OpenStack | devvm (this plan) |
|--------|-------------------|-------------------|
| VM creation | ✅ | ✅ |
| Tool installation | Devcontainer features (in container) | Ansible (on VM directly) |
| Provisioning maintenance | Separate from workstation | Same playbook as workstation |
| Dotfiles | ✅ Built-in | ✅ Via SSH after boot |
| GPG forwarding | ✅ DevPod agent | ✅ SSH RemoteForward |
| SSH forwarding | ✅ DevPod agent | ✅ SSH ForwardAgent |
| Docker | Nested (container in Docker in VM) | Native on VM |
| kind clusters | Nested, slower | Native, better performance |
| Inactivity shutdown | ✅ 5 min timeout | ❌ Manual (could add later) |
| Complexity | Opaque (devpod agent) | Transparent (shell + Ansible) |

## Implementation steps

| Step | Effort | Description |
|------|--------|-------------|
| 1 | 15 min | `workstation/setup.yml` — add `always` to facts role tag |
| 2 | 15 min | `workstation/roles/workstation/tasks/main.yml` — add `desktop` tag |
| 3 | 2–3 hr | `dotfiles/functions/devvm.sh` — full implementation |
| 4 | 30 min | Test: create a VM, verify Ansible provisions correctly |
| 5 | 30 min | Test: GPG forwarding, commit signing |
| 6 | 15 min | Documentation in workstation README and dotfiles README |

## Known issues and considerations

### GitHub API rate limits

The `github_release.yml` Ansible tasks query the GitHub API from the target
host. Without a `github_token`, the limit is 60 requests/hour. With ~20
tools, a single run is fine, but repeated provisioning may hit limits. Pass
`-e github_token=$GITHUB_TOKEN` to Ansible if needed.

### GPG socket forwarding through jumphost

`RemoteForward` for Unix sockets through `ProxyJump` should work but needs
testing. The socket paths assume UID 1000 on both ends (local user and
`ubuntu` on the VM). If unreliable, alternatives include:
- A GPG wrapper script on the VM that communicates back over SSH
- Copying the GPG key to the VM instead of forwarding

### Ansible venv dependency

`devvm provision` requires the Ansible venv at
`${WORKSTATION_REPO_PATH}/.venv/`. The function should check for this and
run `workstation_venv setup` or print a helpful error if missing.

### Inactivity timeout (future)

The devpod provider has a 5-minute inactivity timeout with auto-shutdown.
This could be replicated with a cron job or systemd timer on the VM, but
is not in scope for the initial implementation. OpenStack VMs cost resources,
so this is worth adding eventually.

## File locations

| Component | Location | Purpose |
|-----------|----------|---------|
| VM lifecycle + provisioning | `dotfiles/functions/devvm.sh` | Main implementation |
| Tool installation | `workstation/` (Ansible roles) | Single source of truth |
| SSH helpers (existing) | `dotfiles/functions/ssh.sh` | `ssh_once`, `inject_ssh_config`, `remove_ssh_config` |
| Workstation helpers (existing) | `dotfiles/functions/workstation.sh` | `workstation_venv`, `workstation_run` |
| Devcontainer-in-VM (existing) | `devpod-provider-openstack/provider.yaml` | Complementary, unchanged |