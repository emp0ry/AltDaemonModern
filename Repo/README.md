# Repository packages

`scripts/build-repo-debs.sh` builds the rootless and RootHide packages for the repository into this directory in one step.

## Requirements

- macOS with Xcode
- `ldid` and `dpkg-deb`

## Build

Run from the repository root:

```sh
# Reuse the AltDaemon binary from an existing package (when the daemon source is unchanged)
scripts/build-repo-debs.sh Repo/com.ichitaso.altdaemon_1.2.2_iphoneos-arm64.deb

# Use an AltDaemon binary you built
scripts/build-repo-debs.sh /path/to/AltDaemon

# Build AltDaemon first with scripts/build-altdaemon.sh
scripts/build-repo-debs.sh
```

## Output

| File | Jailbreak |
| --- | --- |
| `com.ichitaso.altdaemon_<version>_iphoneos-arm64.deb` | Dopamine rootless |
| `com.ichitaso.altdaemon_<version>_iphoneos-arm64e.deb` | Dopamine RootHide |

The version is read from `AltDaemon/package/DEBIAN/control`. To release a new version, update it there and in `Repo/control`, then run the script.

Both packages contain the same `AltStoreAuthCompat.dylib`. Only the RootHide package signs AltDaemon with the no-sandbox and storage entitlements. `.deb` files are ignored by git.
