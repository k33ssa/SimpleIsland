#!/bin/bash
# One-line installer/updater for SimpleIsland (builds from source, needs Xcode Command Line Tools).
#   curl -fsSL https://raw.githubusercontent.com/k33ssa/SimpleIsland/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- uninstall
# Teams with a Sten server (optional Meetings widget):
#   curl -fsSL .../install.sh | bash -s -- --with-meetings --meetings-server https://<your-sten-host>/sten
# Other options are passed to build.sh (--no-launch; SIMPLEISLAND_PREFIX=/dir to install elsewhere).
# SIMPLEISLAND_REPO / SIMPLEISLAND_BRANCH override the source (e.g. a local file:// clone for testing).
set -euo pipefail

REPO="${SIMPLEISLAND_REPO:-https://github.com/k33ssa/SimpleIsland.git}"
BRANCH="${SIMPLEISLAND_BRANCH:-main}"
APP="${SIMPLEISLAND_PREFIX:-/Applications}/SimpleIsland.app"
LABEL="local.simpleisland"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "${1:-}" = "uninstall" ]; then
  echo "Uninstalling SimpleIsland..."
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  pkill -f "^$APP/Contents/MacOS/SimpleIsland" 2>/dev/null || true
  rm -f "$PLIST"
  rm -rf "$APP"
  if [ "${2:-}" = "--purge" ]; then
    rm -rf "$HOME/Library/Application Support/SimpleIsland"
    echo "Settings removed."
  else
    echo "Settings kept in ~/Library/Application Support/SimpleIsland (add --purge to remove them)."
  fi
  echo "Done. Permission entries can be removed in System Settings -> Privacy & Security."
  exit 0
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are required. Installing..."
  xcode-select --install || true
  echo "Re-run this command once the tools finish installing."
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Fetching latest SimpleIsland..."
git clone -q --depth 1 --branch "$BRANCH" "$REPO" "$TMP/src"
cd "$TMP/src"
bash build.sh "$@"
