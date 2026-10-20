#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
configuration="${1:-release}"
if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
  echo "Usage: ./build.sh [debug|release]" >&2
  exit 2
fi
# Keep caches in the project so the CLI also works in restricted workspaces.
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox --build-system native --cache-path "$PWD/.build/spm-cache" --manifest-cache local -c "$configuration"
binary_directory="$(swift build --disable-sandbox --build-system native --cache-path "$PWD/.build/spm-cache" --manifest-cache local -c "$configuration" --show-bin-path)"
app="$PWD/dist/Sense.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_directory/Sense" "$app/Contents/MacOS/.Sense.build"
mv -f "$app/Contents/MacOS/.Sense.build" "$app/Contents/MacOS/Sense"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
if [[ -f Resources/Sense.icns ]]; then cp Resources/Sense.icns "$app/Contents/Resources/Sense.icns"; fi
printf 'APPL????' > "$app/Contents/PkgInfo"
# Developer ID / Apple Development can be supplied explicitly for distribution.
# Default local builds reuse one project-only certificate so the designated
# requirement stays stable across source changes and clean builds.
if [[ -n "${SENSE_SIGN_IDENTITY:-}" ]]; then
  sign_flags=(--force --sign "$SENSE_SIGN_IDENTITY")
  # SENSE_HARDENED=1 enables the hardened runtime and entitlements that notarization requires.
  if [[ "${SENSE_HARDENED:-0}" == "1" ]]; then
    sign_flags+=(--options runtime --timestamp --entitlements Resources/Sense.entitlements)
  fi
  codesign "${sign_flags[@]}" "$app"
else
  ./scripts/sign-local.sh "$app"
fi
codesign --verify --strict "$app"
echo "Built $app"
