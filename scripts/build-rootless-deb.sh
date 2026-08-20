#!/bin/sh

set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: $0 <unsigned-or-signed-AltDaemon> [output.deb]" >&2
    exit 64
fi

ALTDAEMON_REPOSITORY_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ALTDAEMON_INPUT_BINARY=$1
ALTDAEMON_DEB_OUTPUT=${2:-"$ALTDAEMON_REPOSITORY_ROOT/AltDaemonModern_1.1.5_iphoneos-arm64.deb"}
ALTDAEMON_LDID_TOOL=${ALTDAEMON_LDID_TOOL:-ldid}
ALTDAEMON_DPKG_DEB_TOOL=${ALTDAEMON_DPKG_DEB_TOOL:-dpkg-deb}
ALTDAEMON_PACKAGE_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/altdaemon-modern-package.XXXXXX")

cleanup()
{
    rm -rf -- "$ALTDAEMON_PACKAGE_STAGE"
}
trap cleanup EXIT HUP INT TERM

test -f "$ALTDAEMON_INPUT_BINARY"
command -v "$ALTDAEMON_LDID_TOOL" >/dev/null
command -v "$ALTDAEMON_DPKG_DEB_TOOL" >/dev/null

mkdir -p \
    "$ALTDAEMON_PACKAGE_STAGE/DEBIAN" \
    "$ALTDAEMON_PACKAGE_STAGE/var/jb/usr/bin" \
    "$ALTDAEMON_PACKAGE_STAGE/var/jb/Library/LaunchDaemons" \
    "$ALTDAEMON_PACKAGE_STAGE/var/jb/usr/share/doc/altdaemonmodern"

chmod 0755 "$ALTDAEMON_PACKAGE_STAGE"

cp "$ALTDAEMON_REPOSITORY_ROOT/AltDaemon/package/DEBIAN/control" "$ALTDAEMON_PACKAGE_STAGE/DEBIAN/control"
cp "$ALTDAEMON_REPOSITORY_ROOT/AltDaemon/package/DEBIAN/preinst" "$ALTDAEMON_PACKAGE_STAGE/DEBIAN/preinst"
cp "$ALTDAEMON_REPOSITORY_ROOT/AltDaemon/package/DEBIAN/postinst" "$ALTDAEMON_PACKAGE_STAGE/DEBIAN/postinst"
cp "$ALTDAEMON_REPOSITORY_ROOT/AltDaemon/package/DEBIAN/prerm" "$ALTDAEMON_PACKAGE_STAGE/DEBIAN/prerm"
cp "$ALTDAEMON_INPUT_BINARY" "$ALTDAEMON_PACKAGE_STAGE/var/jb/usr/bin/AltDaemon"
cp "$ALTDAEMON_REPOSITORY_ROOT/AltDaemon/package/var/jb/Library/LaunchDaemons/com.rileytestut.altdaemon.plist" "$ALTDAEMON_PACKAGE_STAGE/var/jb/Library/LaunchDaemons/com.rileytestut.altdaemon.plist"
cp "$ALTDAEMON_REPOSITORY_ROOT/LICENSE" "$ALTDAEMON_PACKAGE_STAGE/var/jb/usr/share/doc/altdaemonmodern/AGPL-3.0.txt"
cp "$ALTDAEMON_REPOSITORY_ROOT/AltDaemon/NOTICE.md" "$ALTDAEMON_PACKAGE_STAGE/var/jb/usr/share/doc/altdaemonmodern/NOTICE.md"

chmod 0755 "$ALTDAEMON_PACKAGE_STAGE/DEBIAN/preinst" "$ALTDAEMON_PACKAGE_STAGE/DEBIAN/postinst" "$ALTDAEMON_PACKAGE_STAGE/DEBIAN/prerm"
chmod 0755 "$ALTDAEMON_PACKAGE_STAGE/var/jb/usr/bin/AltDaemon"
chmod 0644 \
    "$ALTDAEMON_PACKAGE_STAGE/DEBIAN/control" \
    "$ALTDAEMON_PACKAGE_STAGE/var/jb/Library/LaunchDaemons/com.rileytestut.altdaemon.plist" \
    "$ALTDAEMON_PACKAGE_STAGE/var/jb/usr/share/doc/altdaemonmodern/AGPL-3.0.txt" \
    "$ALTDAEMON_PACKAGE_STAGE/var/jb/usr/share/doc/altdaemonmodern/NOTICE.md"

"$ALTDAEMON_LDID_TOOL" -S"$ALTDAEMON_REPOSITORY_ROOT/AltDaemon/AltDaemon.entitlements" "$ALTDAEMON_PACKAGE_STAGE/var/jb/usr/bin/AltDaemon"
"$ALTDAEMON_DPKG_DEB_TOOL" --build --root-owner-group "$ALTDAEMON_PACKAGE_STAGE" "$ALTDAEMON_DEB_OUTPUT"

echo "Built rootless package: $ALTDAEMON_DEB_OUTPUT"
