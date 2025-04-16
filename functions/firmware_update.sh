#!/bin/env bash

# Update firmware
firmware_update() {
  sudo fwupdmgr refresh
  sudo fwupdmgr update
}
