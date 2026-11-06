#!/bin/bash
# Builds the download disk image signed with a Developer ID, has Apple notarize it, and staples the ticket to it, so
# it opens without the "unidentified developer" warning, even offline.
# Needs a paid Apple Developer membership, a Developer ID Application certificate in the keychain, and a notarytool
# profile saved once (it asks for an app-specific password):
#   xcrun notarytool store-credentials brim-notary --apple-id <apple-id> --team-id <team-id>
#   BRIM_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=brim-notary ./scripts/release.sh
# A Developer ID is a different signature from the local one, so people updating from a locally signed build are
# asked for Accessibility and Screen Recording once more. After that it stays stable.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${BRIM_SIGN_IDENTITY:?Set BRIM_SIGN_IDENTITY to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile name}"
./scripts/package.sh
app="$PWD/dist/Brim.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
image="$PWD/dist/Brim-$version.dmg"
xcrun notarytool submit "$image" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$image"
spctl --assess --type open --context context:primary-signature --verbose "$image"
echo "Ready to distribute: $image"
/usr/bin/shasum -a 256 "$image"
