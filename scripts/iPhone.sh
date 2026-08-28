#!/bin/zsh
# Build, install and launch on the paired iPhone.
#
#   ./scripts/iPhone.sh setup       record the paired iPhone in .device-iphone
#   ./scripts/iPhone.sh             build, install, launch
#   ./scripts/iPhone.sh no-launch   build and install only, leave the phone alone
#
# Names the device; scripts/deploy.sh does the work and carries the rationale.
# A separate identifier file from the iPad's, so both stay configured at once.
# Set SZ_IPHONE to override the recorded identifier for a one-off run.

set -euo pipefail

export SZ_KIND="iPhone"
export SZ_DEVICE_FILE=".device-iphone"
export SZ_DEVICE_ENV="SZ_IPHONE"
export SZ_DEVICE="${SZ_IPHONE:-}"

exec "$(dirname "$0")/deploy.sh" "$@"
