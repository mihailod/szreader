#!/bin/zsh
# Simulator helper: build, run, and keep the forum login alive between builds.
#
#   ./scripts/sim.sh run       build, install over the existing app, launch
#   ./scripts/sim.sh seed      launch with the saved topic pages imported
#   ./scripts/sim.sh paste     copy the Mac clipboard into the simulator
#   ./scripts/sim.sh save      snapshot the logged-in session to .simsession/
#   ./scripts/sim.sh restore   put a saved session back
#   ./scripts/sim.sh wipe      delete the app and all its data
#
# Why `install` and never `uninstall`: installing over an app upgrades it in
# place and keeps its data container, so cookies — and therefore the stripzona
# login — survive a rebuild. `uninstall` destroys the container, which is what
# made the login vanish on every reinstall.
#
# NOTE (zsh): argument lists are arrays expanded as "${arr[@]}". An unquoted
# scalar does not word-split in zsh and silently becomes one argv token.

set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${SZ_DEVICE:-DD69DE82-2AC8-4E3B-8EEF-1C2D9A64B9C4}"
BUNDLE="com.mihailod.szreader"
SESSION_DIR="$PWD/.simsession"

# WebKit spreads a logged-in session across these; cookies alone are not enough.
SESSION_PATHS=(Library/Cookies Library/WebKit Library/HTTPStorages)

app_container() {
  xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data 2>/dev/null
}

cmd_run() {
  local args=(-project SZReader.xcodeproj -scheme SZReader
              -destination "platform=iOS Simulator,id=$DEVICE"
              -derivedDataPath .xcbuild -quiet build)
  echo "==> building"
  xcodebuild "${args[@]}"
  local app
  app=$(find .xcbuild/Build/Products -name 'SZReader.app' -maxdepth 3 | head -1)
  [[ -n "$app" ]] || { echo "no .app produced"; exit 1; }
  xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || xcrun simctl boot "$DEVICE" || true
  echo "==> installing (in place — keeps the login)"
  xcrun simctl install "$DEVICE" "$app"
  xcrun simctl launch "$DEVICE" "$BUNDLE" >/dev/null
  echo "==> running"
}

# Launch with the saved topic pages, so the simulator has a real library to
# look at. The simulator cannot log in to the forum; these pages are checked
# into spike/ and never ship (the import path is #if DEBUG).
cmd_seed() {
  local args=(-project SZReader.xcodeproj -scheme SZReader
              -destination "platform=iOS Simulator,id=$DEVICE"
              -derivedDataPath .xcbuild -quiet build)
  echo "==> building"
  xcodebuild "${args[@]}"
  local app
  app=$(find .xcbuild/Build/Products -name 'SZReader.app' -maxdepth 3 | head -1)
  [[ -n "$app" ]] || { echo "no .app produced"; exit 1; }
  xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || xcrun simctl boot "$DEVICE" || true
  echo "==> installing (in place — keeps the login)"
  xcrun simctl install "$DEVICE" "$app"
  echo "==> seeding from spike/pages"
  xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
  SIMCTL_CHILD_SZ_SEED_PAGES="$PWD/spike/pages" \
    xcrun simctl launch "$DEVICE" "$BUNDLE" >/dev/null
  echo "==> running (seeded)"
}

cmd_paste() {
  # Sync whatever is on the Mac clipboard into the simulator, then long-press
  # the field in the app and choose Paste. Nothing is printed or stored here.
  xcrun simctl pbsync host "$DEVICE"
  echo "clipboard synced to the simulator — long-press the field and Paste"
}

cmd_save() {
  local container; container=$(app_container)
  [[ -n "$container" ]] || { echo "app not installed"; exit 1; }
  rm -rf "$SESSION_DIR"; mkdir -p "$SESSION_DIR"
  local saved=0
  for rel in "${SESSION_PATHS[@]}"; do
    if [[ -e "$container/$rel" ]]; then
      mkdir -p "$SESSION_DIR/$(dirname "$rel")"
      cp -R "$container/$rel" "$SESSION_DIR/$rel"
      saved=$((saved + 1))
    fi
  done
  echo "saved $saved session store(s) to .simsession/ (gitignored)"
}

cmd_restore() {
  [[ -d "$SESSION_DIR" ]] || { echo "nothing saved — run 'save' while logged in"; exit 1; }
  local container; container=$(app_container)
  [[ -n "$container" ]] || { echo "app not installed; run 'run' first"; exit 1; }
  xcrun simctl terminate "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
  for rel in "${SESSION_PATHS[@]}"; do
    if [[ -e "$SESSION_DIR/$rel" ]]; then
      rm -rf "${container:?}/$rel"
      mkdir -p "$(dirname "$container/$rel")"
      cp -R "$SESSION_DIR/$rel" "$container/$rel"
    fi
  done
  echo "session restored — relaunch to pick it up"
}

cmd_wipe() {
  xcrun simctl uninstall "$DEVICE" "$BUNDLE" || true
  echo "app and all its data removed (login included)"
}

case "${1:-run}" in
  run)     cmd_run ;;
  seed)    cmd_seed ;;
  paste)   cmd_paste ;;
  save)    cmd_save ;;
  restore) cmd_restore ;;
  wipe)    cmd_wipe ;;
  *) echo "usage: $0 {run|paste|save|restore|wipe}"; exit 2 ;;
esac
