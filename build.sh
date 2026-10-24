#!/bin/zsh
# Dev build: compiles "Day Offload.app" for this Mac and installs it in /Applications.
# For a release (universal, signed, notarized) use ./make-app.sh instead.
set -e
cd "${0:A:h}"
T=$(mktemp -d /tmp/dayoffload-dev.XXXXXX)
APP="$T/Day Offload.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library Sources/DayOffload.swift Sources/Engine.swift Sources/XXH3.swift Sources/Update.swift -o "$APP/Contents/MacOS/DayOffload"
cp Icon/AppIcon.icns "$APP/Contents/Resources/"
VERSION=$(grep 'static let version' Sources/DayOffload.swift | sed 's/.*"\(.*\)".*/\1/')
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Day Offload</string>
  <key>CFBundleIdentifier</key><string>co.move-ment.dayoffload</string>
  <key>CFBundleExecutable</key><string>DayOffload</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
xattr -cr "$APP"
codesign --force --sign - "$APP"
rm -rf "/Applications/Day Offload.app"
ditto "$APP" "/Applications/Day Offload.app"
rm -rf "$T"
echo "Installed /Applications/Day Offload.app (v$VERSION, dev build)"
