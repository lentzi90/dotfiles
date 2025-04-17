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

# Function to create links maintaining directory structure
create_links() {
  local source_dir=$1
  
  find "${source_dir}" -type f | while read -r file; do
    # Get the relative path of the file within the source directory
    relative_path=${file#${source_dir}/}
    
    # Create the target directory if it doesn't exist
    target_dir="${HOME}/$(dirname "${relative_path}")"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "mkdir -p \"${target_dir}\""
      echo "ln --symbolic --force \"$(pwd)/${file}\" \"${HOME}/${relative_path}\""
    else
      mkdir -p "${target_dir}"
      ln --symbolic --force "$(pwd)/${file}" "${HOME}/${relative_path}"
    fi
  done
}

# Create symbolic links for files in the PERSONA directory
echo "Setting up files from ${PERSONA} persona..."
create_links "${PERSONA}"

# Create symbolic links for files in the common directory
echo "Setting up files from common..."
create_links "common"

# Fedora uses .bashrc.d directory to source files in .bashrc
# Create symbolic links for all files in functions to bashrc.d
echo "Setting up function files..."
mkdir -p "${HOME}/.bashrc.d"
for file in $(find functions -type f); do
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "ln --symbolic --force \"$(pwd)/${file}\" \"${HOME}/.bashrc.d/\""
  else
    ln --symbolic --force "$(pwd)/${file}" "${HOME}/.bashrc.d/"
  fi
done

# Source functions in .bashrc
# Note that .bashrc sources .bash_aliases so we add there to not pollute .bashrc
echo "Setting up bash aliases..."

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
    echo "echo source \"$(pwd)/${file}\" >> \"${HOME}/.bash_aliases\""
  else
    echo "source \"$(pwd)/${file}\"" >> "${HOME}/.bash_aliases"
  fi
done

if [[ "${DRY_RUN}" == "true" ]]; then
  echo 'echo "# dotfiles functions End" >> "${HOME}/.bash_aliases"'
else
  echo "# dotfiles functions End" >> "${HOME}/.bash_aliases"
fi

# Import the PGP key
echo "Importing PGP key..."
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "gpg --import \"$(pwd)/public.asc\""
else
  gpg --import "$(pwd)/public.asc"
fi
