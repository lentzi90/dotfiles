#!/usr/bin/env bash
# dotfiles_update — pull the latest dotfiles (if safe) and re-run setup.sh
# using the persona that was selected the last time setup.sh ran.
#
# Usage:
#   dotfiles_update
#
# Configuration via environment variables:
#   PERSONA             Persona to use instead of the stored one (default: stored persona)
#   DOTFILES_STATE_FILE Where the last used persona is stored
#                        (default: ~/.config/dotfiles/persona, written by setup.sh)

DOTFILES_STATE_FILE="${DOTFILES_STATE_FILE:-${HOME}/.config/dotfiles/persona}"

# Resolve the real path of the dotfiles repo by following the symlink that
# setup.sh creates for this file in ~/.bashrc.d. This file lives in
# <repo>/functions, so the repo root is one directory up from there.
_dotfiles_repo_path() {
  local source="${BASH_SOURCE[0]}"
  local dir
  while [[ -L "${source}" ]]; do
    dir="$(cd -P "$(dirname "${source}")" && pwd)"
    source="$(readlink "${source}")"
    [[ "${source}" != /* ]] && source="${dir}/${source}"
  done
  dir="$(cd -P "$(dirname "${source}")" && pwd)"
  dirname "${dir}"
}

dotfiles_update() {
  local repo_path
  repo_path="$(_dotfiles_repo_path)"

  if [[ ! -d "${repo_path}/.git" ]]; then
    echo "Could not find dotfiles repository at '${repo_path}'." >&2
    return 1
  fi

  (
    cd "${repo_path}" || exit 1

    if [[ -n $(git status --porcelain) ]]; then
      echo "Working directory not clean! Please commit or discard changes before updating." >&2
      exit 1
    fi

    echo "Updating dotfiles in ${repo_path}..."
    # --ff-only refuses to pull if this would require a merge (e.g. diverged
    # history), so it never leaves the repo in a conflicted state.
    if ! git pull --ff-only; then
      echo "git pull failed (not a fast-forward, or other conflict). Resolve manually and retry." >&2
      exit 1
    fi

    persona="${PERSONA:-}"
    if [[ -z "${persona}" && -f "${DOTFILES_STATE_FILE}" ]]; then
      persona="$(<"${DOTFILES_STATE_FILE}")"
    fi

    if [[ -z "${persona}" ]]; then
      echo "No persona specified and none stored from a previous run." >&2
      echo "Run setup.sh manually once, e.g.: PERSONA=work ./setup.sh" >&2
      exit 1
    fi

    echo "Re-running setup with persona: ${persona}"
    PERSONA="${persona}" ./setup.sh
  )
}
