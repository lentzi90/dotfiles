#!/bin/env bash

# Check if a reboot is needed
needs_restart() {
  if [ -f /var/run/reboot-required ]; then
    echo "Reboot required"
  else
    echo "No reboot required"
  fi
}
