#!/bin/bash
# Rebuilds Icon/AppIcon.icns (and docs/icon.png) from makeicon.swift.
set -euo pipefail
cd "$(dirname "$0")"
T=$(mktemp -d)
swiftc -O makeicon.swift -o "$T/makeicon"
"$T/makeicon" "$T/AppIcon.iconset"
iconutil -c icns "$T/AppIcon.iconset" -o AppIcon.icns
cp "$T/AppIcon.iconset/icon_512x512@2x.png" ../docs/icon.png
rm -rf "$T"
echo "wrote Icon/AppIcon.icns"
