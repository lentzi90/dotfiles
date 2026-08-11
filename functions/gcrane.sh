#!/usr/bin/env bash
# gcrane - run google/go-containerregistry's gcrane as a container
# See https://github.com/google/go-containerregistry/blob/main/cmd/gcrane/README.md

gcrane() {
    local runtime=""
    if command -v docker >/dev/null 2>&1; then
        runtime="docker"
    elif command -v podman >/dev/null 2>&1; then
        runtime="podman"
    else
        echo "gcrane: neither docker nor podman found in PATH" >&2
        return 1
    fi

    local tty_flags=()
    if [ -t 0 ] && [ -t 1 ]; then
        tty_flags=(-it)
    fi

    "${runtime}" run --rm "${tty_flags[@]}" \
        -v "${HOME}/.docker:/root/.docker" \
        -v "${HOME}/.config/gcloud:/root/.config/gcloud" \
        gcr.io/go-containerregistry/gcrane "$@"
}
