#!/bin/zsh
# Build, install and launch on the paired iPad.
#
#   ./scripts/iPad.sh setup       record the paired iPad in .device
#   ./scripts/iPad.sh             build, install, launch
#   ./scripts/iPad.sh no-launch   build and install only, leave the iPad alone
#
# Names the device; scripts/deploy.sh does the work and carries the rationale.
# Set SZ_IPAD to override the recorded identifier for a one-off run.

set -euo pipefail

export SZ_KIND="iPad"
export SZ_DEVICE_FILE=".device"
export SZ_DEVICE_ENV="SZ_IPAD"
export SZ_DEVICE="${SZ_IPAD:-}"

exec "$(dirname "$0")/deploy.sh" "$@"
