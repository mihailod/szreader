#!/bin/zsh
# Build, install and launch on a paired device — the same thing as hitting Run
# in Xcode.
#
# Not run directly. The per-device wrappers name the device and call in here:
#
#   ./scripts/iPad.sh      →  .device,        SZ_IPAD
#   ./scripts/iPhone.sh    →  .device-iphone, SZ_IPHONE
#
# They pass everything device-specific through the environment:
#
#   SZ_KIND         display name, and the model to match on in `setup`
#   SZ_DEVICE_FILE  file holding the identifier, gitignored
#   SZ_DEVICE_ENV   name of the one-off override variable, for messages
#   SZ_DEVICE       its value, already resolved by the wrapper
#
# This is a development install only. Packaging, signing for distribution,
# notarising and uploading stay manual.
#
# The build is `generic/platform=iOS`, so it does not need the device present at
# build time — only the install does. That also makes it the same product for
# every device, so one derived-data directory serves them all and switching
# devices does not force a rebuild. It is kept separate from the simulator's so
# a device build never invalidates that one, and vice versa.
#
# NOTE (zsh): argument lists are arrays expanded as "${arr[@]}". An unquoted
# scalar does not word-split in zsh and silently becomes one argv token.

set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE="com.mihailod.szreader"

if [[ -z "${SZ_KIND:-}" ]]; then
  echo "scripts/deploy.sh is not run directly — use ./scripts/iPad.sh or ./scripts/iPhone.sh"
  exit 1
fi
KIND="$SZ_KIND"
SCRIPT="./scripts/${KIND}.sh"

# The device identifier lives in a gitignored file — it names a specific piece
# of hardware and belongs to this machine, not the repository.
#
#   ./scripts/iPad.sh setup     write the identifier from the paired device
if [[ "${1:-}" == "setup" ]]; then
  # Matched by shape, not by column: both the name and model columns contain
  # spaces, so counting fields picks up a fragment of the model name. Narrowed
  # to rows naming this kind of device, so with both paired the wrong one is
  # never recorded.
  #
  # Both reachable states count here, not just "connected" — see the state
  # check below for why.
  id=$(xcrun devicectl list devices 2>/dev/null \
       | grep -E 'connected|available' | grep -i "$KIND" \
       | grep -oE '[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}' | head -1)
  [[ -n "$id" ]] || { echo "no reachable $KIND found — plug it in or wake it"; exit 1; }
  print -r -- "$id" > "$SZ_DEVICE_FILE"
  echo "==> wrote $SZ_DEVICE_FILE ($id)"
  exit 0
fi

DEVICE="${SZ_DEVICE:-}"
if [[ -z "$DEVICE" && -r "$SZ_DEVICE_FILE" ]]; then
  DEVICE=$(< "$SZ_DEVICE_FILE")
  DEVICE="${DEVICE//[[:space:]]/}"
fi
if [[ -z "$DEVICE" ]]; then
  echo "no device configured — run: $SCRIPT setup"
  echo "(or set $SZ_DEVICE_ENV to a device identifier)"
  exit 1
fi

state=$(xcrun devicectl list devices 2>/dev/null | awk -v d="$DEVICE" '$0 ~ d {print}')
if [[ -z "$state" ]]; then
  echo "==> $KIND not paired with this Mac (looked for $DEVICE)"
  echo "    plug it in, or set $SZ_DEVICE_ENV to another device identifier"
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
  echo "==> $KIND is paired but not reachable — plug it in, or put it on the"
  echo "    same network with Xcode's network debugging enabled"
  exit 1
fi

# `-allowProvisioningUpdates` lets xcodebuild fetch a profile itself.
#
# Without it, xcodebuild will only ever use a profile already cached on this
# Mac — it will not create or refresh one — so the first build after any change
# to the App ID's capabilities fails, and the only way through is to open Xcode
# once and let it do the fetch. Adding iCloud was exactly that: the portal says
# in as many words that changing capabilities invalidates every profile
# carrying this App ID.
#
# This is still a development install. It refreshes development signing; it
# does not package, distribute or notarise anything.
args=(-project SZReader.xcodeproj -scheme SZReader
      -destination "generic/platform=iOS"
      -derivedDataPath .xcbuild-device -allowProvisioningUpdates -quiet build)
echo "==> building for device"
xcodebuild "${args[@]}"

app=$(find .xcbuild-device/Build/Products -name 'SZReader.app' -maxdepth 3 | head -1)
[[ -n "$app" ]] || { echo "no .app produced"; exit 1; }

# Installing over the existing app keeps its data container — so the library,
# the downloads and the forum login all survive the update.
echo "==> installing on $KIND"
if ! xcrun devicectl device install app --device "$DEVICE" "$app" 2>&1 | tail -3; then
  echo "==> install failed — the $KIND must be unlocked to accept it"
  exit 1
fi

# Launching by default mirrors what Run in Xcode does, and saves reaching for
# the device after every build. Terminate first: launching an already-running
# app just foregrounds the old process, so without this you would be looking at
# the previous build and think the change had not landed.
if [[ "${1:-}" != "no-launch" ]]; then
  echo "==> launching"
  xcrun devicectl device process terminate \
    --device "$DEVICE" --bundle-identifier "$BUNDLE" >/dev/null 2>&1 || true
  xcrun devicectl device process launch \
    --device "$DEVICE" --terminate-existing "$BUNDLE" >/dev/null
fi
echo "==> done"
