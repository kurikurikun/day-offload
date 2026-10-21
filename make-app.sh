#!/bin/bash
# Build "Day Offload.app" + release zips from a clean checkout.
# Needs Xcode or Command Line Tools. Output: build/DayOffload-<version>.zip and build/DayOffload.zip
#
# Signs with Developer ID + notarizes + staples IF the keychain has a
# "Developer ID Application" certificate and a notarytool profile (default
# name "peripheralspeed-notary", override with NOTARY_PROFILE=…).
# Otherwise it refuses to make a release; ALLOW_ADHOC=1 ./make-app.sh for a dev build.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(grep 'static let version' Sources/DayOffload.swift | sed 's/.*"\(.*\)".*/\1/')
SOURCES=(Sources/DayOffload.swift Sources/Engine.swift Sources/XXH3.swift)

# Some Command Line Tools releases ship no SwiftUI macro plugin, so SwiftUI
# code fails to compile against the newest SDK. Probe, and fall back to the
# newest installed SDK that works (deployment target is macOS 14).
PROBE=$(mktemp -d /tmp/dayoffload-probe.XXXXXX)
trap 'rm -rf "$PROBE"' EXIT
cat > "$PROBE/probe.swift" <<'SWIFT'
import SwiftUI
struct Probe: View { @State var n = 0; var body: some View { Text("\(n)") } }
SWIFT
builds_with() {
    if [ -n "$1" ]; then swiftc -parse-as-library -typecheck -sdk "$1" "$PROBE/probe.swift" >/dev/null 2>&1
    else swiftc -parse-as-library -typecheck "$PROBE/probe.swift" >/dev/null 2>&1; fi
}
SDK_ARGS=()
if ! builds_with ""; then
    for CANDIDATE in $(ls -d "$(xcode-select -p)"/SDKs/MacOSX*.sdk \
                             "$(xcode-select -p)"/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.sdk \
                             /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | sort -Vr); do
        if builds_with "$CANDIDATE"; then
            SDK_ARGS=(-sdk "$CANDIDATE"); echo "note: building against $(basename "$CANDIDATE")"; break
        fi
    done
    [ ${#SDK_ARGS[@]} -gt 0 ] || { echo "error: no SDK on this Mac can compile SwiftUI — install Xcode." >&2; exit 1; }
fi

./Tests/run.sh   # xxHash must match the reference before anything ships

# Assemble OUTSIDE any iCloud-synced folder: sync daemons re-stamp metadata
# that strict codesigning rejects.
STAGE=$(mktemp -d /tmp/dayoffload-build.XXXXXX)
APP="$STAGE/Day Offload.app"
rm -rf build
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -target arm64-apple-macos14.0 ${SDK_ARGS[@]+"${SDK_ARGS[@]}"} "${SOURCES[@]}" -o "$STAGE/DayOffload-arm64"
swiftc -O -parse-as-library -target x86_64-apple-macos14.0 ${SDK_ARGS[@]+"${SDK_ARGS[@]}"} "${SOURCES[@]}" -o "$STAGE/DayOffload-x86_64"
lipo -create "$STAGE/DayOffload-arm64" "$STAGE/DayOffload-x86_64" -output "$APP/Contents/MacOS/DayOffload"
cp Icon/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>        <string>DayOffload</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleIdentifier</key>        <string>co.move-ment.dayoffload</string>
    <key>CFBundleName</key>              <string>Day Offload</string>
    <key>CFBundleDisplayName</key>       <string>Day Offload</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>Day Offload reads your camera cards to copy the shoot days you choose. It never changes or deletes anything on a card.</string>
    <key>NSHumanReadableCopyright</key>  <string>© 2026 move-ment · MIT licence</string>
</dict>
</plist>
PLIST

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)
PROFILE="${NOTARY_PROFILE:-peripheralspeed-notary}"
xattr -cr "$APP"
if [ -n "$IDENTITY" ] && xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "signing with: $IDENTITY"
    codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP"
    ditto -c -k --keepParent "$APP" build/notarize.zip
    echo "submitting to Apple notary service…"
    xcrun notarytool submit build/notarize.zip --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    rm build/notarize.zip
    echo "notarized and stapled."
else
    echo "no Developer ID identity + notary profile \"$PROFILE\" — ad-hoc signing"
    codesign --force --deep -s - "$APP"
fi

# RELEASE GATE: never let an app macOS would block become a release zip.
if ! spctl -a -t exec "$APP" >/dev/null 2>&1; then
    if [ "${ALLOW_ADHOC:-0}" != "1" ]; then
        echo "ERROR: the app is NOT Gatekeeper-acceptable (ad-hoc or not notarized)."
        echo "Run this on the Mac with the Developer ID certificate, or ALLOW_ADHOC=1 for a dev build."
        exit 1
    fi
    echo "WARNING: dev build — macOS will block this on other Macs (ALLOW_ADHOC=1)"
fi

ditto -c -k --keepParent "$APP" "build/DayOffload-$VERSION.zip"
cp "build/DayOffload-$VERSION.zip" build/DayOffload.zip   # stable name for the website's download button
echo "built: build/DayOffload-$VERSION.zip (+ build/DayOffload.zip)"
echo "app staged at: $APP"
