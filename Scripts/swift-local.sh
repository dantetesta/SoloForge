#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
cache="$PWD/.build-local/modules"
mkdir -p "$cache"
export CLANG_MODULE_CACHE_PATH="$cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache"

sdk="$(xcrun --sdk macosx --show-sdk-path)"
if [[ "$sdk" == /Library/Developer/CommandLineTools/* && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
export SDKROOT="$sdk"

action="$1"
shift
if [[ "$action" == test ]]; then
    set -- --disable-xctest --enable-swift-testing "$@"
    macros="$(dirname "$(xcrun --find swiftc)")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
    if [[ -f "$macros" ]]; then
        set -- -Xswiftc -load-plugin-library -Xswiftc "$macros" "$@"
    fi
else
    set -- --build-system native "$@"
fi
exec swift "$action" --disable-sandbox --manifest-cache local --sdk "$sdk" \
    -Xswiftc -module-cache-path -Xswiftc "$cache" "$@"
