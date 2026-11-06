#!/bin/bash
# Builds the download: a disk image with Brim and a shortcut to Applications, in dist/, which git ignores.
# By default it's signed with the project's own identity, so updates keep their privacy permissions, but it isn't
# notarized: macOS asks people to approve it the first time. With BRIM_SIGN_IDENTITY set to a Developer ID, the app
# is signed for notarization and so is the image; scripts/release.sh then notarizes it.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "${BRIM_SIGN_IDENTITY:-}" ]]; then BRIM_HARDENED=1 ./build.sh release; else ./build.sh release; fi
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
if [[ -n "${BRIM_SIGN_IDENTITY:-}" ]]; then codesign --force --sign "$BRIM_SIGN_IDENTITY" --timestamp "$image"; fi
echo "Ready to upload: $image"
/usr/bin/shasum -a 256 "$image"
