#!/bin/sh

set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: $0 <unsigned-or-signed-AltDaemon> [output.deb]" >&2
    exit 64
fi

ALTDAEMON_REPOSITORY_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ALTDAEMON_ROOTLESS_PACKAGE="$ALTDAEMON_REPOSITORY_ROOT/AltDaemon/package"
ALTDAEMON_ROOTHIDE_PACKAGE="$ALTDAEMON_REPOSITORY_ROOT/AltDaemon/package/roothide"
ALTDAEMON_VERSION=$(sed -n 's/^Version: //p' "$ALTDAEMON_ROOTLESS_PACKAGE/DEBIAN/control")
ALTDAEMON_INPUT_BINARY=$1
ALTDAEMON_DEB_OUTPUT=${2:-"$ALTDAEMON_REPOSITORY_ROOT/AltDaemonModern_${ALTDAEMON_VERSION}_iphoneos-arm64e.deb"}
ALTDAEMON_LDID_TOOL=${ALTDAEMON_LDID_TOOL:-ldid}
ALTDAEMON_DPKG_DEB_TOOL=${ALTDAEMON_DPKG_DEB_TOOL:-dpkg-deb}
ALTDAEMON_PACKAGE_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/altdaemon-modern-roothide.XXXXXX")
ALTDAEMON_COMPAT_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/altdaemon-modern-compat.XXXXXX")
ALTDAEMON_AUTH_COMPAT_BINARY=${ALTDAEMON_AUTH_COMPAT_BINARY:-"$ALTDAEMON_COMPAT_BUILD_DIR/AltStoreAuthCompat.dylib"}

cleanup()
{
    rm -rf -- "$ALTDAEMON_PACKAGE_STAGE" "$ALTDAEMON_COMPAT_BUILD_DIR"
}
trap cleanup EXIT HUP INT TERM

test -f "$ALTDAEMON_INPUT_BINARY"
command -v "$ALTDAEMON_LDID_TOOL" >/dev/null
command -v "$ALTDAEMON_DPKG_DEB_TOOL" >/dev/null

if [ ! -f "$ALTDAEMON_AUTH_COMPAT_BINARY" ]; then
    "$ALTDAEMON_REPOSITORY_ROOT/scripts/build-altstore-auth-compat.sh" "$ALTDAEMON_AUTH_COMPAT_BINARY"
fi

# roothide installs into a randomized jbroot, so files are staged relative to it (no /var/jb).
mkdir -p \
    "$ALTDAEMON_PACKAGE_STAGE/DEBIAN" \
    "$ALTDAEMON_PACKAGE_STAGE/usr/bin" \
    "$ALTDAEMON_PACKAGE_STAGE/Library/LaunchDaemons" \
    "$ALTDAEMON_PACKAGE_STAGE/Library/MobileSubstrate/DynamicLibraries" \
    "$ALTDAEMON_PACKAGE_STAGE/usr/share/doc/altdaemonmodern"

chmod 0755 "$ALTDAEMON_PACKAGE_STAGE"

sed \
    -e 's/^Architecture: .*/Architecture: iphoneos-arm64e/' \
    -e 's/^Description: Reliable rootless AltDaemon/Description: Reliable RootHide AltDaemon/' \
    -e 's/This fork targets standard Dopamine rootless jailbreaks\./This build targets RootHide jailbreaks./' \
    "$ALTDAEMON_ROOTLESS_PACKAGE/DEBIAN/control" > "$ALTDAEMON_PACKAGE_STAGE/DEBIAN/control"
sed 's|/var/jb/|/|g' \
    "$ALTDAEMON_ROOTLESS_PACKAGE/var/jb/Library/LaunchDaemons/com.rileytestut.altdaemon.plist" \
    > "$ALTDAEMON_PACKAGE_STAGE/Library/LaunchDaemons/com.rileytestut.altdaemon.plist"

