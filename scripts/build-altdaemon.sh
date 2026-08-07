#!/bin/sh

set -eu

ALTDAEMON_REPOSITORY_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ALTDAEMON_OPENSSL_ROOT="$ALTDAEMON_REPOSITORY_ROOT/Dependencies/AltSign/Dependencies/OpenSSL"
ALTDAEMON_DERIVED_DATA_DIR=${ALTDAEMON_DERIVED_DATA_DIR:-${TMPDIR:-/tmp}/AltDaemonModernDerivedData}
ALTDAEMON_PACKAGE_CACHE_DIR=${ALTDAEMON_PACKAGE_CACHE_DIR:-${TMPDIR:-/tmp}/AltDaemonModernPackages}

git -C "$ALTDAEMON_REPOSITORY_ROOT" submodule update --init --recursive Dependencies/AltSign

if [ ! -f "$ALTDAEMON_OPENSSL_ROOT/iphoneos/include/openssl/err.h" ]; then
    echo "error: pinned OpenSSL iPhoneOS headers are missing" >&2
    exit 1
fi

xcodebuild \
    -quiet \
    -workspace "$ALTDAEMON_REPOSITORY_ROOT/AltStore.xcworkspace" \
    -scheme AltDaemon \
    -configuration Release \
    -sdk iphoneos \
    -destination generic/platform=iOS \
    -derivedDataPath "$ALTDAEMON_DERIVED_DATA_DIR" \
    -clonedSourcePackagesDirPath "$ALTDAEMON_PACKAGE_CACHE_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    "HEADER_SEARCH_PATHS=\$(inherited) $ALTDAEMON_OPENSSL_ROOT/iphoneos/include" \
    "LIBRARY_SEARCH_PATHS=\$(inherited) $ALTDAEMON_OPENSSL_ROOT/iphoneos/lib" \
    build

echo "Built unsigned binary: $ALTDAEMON_DERIVED_DATA_DIR/Build/Products/Release-iphoneos/AltDaemon"
