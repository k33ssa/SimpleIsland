#!/bin/bash
# Maintainer script: ./release.sh 1.0.0
# Universal SimpleIsland.app (arm64 + x86_64) -> zip -> GitHub release -> bump the cask in k33ssa/homebrew-tap.
# The release build never contains the optional Meetings widget.
set -euo pipefail
cd "$(dirname "$0")"
VER="${1:?usage: ./release.sh <version>}"
NAME=SimpleIsland
LOWER=simpleisland
OUT="$(pwd)/dist"; APP="$OUT/$NAME.app"; ZIP="$OUT/$NAME-$VER.zip"

security find-identity -p codesigning | grep -q '"ScreenTab Local Signing"' \
  || { echo "signing identity 'ScreenTab Local Signing' missing: releases must use the stable certificate"; exit 1; }

rm -rf "$OUT" && mkdir -p "$OUT"
echo "$VER" > VERSION
# 1. universal build + bundle + signature (build.sh, installs into dist/, no launch)
SIMPLEISLAND_PREFIX="$OUT" SIMPLEISLAND_VERSION="$VER" SIMPLEISLAND_ARCHS="arm64 x86_64" bash build.sh --no-launch
lipo -info "$APP/Contents/MacOS/$NAME" | grep -q x86_64 || { echo "not universal"; exit 1; }
ditto -c -k --keepParent "$APP" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')

# 2. release
gh release create "v$VER" "$ZIP" -R k33ssa/$NAME --title "$NAME $VER" --notes-file - <<NOTES
A Dynamic Island for the Mac notch: now playing with synced lyrics, today at a glance, a file shelf, Claude Code / Codex agents, volume and brightness indicators, menu bar cleanup.

## Downloads

| Platform | File | Install |
|---|---|---|
| macOS 15+ (Apple Silicon + Intel) | [$NAME-$VER.zip](https://github.com/k33ssa/$NAME/releases/download/v$VER/$NAME-$VER.zip) | \`brew install --cask k33ssa/tap/$LOWER\` |

**Update:** \`brew upgrade --cask $LOWER\`. Automatic background updates: \`brew tap DomT4/autoupdate && brew trust DomT4/autoupdate && brew autoupdate start --upgrade --cleanup\`.

**Zip without Homebrew:** unzip, move $NAME.app to Applications, open it. The app is free and not notarized; if macOS refuses to open it, run \`xattr -dr com.apple.quarantine /Applications/$NAME.app\` once.
NOTES

# 3. README download links -> this version
sed -i '' -E "s/($NAME-)[0-9]+\.[0-9]+\.[0-9]+(\.zip)/\1$VER\2/g; s#(releases/download/v)[0-9]+\.[0-9]+\.[0-9]+#\1$VER#g" README.md
git add README.md VERSION && git commit -qm "release $VER" && git push -q origin main || true

# 4. cask in the tap (first time: copy packaging/Casks/$LOWER.rb into the tap)
TAP=$(mktemp -d)
gh repo clone k33ssa/homebrew-tap "$TAP" -- -q
[ -f "$TAP/Casks/$LOWER.rb" ] || cp "packaging/Casks/$LOWER.rb" "$TAP/Casks/$LOWER.rb"
sed -i '' -E "s/version \"[^\"]+\"/version \"$VER\"/; s/sha256 \"[^\"]+\"/sha256 \"$SHA\"/" "$TAP/Casks/$LOWER.rb"
git -C "$TAP" add "Casks/$LOWER.rb"
git -C "$TAP" commit -qm "$LOWER $VER" && git -C "$TAP" push -q
rm -rf "$TAP"
echo "released $VER  sha256=$SHA"
