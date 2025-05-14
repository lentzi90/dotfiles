# clusterctl shell completion

# Check if clusterctl is installed
if command -v clusterctl >/dev/null 2>&1; then
    # Check if completion file directory exists
    if [ ! -d "${HOME}/.kube" ]; then
        mkdir -p "${HOME}/.kube"
    fi

    # Generate completion script if it doesn't exist
    if [ ! -f "${HOME}/.kube/clusterctl_completion.bash.inc" ]; then
        clusterctl completion bash > "${HOME}/.kube/clusterctl_completion.bash.inc"
    fi

    # Source completion script if it exists
    if [ -f "${HOME}/.kube/clusterctl_completion.bash.inc" ]; then
        source "${HOME}/.kube/clusterctl_completion.bash.inc"
    fi
fi
alias k=clusterctl
complete -F __start_clusterctl k
