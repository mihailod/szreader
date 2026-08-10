#!/bin/zsh
# Build and install onto the connected iPad — the same thing as hitting Run in
# Xcode, minus the launch.
#
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

DEVICE="${SZ_IPAD:-CC1C5C3D-0634-5472-9F56-19A47F3F0E17}"   # Mihailo's iPad Pro 6
BUNDLE="com.mihailod.szreader"

state=$(xcrun devicectl list devices 2>/dev/null | awk -v d="$DEVICE" '$0 ~ d {print}')
if [[ -z "$state" ]]; then
  echo "==> iPad not paired with this Mac (looked for $DEVICE)"
  echo "    plug it in, or set SZ_IPAD to another device identifier"
  exit 1
fi
if [[ "$state" != *connected* ]]; then
  echo "==> iPad is paired but not connected — plug it in or enable network debugging"
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
