#!/bin/sh

set -eu

ALTDAEMON_REPOSITORY_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ALTDAEMON_COMPAT_SOURCE="$ALTDAEMON_REPOSITORY_ROOT/Compatibility/AltStoreAuthCompat/Tweak.m"
ALTDAEMON_COMPAT_OUTPUT=${1:-"${TMPDIR:-/tmp}/AltStoreAuthCompat.dylib"}
ALTDAEMON_IPHONEOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
ALTDAEMON_CLANG=$(xcrun --sdk iphoneos --find clang)

mkdir -p "$(dirname -- "$ALTDAEMON_COMPAT_OUTPUT")"

"$ALTDAEMON_CLANG" \
    -arch arm64 \
    -dynamiclib \
    -fobjc-arc \
    -Os \
    -Wall \
    -Wextra \
    -Werror \
    -miphoneos-version-min=15.0 \
    -isysroot "$ALTDAEMON_IPHONEOS_SDK" \
    -framework Foundation \
    -install_name @rpath/AltStoreAuthCompat.dylib \
    "$ALTDAEMON_COMPAT_SOURCE" \
    -o "$ALTDAEMON_COMPAT_OUTPUT"

echo "Built unsigned compatibility module: $ALTDAEMON_COMPAT_OUTPUT"
