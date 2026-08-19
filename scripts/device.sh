#!/bin/zsh
# Build, install and launch on the connected iPad — the same thing as hitting
# Run in Xcode.
#
#   ./scripts/device.sh setup       record the connected device in .device
#   ./scripts/device.sh             build, install, launch
#   ./scripts/device.sh no-launch   build and install only, leave the iPad alone
#
# This is a development install only. Packaging, signing for distribution,
# notarising and uploading stay manual.
#
# The build is `generic/platform=iOS`, so it does not need the device present at
# build time — only the install does. Kept in its own derived-data directory so
# a device build never invalidates the simulator one, and vice versa.
#
# NOTE (zsh): argument lists are arrays expanded as "${arr[@]}". An unquoted
# scalar does not word-split in zsh and silently becomes one argv token.

set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE="com.mihailod.szreader"

# The device identifier lives in .device, which is gitignored — it names a
# specific piece of hardware and belongs to this machine, not the repository.
# Set SZ_IPAD to override for a one-off run.
#
#   ./scripts/device.sh setup     write .device from the connected iPad
if [[ "${1:-}" == "setup" ]]; then
  # Matched by shape, not by column: both the name and model columns contain
  # spaces, so counting fields picks up a fragment of the model name.
  id=$(xcrun devicectl list devices 2>/dev/null | grep connected \
       | grep -oE '[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}' | head -1)
  [[ -n "$id" ]] || { echo "no connected device found — plug one in"; exit 1; }
  print -r -- "$id" > .device
  echo "==> wrote .device ($id)"
  exit 0
fi

DEVICE="${SZ_IPAD:-}"
if [[ -z "$DEVICE" && -r .device ]]; then
  DEVICE=$(< .device)
  DEVICE="${DEVICE//[[:space:]]/}"
fi
if [[ -z "$DEVICE" ]]; then
  echo "no device configured — run: ./scripts/device.sh setup"
  echo "(or set SZ_IPAD to a device identifier)"
  exit 1
fi

state=$(xcrun devicectl list devices 2>/dev/null | awk -v d="$DEVICE" '$0 ~ d {print}')
if [[ -z "$state" ]]; then
  echo "==> iPad not paired with this Mac (looked for $DEVICE)"
  echo "    plug it in, or set SZ_IPAD to another device identifier"
  exit 1
fi
# Two states can be installed to, and only one of them says "connected":
# a cabled device reports "connected", while one reachable over the network
# reports "available (paired)". Checking for "connected" alone refused every
# wireless deploy with a message telling you to enable the network debugging
# that was already working.
#
# "unavailable" is the paired-but-out-of-reach case and is the one to refuse.
if [[ "$state" != *connected* && "$state" != *available* ]]; then
  echo "==> iPad is paired but not reachable — plug it in, or put it on the"
  echo "    same network with Xcode's network debugging enabled"
  exit 1
fi

args=(-project SZReader.xcodeproj -scheme SZReader
      -destination "generic/platform=iOS"
      -derivedDataPath .xcbuild-device -quiet build)
echo "==> building for device"
xcodebuild "${args[@]}"

app=$(find .xcbuild-device/Build/Products -name 'SZReader.app' -maxdepth 3 | head -1)
[[ -n "$app" ]] || { echo "no .app produced"; exit 1; }

# Installing over the existing app keeps its data container — so the library,
# the downloads and the forum login all survive the update.
echo "==> installing on iPad"
if ! xcrun devicectl device install app --device "$DEVICE" "$app" 2>&1 | tail -3; then
  echo "==> install failed — the iPad must be unlocked to accept it"
  exit 1
fi

# Launching by default mirrors what Run in Xcode does, and saves reaching for
# the iPad after every build. Terminate first: launching an already-running app
# just foregrounds the old process, so without this you would be looking at the
# previous build and think the change had not landed.
if [[ "${1:-}" != "no-launch" ]]; then
  echo "==> launching"
  xcrun devicectl device process terminate \
    --device "$DEVICE" --bundle-identifier "$BUNDLE" >/dev/null 2>&1 || true
  xcrun devicectl device process launch \
    --device "$DEVICE" --terminate-existing "$BUNDLE" >/dev/null
fi
echo "==> done"
