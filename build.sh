#!/bin/bash
# Build SimpleIsland.app from source (SwiftPM), install it to /Applications, sign it, add a login item, launch it.
#
#   ./build.sh                                   normal build (no Meetings widget)
#   ./build.sh --with-meetings --meetings-server https://sten.example.com/sten
#                                                + the optional Meetings widget for teams that run a Sten server
#   ./build.sh --no-launch                       build and install only: no stop/start, no login item
#
# Environment:
#   SIMPLEISLAND_PREFIX=/some/dir   install SimpleIsland.app there instead of /Applications (implies --no-launch)
#   SIMPLEISLAND_JOBS=2             parallel build jobs (default: all cores)
#   SIMPLEISLAND_VERSION=1.2.3      version written to Info.plist (default: ./VERSION)
#   SIMPLEISLAND_ARCHS="arm64 x86_64"  build a universal binary (release.sh uses this)
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

NAME="SimpleIsland"
LABEL="local.simpleisland"
WITH_MEETINGS=0
MEETINGS_SERVER=""
LAUNCH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --with-meetings) WITH_MEETINGS=1 ;;
    --meetings-server) MEETINGS_SERVER="${2:?--meetings-server needs an address}"; WITH_MEETINGS=1; shift ;;
    --meetings-server=*) MEETINGS_SERVER="${1#*=}"; WITH_MEETINGS=1 ;;
    --no-launch) LAUNCH=0 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
  shift
done

PREFIX="${SIMPLEISLAND_PREFIX:-/Applications}"
[ "$PREFIX" = "/Applications" ] || LAUNCH=0
APP="$PREFIX/$NAME.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
VERSION="${SIMPLEISLAND_VERSION:-$(cat VERSION 2>/dev/null || echo 0.0.0)}"
read -r -a ARCHS <<< "${SIMPLEISLAND_ARCHS:-}"

if ! command -v swift >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are required: xcode-select --install"; exit 1
fi

SCRATCH=".build-release"
[ "$WITH_MEETINGS" = "1" ] && SCRATCH=".build-meetings"
ARGS=(-c release --product "$NAME")
[ -n "${SIMPLEISLAND_JOBS:-}" ] && ARGS+=(-j "$SIMPLEISLAND_JOBS")

echo "Compiling $NAME $VERSION$([ "$WITH_MEETINGS" = "1" ] && echo " (with Meetings)")..."
export SIMPLEISLAND_MEETINGS="$WITH_MEETINGS"
if [ ${#ARCHS[@]} -eq 0 ]; then
  swift build "${ARGS[@]}" --scratch-path "$SCRATCH"
  BIN="$(swift build "${ARGS[@]}" --scratch-path "$SCRATCH" --show-bin-path)/$NAME"
else
  # One build per architecture (multi --arch needs full Xcode's xcbuild), then lipo.
  SLICES=()
  for a in "${ARCHS[@]}"; do
    swift build "${ARGS[@]}" --scratch-path "$SCRATCH-$a" --arch "$a"
    SLICES+=("$(swift build "${ARGS[@]}" --scratch-path "$SCRATCH-$a" --arch "$a" --show-bin-path)/$NAME")
  done
  BIN="$ROOT/$SCRATCH-universal/$NAME"
  mkdir -p "$(dirname "$BIN")"
  lipo -create "${SLICES[@]}" -output "$BIN"
fi

if [ "$LAUNCH" = "1" ]; then
  echo "Stopping running instance..."
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  pkill -f "^$APP/Contents/MacOS/$NAME" 2>/dev/null || true
  sleep 0.5
fi

echo "Assembling $APP..."
mkdir -p "$PREFIX"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Themes" "$APP/Contents/Resources/Catalog"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp Resources/AppIcon.icns Resources/MenuBarIcon.pdf "$APP/Contents/Resources/"
cp Resources/Catalog/*.png "$APP/Contents/Resources/Catalog/"
cp design/themes/*.json "$APP/Contents/Resources/Themes/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>SimpleIsland показывает ближайшую встречу и кнопку «Подключиться».</string>
  <key>NSAppleEventsUsageDescription</key><string>SimpleIsland управляет музыкой в Music и Spotify, по нажатию на агента переключает на его окно терминала и включает тёмную тему через System Events. По кнопке «Установить» в каталоге виджетов открывает Терминал с командой установки через Homebrew.</string>
  <key>NSCameraUsageDescription</key><string>Камера нужна для «зеркала» в острове — только когда вы его открываете.</string>
  <key>NSAppleMusicUsageDescription</key><string>SimpleIsland берёт у вашей подписки Apple Music ключ для пословных текстов песен. Пароль и медиатека не читаются.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Эквалайзер в острове двигается по звуку, который сейчас играет. Звук не записывается на диск и никуда не отправляется — считаются только уровни полос.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>SimpleIsland показывает, что подключились наушники или AirPods, и их заряд.</string>
</dict>
</plist>
PLIST
if [ "$WITH_MEETINGS" = "1" ]; then
  /usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string 'Виджет «Встречи» записывает встречу с микрофона по кнопке «Начать запись» и отправляет звук на ваш сервер Sten для протокола.'" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SimpleIslandStenServer string '$MEETINGS_SERVER'" "$APP/Contents/Info.plist"
fi

echo "Building the media helper..."
scripts/build-media-helper.sh "$APP/Contents/Resources" >/dev/null

echo "Signing..."
# One stable local certificate keeps granted permissions across updates; without it — ad-hoc.
ID="$(security find-identity -p codesigning 2>/dev/null | awk '/"ScreenTab Local Signing"/{print $2; exit}')"
SIGN="${ID:--}"
codesign --force --sign "$SIGN" --timestamp=none "$APP/Contents/Resources/SimpleIslandMR.dylib"
codesign --force --sign "$SIGN" "$APP"
codesign --verify --strict --deep "$APP"

if [ "$LAUNCH" = "0" ]; then
  echo "Built $APP (not launched, no login item)."
  exit 0
fi

# Ad-hoc signature = new code hash on every build: old permission checkboxes no longer apply, let macOS ask again.
if [ -z "$ID" ]; then tccutil reset All "$LABEL" >/dev/null 2>&1 || true; fi

# Login item: the app turns on "Open at login" itself on first launch (SMAppService) — no LaunchAgent here,
# so it never starts twice. An old LaunchAgent from earlier builds is removed.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
open "$APP"

echo
echo "Installed $APP. macOS asks for permissions when a feature first needs them"
echo "(Accessibility for the menu bar cleanup, Calendar for Today, Automation for Music/Spotify)."
