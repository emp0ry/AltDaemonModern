# AltDaemon Modern 1.2.2

## Changes

- Addresses Apple authentication error `-80045` by trying on-device AuthKit anisette before the existing v3 providers.
- Applies updated client-info compatibility headers to both Apple authentication and developer-services requests.
- Prevents an AltStore authentication-retry crash caused by creating a task on an invalidated URL session, with a fresh-session fallback when needed.
- Adds bounded Apple authentication status diagnostics without recording raw request/response bodies, anisette values, or credentials.
- Retains the existing v3 provider fallback, XPC fixes, installation flow, and extension-refresh handling.

## Tested configuration

The same code was tested as `1.2.2+ios17.test1` on an iPhone 13 mini running iOS 17.3.1 with a standard Dopamine rootless jailbreak. The native-only anisette self-test passed as user `mobile`, and Refresh All succeeded after reopening AltStore. Apple authentication returned `ec=0` and `hsc=200`.

No Apple ID logout or anisette-state reset was required on that device. This does not guarantee success on every account, iOS version, or future Apple server change. The invalidated-session retry fallback was compiled and reviewed but was not separately fault-injection tested.

## Installation

Install `AltDaemonModern_1.2.2_iphoneos-arm64.deb` over the existing package, then fully close and reopen AltStore before trying Refresh All. The package targets standard Dopamine rootless environments; RootHide is not supported. Do not reset anisette state or sign out of Apple ID as a routine update step.

## Credits

Special thanks to [ichitaso](https://github.com/ichitaso/AltDaemonModern) for the on-device AuthKit anisette implementation and the 1.2.2 authentication and retry-crash fixes, ported from [commit 659f911](https://github.com/ichitaso/AltDaemonModern/commit/659f9111df92f1378c5dea9be652d2da7464f71e).

Thanks also to Riley Testut, AltStore, SideStore, and the other contributors. AltDaemon Modern remains open source under AGPL-3.0.
