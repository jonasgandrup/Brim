#!/bin/bash
# Builds, signs with the hardened runtime, notarizes and staples a distributable zip.
# Requires a Developer ID Application certificate and a notarytool keychain profile:
#   xcrun notarytool store-credentials sense-notary --apple-id <id> --team-id <team>
#   SENSE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=sense-notary ./scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SENSE_SIGN_IDENTITY:?Set SENSE_SIGN_IDENTITY to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile name}"
SENSE_HARDENED=1 ./build.sh release
app="$PWD/dist/Sense.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
upload="$PWD/dist/Sense-$version-notarize.zip"
final="$PWD/dist/Sense-$version.zip"
rm -f "$upload" "$final"
/usr/bin/ditto -c -k --keepParent "$app" "$upload"
xcrun notarytool submit "$upload" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
/usr/bin/ditto -c -k --keepParent "$app" "$final"
rm -f "$upload"
spctl --assess --type execute --verbose "$app"
echo "Ready to distribute: $final"
