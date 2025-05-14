# Kubectl shell completion
# See https://kubernetes.io/docs/reference/kubectl/cheatsheet/#bash

# Check if kubectl is installed
if command -v kubectl >/dev/null 2>&1; then
    # Check if completion file directory exists
    if [ ! -d "${HOME}/.kube" ]; then
        mkdir -p "${HOME}/.kube"
    fi

    # Generate completion script if it doesn't exist
    if [ ! -f "${HOME}/.kube/completion.bash.inc" ]; then
        kubectl completion bash > "${HOME}/.kube/completion.bash.inc"
    fi

    # Source completion script if it exists
    if [ -f "${HOME}/.kube/completion.bash.inc" ]; then
        source "${HOME}/.kube/completion.bash.inc"
    fi
fi
alias k=kubectl
complete -F __start_kubectl k
