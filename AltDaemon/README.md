# AltDaemonModern

This fork repairs AltDaemon for rootless and Dopamine RootHide jailbreaks. Version 1.2.3 tries on-device AuthKit anisette first and retains the anisette v3 client as fallback. It preserves AltStore's existing XPC protocol, so compatible AltStore Classic builds do not need a protocol change.

Thanks to [ichitaso](https://github.com/ichitaso/AltDaemonModern) for the on-device anisette and authentication/retry fixes in 1.2.2, and the HTTP 503 fix and RootHide package in 1.2.3. See the [release notes](../RELEASE_NOTES_1.2.3.md) for validation details.

## What changed

- Tries on-device AuthKit anisette first; if it cannot produce the required data,
  falls back to an anisette v3 provider and Apple's MID provisioning flow.
- Uses the pinned Starscream 4.0.8 transport for daemon-safe WebSocket provisioning.
- Persists one stable random identifier and the associated `adi.pb` provisioning blob
  in an explicit daemon preferences suite, including across launchd restarts.
- Reprovisions once when the provider reports Apple error `-45061`; it never loops indefinitely.
- Retries only transient `get_headers` failures with a short bounded backoff.
- In v3 mode, automatically fails over between three HTTPS SideStore anisette endpoints and
  remembers the last endpoint that succeeded.
- Applies the compatibility client-info headers to both GSA authentication
  and developer-services requests. Since 2026-11-20 Apple's GSA edge answers
  HTTP 503 when the OS name is `macOS;`, so 1.2.3 sends `Mac OS X;` and rewrites
  `<macOS;` in any other GSA request.
- Includes an AltStore-only compatibility module for Classic 2.2.1 that updates
  its obsolete GSA authentication identity to `com.apple.akd`, retries transient
  Apple HTTP 429/5xx responses with bounded backoff, and reports an accurate
  service error instead of trying to parse an HTML error page as a property list.
- Handles retry-task creation on an invalidated URL session, with a fresh
  ephemeral-session fallback instead of an uncaught Objective-C exception.
- Serializes concurrent requests through a Swift actor.
- Replaces the polling semaphore in the XPC transport with a locked pending-read
  queue, preventing intermittent daemon crashes and lost-connection errors.
- Keeps MID, OTP, ADI, and Apple credentials out of logs.
- Fixes the Security.framework ownership bug by consuming Create/Copy results exactly once with `takeRetainedValue()`.
- Accepts canonical and valid team-prefixed AltStore code identifiers, as produced by common re-signing workflows.
- On iOS 26, falls back from the removed LaunchServices installer to InstallCoordination using the runtime `MIInstallOptions` object expected by that API. iOS 26 is supported in the current release.
- Stages AltStore self-refreshes before reporting the handoff complete, then waits
  briefly for App Intents to return their result before replacing AltStore. This
  prevents successful Shortcuts refreshes from being reported as helper-app
  communication failures.
- Includes daemon-specific target fixes needed to build current upstream source.

The minimum deployment target is iOS 15.0. Supported environments are Dopamine's standard rootless environment and Dopamine RootHide. The legacy RootHide Bootstrap is not tested.

## Build

Requirements:

- macOS with Xcode 15 or newer
- Git
- Network access for the pinned submodules and Swift packages

Run:

```sh
git clone --recursive <your-fork-url>
cd AltDaemonModern
scripts/build-altdaemon.sh
```

The script prints the path to an unsigned arm64 Mach-O. It intentionally does not install, package, or sign the daemon.

To build a signed Dopamine rootless package on a system with `ldid` and `dpkg-deb`:

```sh
scripts/build-rootless-deb.sh /path/to/AltDaemon /path/to/AltDaemonModern.deb
```

The package builder stages files under `/var/jb`, signs a private copy of the input binary, and includes the AGPL and third-party notices. It never changes the input binary.

To build a Dopamine RootHide package from the same binary:

```sh
scripts/build-roothide-deb.sh /path/to/AltDaemon /path/to/AltDaemonModern.deb
```

The RootHide package uses architecture `iphoneos-arm64e` and stages files relative to the jbroot instead of `/var/jb`. Because the jbroot path is randomized, `postinst` resolves it with `jbroot /` and writes the absolute daemon path into the LaunchDaemon plist before bootstrapping it. The daemon is also signed with `com.apple.private.security.no-sandbox` and the RootHide storage entitlements; without them RootHide sandboxes AltDaemon, the peer check on AltStore's connection is denied, and AltStore reports that AltServer could not be found. The version is read from the rootless `control`, so both packages stay in step.

## Configuration

By default, the daemon tries on-device AuthKit first. If that path fails, the
default v3 provider order is `https://ani.sidestore.io`,
`https://ani.sidestore.app`, then `https://ani.sidestore.zip`. The daemon tries
the next endpoint after a failure and remembers the last endpoint that worked.
A self-hosted anisette v3 server is recommended when possible because the
provider receives the random anisette identifier and ADI provisioning blob.

Public providers can be unavailable, rate-limit repeated new identities, or change independently of this repository. Keep the generated identifier stable; deleting it unnecessarily can trigger provisioning limits and invalidates its matching ADI blob.

Version 1.1.8 performs a one-time rotation only for daemon state created with the
obsolete client identity. This may cause Apple to request 2FA once. It does not
delete AltStore's account, database, installed-app records, or signing data.

The launchd environment may override these values:

| Variable | Purpose |
| --- | --- |
| `ALTDAEMON_ANISETTE_MODE` | `native` uses only on-device AuthKit; `v3` uses only the configured v3 providers; unset or any other value tries native first, then v3. |
| `ALTDAEMON_ANISETTE_URL` | One trusted anisette v3 base URL. Setting it disables public fallback. HTTPS is required by default. |
| `ALTDAEMON_ANISETTE_URLS` | Ordered comma-, semicolon-, or newline-separated anisette v3 URLs for automatic failover. |
| `ALTDAEMON_ANISETTE_CLIENT_INFO` | Override the v3 provider's client info without rebuilding. The AltStore compatibility module separately applies its GSA/developer-services headers. |
| `ALTDAEMON_ANISETTE_USER_AGENT` | Override the v3 provider's user agent without rebuilding. |
| `ALTDAEMON_ALLOW_INSECURE_ANISETTE=1` | Explicitly permit HTTP/WS, intended only for a trusted local server. |
| `ALTDAEMON_ANISETTE_STATE_SUITE` | Use a separate UserDefaults suite instead of the default `io.altstore.altdaemon`, mainly for isolated diagnostics. |

The same server URL, client info, and user agent can be stored under the UserDefaults keys declared at the top of `AnisetteDataManager.swift`.

## Redacted self-test

After signing a copy with the required entitlements, run it outside the live launchd job:

```sh
ALTDAEMON_ANISETTE_STATE_SUITE=io.altstore.altdaemon.selftest ./AltDaemon --self-test-anisette
```

The command prints only pass/fail and the lengths of MID/OTP. It never prints their values. Use a separate state suite so testing cannot invalidate the live daemon's provisioning state.

The AltStore compatibility module writes only request-path metadata, HTTP and
Apple status fields, content type, byte count, and retry timing to a bounded 64 KiB file in AltStore's temporary
container. It never records request bodies, response bodies, credentials,
anisette values, or Apple tokens.

## Security and trust

AltDaemon does not receive or transmit the user's Apple ID password. The native path obtains anisette through the device's AuthKit framework without using a public anisette server. When the v3 path is used, the provider participates in MID provisioning and receives an opaque random identifier and ADI blob. Apple-account authentication remains between AltStore/AltSign and Apple.

Do not add raw header logging. `X-Apple-I-MD`, `X-Apple-I-MD-M`, and `adi.pb` must be treated as authentication material. Public providers are an availability and trust dependency; self-hosting is preferable.

## Installation

The build product is unsigned. A rootless installation must be signed with the entitlements in `AltDaemon.entitlements`, installed as `/var/jb/usr/bin/AltDaemon`, and bootstrapped with the rootless plist at `AltDaemon/package/var/jb/Library/LaunchDaemons/com.rileytestut.altdaemon.plist`. Back up an existing executable and validate a separately named, signed copy with `--self-test-anisette` before replacing anything. The private AuthKit client entitlement for the on-device path is included since 1.2.2.

The standard build script does not create a `.deb` or modify a connected device. Packaging and installation are separate, explicit steps.
