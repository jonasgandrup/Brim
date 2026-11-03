#!/bin/bash
# Builds the download: a disk image with Brim and a shortcut to Applications, in dist/, which git ignores.
# It's signed with the project's own identity, so updates keep their privacy permissions, but it isn't notarized:
# macOS asks people to approve it the first time. With a paid Developer ID, scripts/release.sh makes a notarized build.
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh release
app="$PWD/dist/Brim.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
image="$PWD/dist/Brim-$version.dmg"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
/usr/bin/ditto "$app" "$staging/Brim.app"
ln -s /Applications "$staging/Applications"
rm -f "$image"
/usr/bin/hdiutil create -volname "Brim $version" -srcfolder "$staging" -format UDZO -quiet "$image"
/usr/bin/hdiutil verify -quiet "$image"
echo "Ready to upload: $image"
/usr/bin/shasum -a 256 "$image"
