# AltDaemon Modern 1.2.3

## Changes

- Fixes the HTTP 503 that Apple's authentication server began returning on 2026-11-20 for AltStore sign-in, refresh, and installation. Apple's GSA edge now rejects `X-MMe-Client-Info` values whose OS name is `macOS;`. The AltStore compatibility module now sends `Mac OS X;`, and rewrites `<macOS;` in any other GSA request, such as values supplied by an anisette v3 server.
- Adds a Dopamine RootHide package, `AltDaemonModern_1.2.3_iphoneos-arm64e.deb`, built with the new `scripts/build-roothide-deb.sh`.
  - Files are staged relative to the jbroot instead of `/var/jb`.
  - `postinst` resolves the randomized jbroot with `jbroot /` and writes the absolute daemon path into the LaunchDaemon plist before bootstrapping it.
  - AltDaemon is signed with `com.apple.private.security.no-sandbox` and the RootHide storage entitlements. Without them RootHide sandboxes the daemon, which denies the peer check on AltStore's connection and makes AltStore report that AltServer could not be found.
- The AltDaemon binary is unchanged from 1.2.2. Only the compatibility module and packaging changed.

## Tested configurations

- iPad (7th generation), iPadOS 18.3.2, Dopamine rootless: before the fix, every `GsService2` request returned a 190-byte HTML 503. With 1.2.3 the requests returned `hsc=200` with `ec=0`, and Refresh All succeeded.
- iPhone 11 Pro, iOS 26.0.1, Dopamine RootHide: the package installed and upgraded cleanly, the daemon started with both Mach services active, and Refresh All succeeded.

This does not guarantee success on every account, iOS version, or future Apple server change. The legacy RootHide Bootstrap was not tested.

## Installation

- Dopamine rootless: install `AltDaemonModern_1.2.3_iphoneos-arm64.deb` over the existing package.
- Dopamine RootHide: install `AltDaemonModern_1.2.3_iphoneos-arm64e.deb`.

Then fully close and reopen AltStore before trying Refresh All. Do not reset anisette state or sign out of Apple ID as a routine update step.

## Credits

Thanks to [ichitaso](https://github.com/ichitaso/AltDaemonModern) for the 503 fix and the RootHide package, and to the LiveContainer and SideStore communities for isolating the `macOS;` client-info change.

Thanks also to Riley Testut, AltStore, SideStore, and the other contributors. AltDaemon Modern remains open source under AGPL-3.0.
