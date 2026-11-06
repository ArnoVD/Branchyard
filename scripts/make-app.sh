#!/bin/zsh
# Builds Branchyard.app (release) into ./dist.
# Usage: ./scripts/make-app.sh            build only
#        ./scripts/make-app.sh --install  build, copy to /Applications and open it
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Branchyard
BIN="$(swift build -c release --show-bin-path)/Branchyard"

APP="dist/Branchyard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Branchyard"

# App icon: render the logo to an .iconset, then pack it as .icns.
swift build -c release --product IconRenderer
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$(swift build -c release --show-bin-path)/IconRenderer" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Branchyard</string>
  <key>CFBundleDisplayName</key><string>Branchyard</string>
  <key>CFBundleIdentifier</key><string>local.branchyard.app</string>
  <key>CFBundleExecutable</key><string>Branchyard</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app "Branchyard"' 2>/dev/null || true
  sleep 1
  rm -rf /Applications/Branchyard.app
  ditto "$APP" /Applications/Branchyard.app
  echo "Installed /Applications/Branchyard.app"
  open /Applications/Branchyard.app
else
  echo "Install: ./scripts/make-app.sh --install"
fi
