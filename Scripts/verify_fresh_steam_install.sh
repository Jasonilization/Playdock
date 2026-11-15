#!/usr/bin/env bash
# Internal: prove first-time Steam install in an isolated support root (never touches
# ~/Library/Application Support/ExeDock bottles). Requires an already-extracted engine;
# reads and copies from the user's ExeDock Engine + Frameworks without modifying them.
set -euo pipefail

REAL_SUPPORT="${HOME}/Library/Application Support/ExeDock"
TEST_ROOT="${1:-/tmp/playdock-fresh-verify-$(date +%s)}"
STEAM_EXE_REL="drive_c/Program Files (x86)/Steam/Steam.exe"
LOG="${TEST_ROOT}/verify-steam-install.log"
START_TS=$(date +%s)

mkdir -p "${TEST_ROOT}"
: >"${LOG}"

if [[ ! -x "${REAL_SUPPORT}/Engine/bin/wine" ]]; then
  echo "No extracted engine at ${REAL_SUPPORT}/Engine — open Playdock once to prepare the engine." | tee -a "${LOG}"
  exit 1
fi

echo "TEST_ROOT=${TEST_ROOT}" | tee -a "${LOG}"
cp -Rc "${REAL_SUPPORT}/Engine" "${TEST_ROOT}/Engine"
cp -Rc "${REAL_SUPPORT}/Frameworks" "${TEST_ROOT}/Frameworks"
touch "${TEST_ROOT}/Frameworks/.complete"

PREFIX="${TEST_ROOT}/Bottles/Steam"
mkdir -p "${PREFIX}"
WINE="${TEST_ROOT}/Engine/bin/wine"
export WINEPREFIX="${PREFIX}"
export DYLD_FALLBACK_LIBRARY_PATH="${TEST_ROOT}/Frameworks:${TEST_ROOT}/Engine/lib"
export WINEDEBUG="-all"

"${WINE}" wineboot --init >>"${LOG}" 2>&1
for _ in $(seq 1 120); do
  [[ -f "${PREFIX}/system.reg" ]] && break
  sleep 1
done
[[ -f "${PREFIX}/system.reg" ]] || { echo "wineboot failed" | tee -a "${LOG}"; tail -20 "${LOG}"; exit 1; }

# Let wineboot background helpers (rundll32, mono) settle — race here broke earlier attempts.
sleep 15

SETUP_DL="${TEST_ROOT}/SteamSetup.exe"
curl -fsSL -o "${SETUP_DL}" "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe"
DRIVE_C="${PREFIX}/drive_c"
cp "${SETUP_DL}" "${DRIVE_C}/SteamSetup.exe"

echo "=== steam install $(date) ===" >>"${LOG}"
(cd "${DRIVE_C}" && "${WINE}" "${DRIVE_C}/SteamSetup.exe" /S >>"${LOG}" 2>&1) || true

STEAM_EXE="${PREFIX}/${STEAM_EXE_REL}"
for _ in $(seq 1 60); do
  if [[ -f "${STEAM_EXE}" ]]; then
    END_TS=$(date +%s)
    echo "SUCCESS Steam.exe created elapsed=$((END_TS - START_TS))s" | tee -a "${LOG}"
    ls -la "${STEAM_EXE}"
    exit 0
  fi
  sleep 2
done

END_TS=$(date +%s)
echo "FAIL elapsed=$((END_TS - START_TS))s — Steam.exe missing" | tee -a "${LOG}"
tail -30 "${LOG}"
exit 1