#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
test_options=()
developer_directory="$(xcode-select -p)"
framework_directory="$developer_directory/Library/Developer/Frameworks"
swift_binary="$(xcrun --find swift)"
testing_plugin="$(dirname "$swift_binary")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
# Swift 6.4 Command Line Tools ship Testing as a framework rather than a toolchain module.
if [[ -d "$framework_directory/Testing.framework" ]]; then
  test_options+=(-Xswiftc -F -Xswiftc "$framework_directory" -Xlinker -rpath -Xlinker "$framework_directory")
fi
if [[ -f "$testing_plugin" ]]; then
  test_options+=(-Xswiftc -load-plugin-library -Xswiftc "$testing_plugin")
fi
swift test --disable-sandbox --build-system native --cache-path "$PWD/.build/spm-cache" --manifest-cache local "${test_options[@]}"
