#!/bin/sh

set -eu

if [ "$#" -gt 1 ]; then
    echo "usage: $0 [AltDaemon binary | existing AltDaemon .deb]" >&2
    echo "Without an argument, AltDaemon is built with scripts/build-altdaemon.sh." >&2
    exit 64
fi

ALTDAEMON_REPOSITORY_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ALTDAEMON_REPO_DIR="$ALTDAEMON_REPOSITORY_ROOT/Repo"
ALTDAEMON_VERSION=$(sed -n 's/^Version: //p' "$ALTDAEMON_REPOSITORY_ROOT/AltDaemon/package/DEBIAN/control")
ALTDAEMON_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/altdaemon-modern-repo.XXXXXX")

cleanup()
{
    rm -rf -- "$ALTDAEMON_WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

if [ "$#" -eq 0 ]; then
    "$ALTDAEMON_REPOSITORY_ROOT/scripts/build-altdaemon.sh"
    ALTDAEMON_BINARY="${ALTDAEMON_DERIVED_DATA_DIR:-${TMPDIR:-/tmp}/AltDaemonModernDerivedData}/Build/Products/Release-iphoneos/AltDaemon"
else
    case "$1" in
        *.deb)
            dpkg-deb -x "$1" "$ALTDAEMON_WORK_DIR/source"
            ALTDAEMON_BINARY=$(find "$ALTDAEMON_WORK_DIR/source" -path '*/usr/bin/AltDaemon' -type f | head -n 1)
            ;;
        *)
            ALTDAEMON_BINARY=$1
            ;;
    esac
fi

if [ -z "$ALTDAEMON_BINARY" ] || [ ! -f "$ALTDAEMON_BINARY" ]; then
    echo "error: AltDaemon binary not found" >&2
    exit 1
fi

# Build the compatibility module once so both packages ship the same dylib.
export ALTDAEMON_AUTH_COMPAT_BINARY="$ALTDAEMON_WORK_DIR/AltStoreAuthCompat.dylib"
"$ALTDAEMON_REPOSITORY_ROOT/scripts/build-altstore-auth-compat.sh" "$ALTDAEMON_AUTH_COMPAT_BINARY"

ALTDAEMON_ROOTLESS_DEB="$ALTDAEMON_REPO_DIR/com.ichitaso.altdaemon_${ALTDAEMON_VERSION}_iphoneos-arm64.deb"
ALTDAEMON_ROOTHIDE_DEB="$ALTDAEMON_REPO_DIR/com.ichitaso.altdaemon_${ALTDAEMON_VERSION}_iphoneos-arm64e.deb"

"$ALTDAEMON_REPOSITORY_ROOT/scripts/build-rootless-deb.sh" "$ALTDAEMON_BINARY" "$ALTDAEMON_ROOTLESS_DEB"
"$ALTDAEMON_REPOSITORY_ROOT/scripts/build-roothide-deb.sh" "$ALTDAEMON_BINARY" "$ALTDAEMON_ROOTHIDE_DEB"

echo
echo "Repo packages ($ALTDAEMON_VERSION):"
for ALTDAEMON_DEB in "$ALTDAEMON_ROOTLESS_DEB" "$ALTDAEMON_ROOTHIDE_DEB"
do
    echo "  $(basename -- "$ALTDAEMON_DEB")  $(dpkg-deb -f "$ALTDAEMON_DEB" Architecture)"
done
