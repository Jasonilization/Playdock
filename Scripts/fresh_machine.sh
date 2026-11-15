#!/usr/bin/env bash
# A second Playdock you can throw away. It has its own bundle id, its own support
# folder, and an empty library. The real app, its bottles, and Sikarugir are not touched.
#
#   ./Scripts/fresh_machine.sh          build (if needed) and open the fresh app
#   ./Scripts/fresh_machine.sh reset    quit it and delete only the fresh folder
#   ./Scripts/fresh_machine.sh down     quit it, keep the fresh folder
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRESH_ROOT="${HOME}/Library/Application Support/PlaydockFresh"
APP="${FRESH_ROOT}/PlaydockFresh.app"
SUPPORT="${FRESH_ROOT}/Support"
BUNDLE_ID="com.jasonilization.playdock.fresh"
SOURCE_APP="${ROOT}/build/Playdock.app"

case "${FRESH_ROOT}" in
  */PlaydockFresh) ;;
  *) echo "Refusing to touch an unexpected path: ${FRESH_ROOT}" >&2; exit 1 ;;
esac

quit_fresh() {
  osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
  # The process name is ExeDock for both apps. Match the fresh bundle path only.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ! pgrep -f "${APP}/Contents/MacOS/ExeDock" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.3
  done
}

cmd="${1:-up}"
case "${cmd}" in
  down)
    quit_fresh
    echo "Playdock Fresh quit. Data is still at ${FRESH_ROOT}"
    ;;
  reset)
    quit_fresh
    rm -rf "${FRESH_ROOT}"
    defaults delete "${BUNDLE_ID}" >/dev/null 2>&1 || true
    echo "Removed ${FRESH_ROOT}"
    ;;
  up)
    "${ROOT}/Scripts/build_app.sh"
    quit_fresh
    mkdir -p "${FRESH_ROOT}"
    rm -rf "${APP}"
    ditto "${SOURCE_APP}" "${APP}"
    PLIST="${APP}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "${PLIST}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Playdock Fresh" "${PLIST}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Playdock Fresh" "${PLIST}"
    /usr/libexec/PlistBuddy -c "Delete :LSEnvironment" "${PLIST}" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "${PLIST}"
    /usr/libexec/PlistBuddy -c "Add :LSEnvironment:PLAYDOCK_SUPPORT_DIR string ${SUPPORT}" "${PLIST}"
    /usr/libexec/PlistBuddy -c "Add :LSEnvironment:EXEDOCK_SUPPORT_DIR string ${SUPPORT}" "${PLIST}"
    /usr/libexec/PlistBuddy -c "Add :LSEnvironment:PLAYDOCK_HIDE_HOST_STEAM string 1" "${PLIST}"
    mkdir -p "${SUPPORT}"
    codesign --force --deep --sign - "${APP}" >/dev/null
    if [[ -x /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister ]]; then
      /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${APP}" >/dev/null
    fi
    open "${APP}"
    echo "Playdock Fresh is open."
    echo "Library and bottles: ${SUPPORT}"
    echo "Your real Playdock data was not used."
    echo "Throw this one away with: ./Scripts/fresh_machine.sh reset"
    ;;
  *)
    echo "Use: $0 [up|down|reset]" >&2
    exit 1
    ;;
esac
