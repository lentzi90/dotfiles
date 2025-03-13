#!/usr/bin/env bash

PERSONA="${PERSONA:-private}"
DRY_RUN=${DRY_RUN:-false}
if [[ $# -eq 1 ]]; then
  if [[ "${1}" == "--dry-run" ]]; then
    DRY_RUN=true
  fi
else
  echo "Usage: setup.sh [--dry-run]"
fi

echo "Setting up dotfiles using persona: ${PERSONA}"

# Create symbolic links for every file in the PERSONA directory to the home directory
for file in $(find "${PERSONA}" -type f); do
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "ln --symbolic --force $(pwd)/${file} ${HOME}/$(basename ${file})"
  else
    ln --symbolic --force "$(pwd)/${file}" "${HOME}/"
  fi
done
