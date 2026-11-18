#!/bin/zsh
# Builds GameShelf.app (release, ad-hoc signed) into macos/build/.
# Usage: scripts/build-app.sh [--debug] [--open]
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIG=release
OPEN=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --open) OPEN=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

NAME=GameShelf
BUNDLE_ID=local.gameshelf.app
APP="$ROOT/build/$NAME.app"

cd "$ROOT"
swift build -c "$CONFIG" --product "$NAME"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"

if [[ $OPEN == 1 ]]; then open "$APP"; fi
