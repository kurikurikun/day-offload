#!/bin/bash
# One-command release, run on the Mac with the Developer ID certificate:
#
#   ./release.sh 1.1 "What changed in this version"
#
# Pulls the latest code, sets the version, builds + notarizes (make-app.sh,
# which refuses anything macOS would block), tags vX.Y and publishes a GitHub
# Release with both DayOffload-X.Y.zip and DayOffload.zip (the website's
# download button needs the second name). Needs the GitHub CLI once:
#   brew install gh && gh auth login
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
NOTES="${2:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "usage: ./release.sh 1.1 \"what changed\"" >&2; exit 1; }
[ -n "$NOTES" ] || { echo "Please add a short description of what changed, in quotes." >&2; exit 1; }
command -v gh >/dev/null || { echo "The GitHub CLI isn't installed. Run once:  brew install gh && gh auth login" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not signed in to GitHub. Run once:  gh auth login" >&2; exit 1; }

git diff --quiet && git diff --cached --quiet || { echo "There are uncommitted changes here — commit or discard them first." >&2; exit 1; }
git pull --ff-only -q origin main
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || git ls-remote --exit-code --tags origin "v$VERSION" >/dev/null 2>&1; then
    echo "v$VERSION already exists. Pick a new version number." >&2; exit 1
fi

# Set the version (single source of truth) and commit it if it changed.
sed -i '' "s/static let version = \"[^\"]*\"/static let version = \"$VERSION\"/" Sources/DayOffload.swift
if ! git diff --quiet; then
    git commit -q -am "Version $VERSION"
    git push -q origin main
fi

./make-app.sh

git tag "v$VERSION"
git push -q origin "v$VERSION"
gh release create "v$VERSION" "build/DayOffload-$VERSION.zip" build/DayOffload.zip \
    --title "v$VERSION" \
    --notes "$NOTES

macOS 14 or later · Apple Silicon & Intel · notarized by Apple. Unzip, drag **Day Offload.app** to Applications, open."

echo
echo "Released v$VERSION — https://github.com/kurikurikun/day-offload/releases/tag/v$VERSION"
echo "The download button on move-ment.co/day-offload now gives this version."
