#!/usr/bin/env bash

PERSONA="${PERSONA:-private}"
DRY_RUN=${DRY_RUN:-false}
if [[ $# -eq 1 ]]; then
  echo "Usage: setup.sh"
  echo "Supports the following environment variables:"
  echo "  PERSONA: The persona to use (default: private, alt. work)"
  echo "  DRY_RUN: If set to true, will not make any changes (default: false)"
  exit 1
fi

echo "Setting up dotfiles using persona: ${PERSONA}"
echo "Dry run mode: ${DRY_RUN}"
echo "Are you sure you want to continue? (y/n)"
read -r answer
if [[ "${answer}" != "y" ]]; then
  echo "Aborting setup."
  exit 1
fi

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

# Fedora used .bashrc.d directory to source files in .bashrc
# Create symbolic links for all files in functions to bashrc.d
mkdir -p "${HOME}/.bashrc.d"
for file in $(find functions -type f); do
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "ln --symbolic --force $(pwd)/${file} ${HOME}/.bashrc.d/"
  else
    ln --symbolic --force "$(pwd)/${file}" "${HOME}/.bashrc.d/"
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

# Import the PGP key
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "gpg --import $(pwd)/public.asc"
else
  gpg --import "$(pwd)/public.asc"
fi