cp "$ALTDAEMON_ROOTHIDE_PACKAGE/DEBIAN/preinst" "$ALTDAEMON_PACKAGE_STAGE/DEBIAN/preinst"
cp "$ALTDAEMON_ROOTHIDE_PACKAGE/DEBIAN/postinst" "$ALTDAEMON_PACKAGE_STAGE/DEBIAN/postinst"
cp "$ALTDAEMON_ROOTHIDE_PACKAGE/DEBIAN/prerm" "$ALTDAEMON_PACKAGE_STAGE/DEBIAN/prerm"
cp "$ALTDAEMON_INPUT_BINARY" "$ALTDAEMON_PACKAGE_STAGE/usr/bin/AltDaemon"
cp "$ALTDAEMON_AUTH_COMPAT_BINARY" "$ALTDAEMON_PACKAGE_STAGE/Library/MobileSubstrate/DynamicLibraries/AltStoreAuthCompat.dylib"
cp "$ALTDAEMON_REPOSITORY_ROOT/Compatibility/AltStoreAuthCompat/AltStoreAuthCompat.plist" "$ALTDAEMON_PACKAGE_STAGE/Library/MobileSubstrate/DynamicLibraries/AltStoreAuthCompat.plist"
cp "$ALTDAEMON_REPOSITORY_ROOT/LICENSE" "$ALTDAEMON_PACKAGE_STAGE/usr/share/doc/altdaemonmodern/AGPL-3.0.txt"
cp "$ALTDAEMON_REPOSITORY_ROOT/AltDaemon/NOTICE.md" "$ALTDAEMON_PACKAGE_STAGE/usr/share/doc/altdaemonmodern/NOTICE.md"

chmod 0755 "$ALTDAEMON_PACKAGE_STAGE/DEBIAN/preinst" "$ALTDAEMON_PACKAGE_STAGE/DEBIAN/postinst" "$ALTDAEMON_PACKAGE_STAGE/DEBIAN/prerm"
chmod 0755 "$ALTDAEMON_PACKAGE_STAGE/usr/bin/AltDaemon"
chmod 0755 "$ALTDAEMON_PACKAGE_STAGE/Library/MobileSubstrate/DynamicLibraries/AltStoreAuthCompat.dylib"
chmod 0644 \
    "$ALTDAEMON_PACKAGE_STAGE/DEBIAN/control" \
    "$ALTDAEMON_PACKAGE_STAGE/Library/LaunchDaemons/com.rileytestut.altdaemon.plist" \
    "$ALTDAEMON_PACKAGE_STAGE/Library/MobileSubstrate/DynamicLibraries/AltStoreAuthCompat.plist" \
    "$ALTDAEMON_PACKAGE_STAGE/usr/share/doc/altdaemonmodern/AGPL-3.0.txt" \
    "$ALTDAEMON_PACKAGE_STAGE/usr/share/doc/altdaemonmodern/NOTICE.md"

# roothide sandboxes the daemon otherwise, which blocks the peer check on AltStore's connection.
ALTDAEMON_ENTITLEMENTS="$ALTDAEMON_COMPAT_BUILD_DIR/AltDaemon-roothide.entitlements"
cp "$ALTDAEMON_REPOSITORY_ROOT/AltDaemon/AltDaemon.entitlements" "$ALTDAEMON_ENTITLEMENTS"
for ALTDAEMON_ENTITLEMENT in \
    com.apple.private.security.no-sandbox \
    com.apple.private.security.storage.AppBundles \
    com.apple.private.security.storage.AppDataContainers
do
    /usr/libexec/PlistBuddy -c "Add :$ALTDAEMON_ENTITLEMENT bool true" "$ALTDAEMON_ENTITLEMENTS"
done

"$ALTDAEMON_LDID_TOOL" -S"$ALTDAEMON_ENTITLEMENTS" "$ALTDAEMON_PACKAGE_STAGE/usr/bin/AltDaemon"
"$ALTDAEMON_LDID_TOOL" -S "$ALTDAEMON_PACKAGE_STAGE/Library/MobileSubstrate/DynamicLibraries/AltStoreAuthCompat.dylib"
"$ALTDAEMON_DPKG_DEB_TOOL" --build --root-owner-group "$ALTDAEMON_PACKAGE_STAGE" "$ALTDAEMON_DEB_OUTPUT"

echo "Built roothide package: $ALTDAEMON_DEB_OUTPUT"
