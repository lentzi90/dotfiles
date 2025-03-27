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
    echo "ln --symbolic --force $(pwd)/${file} ${HOME}/"
  else
    ln --symbolic --force "$(pwd)/${file}" "${HOME}/"
  fi
done

# Create symbolic links for every file in the common directory to the home directory
for file in $(find common -type f); do
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "ln --symbolic --force $(pwd)/${file} ${HOME}/"
  else
    ln --symbolic --force "$(pwd)/${file}" "${HOME}/"
  fi
done

# Source functions in .bashrc
# Note that .bashrc sources .bash_aliases so we add there to not polute .bashrc

if [[ "${DRY_RUN}" == "true" ]]; then
  echo 'sed -i.bak "/# dotfiles functions Start/,/# dotfiles functions End/d" "${HOME}/.bash_aliases"'
  echo 'echo "# dotfiles functions Start" >> "${HOME}/.bash_aliases"'
else
  touch "${HOME}/.bash_aliases"
  sed -i.bak "/# dotfiles functions Start/,/# dotfiles functions End/d" "${HOME}/.bash_aliases"
  echo "# dotfiles functions Start" >> "${HOME}/.bash_aliases"
fi

for file in $(find functions -type f); do
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "echo source $(pwd)/${file} >> ${HOME}/.bash_aliases"
  else
    echo "source $(pwd)/${file}" >> "${HOME}/.bash_aliases"
  fi
done

if [[ "${DRY_RUN}" == "true" ]]; then
  echo 'echo "# dotfiles functions End" >> "${HOME}/.bash_aliases"'
else
  echo "# dotfiles functions End" >> "${HOME}/.bash_aliases"
fi
