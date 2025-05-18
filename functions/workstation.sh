# functions for handling the workstation repo

WORKSTATION_REPO_PATH="${HOME}/workspace/workstation"

workstation_clone() {
    git clone git@github.com:lentzi90/workstation.git "${WORKSTATION_REPO_PATH}"
}

workstation_sync() {
    cd "${WORKSTATION_REPO_PATH}"
    if [[ -z $(git status --porcelain) ]]; then
        git checkout main
        git pull
    else
        echo "Working directory not clean! Please commit or discard changes."
        return 1
    fi
}

workstation_venv() {
    cd "${WORKSTATION_REPO_PATH}"
    if [ "$1" = "clean" ]; then
        rm -rf .venv
        return
    elif [ "$1" = "setup" ]; then
        : # Do nothing, fall through
    elif [ "$1" = "activate" ]; then
        source .venv/bin/activate
        return
    else
        echo "Please specify 'clean', 'setup' or 'activate'"
        return 1
    fi
    python -m venv .venv
    source .venv/bin/activate
    pip install ansible jmespath

    ansible-galaxy collection install community.general
}

workstation_run() {
    if ! workstation_sync; then
        return 1
    fi
    workstation_venv activate
    ansible-playbook setup.yml -K "$@"
}
