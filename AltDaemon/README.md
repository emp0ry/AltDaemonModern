# AltDaemonModern

This fork repairs AltDaemon for rootless jailbreaks and replaces its obsolete 2020 private-AuthKit anisette generator with an anisette v3 client. It preserves AltStore's existing XPC protocol, so compatible AltStore Classic builds do not need a protocol change.

## What changed

- Uses an anisette v3 provider and Apple's current MID provisioning flow.
- Uses the pinned Starscream 4.0.8 transport for daemon-safe WebSocket provisioning.
- Persists one stable random identifier and the associated `adi.pb` provisioning blob
  in an explicit daemon preferences suite, including across launchd restarts.
- Reprovisions once when the provider reports Apple error `-45061`; it never loops indefinitely.
- Retries only transient `get_headers` failures with a short bounded backoff.
- Automatically fails over between three HTTPS SideStore anisette endpoints and
  remembers the last endpoint that succeeded.
- Uses a coherent current model/macOS/Xcode client identity instead of mixing a
  current macOS version with the obsolete Xcode 11.2 build identifier.
- Includes an AltStore-only compatibility module for Classic 2.2.1 that updates
  its obsolete GSA authentication user agent, retries transient Apple HTTP
  429/5xx responses with bounded backoff, and reports an accurate service error
  instead of trying to parse an HTML error page as a property list.
- Serializes concurrent requests through a Swift actor.
- Replaces the polling semaphore in the XPC transport with a locked pending-read
  queue, preventing intermittent daemon crashes and lost-connection errors.
- Keeps MID, OTP, ADI, and Apple credentials out of logs.
- Fixes the Security.framework ownership bug by consuming Create/Copy results exactly once with `takeRetainedValue()`.
- Accepts canonical and valid team-prefixed AltStore code identifiers, as produced by common re-signing workflows.
- On iOS 26, falls back from the removed LaunchServices installer to InstallCoordination using the runtime `MIInstallOptions` object expected by that API. iOS 26 is supported in the current release.
- Includes daemon-specific target fixes needed to build current upstream source.

The minimum deployment target is iOS 15.0. The primary target is Dopamine's standard rootless environment; RootHide is not currently supported.

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

## Configuration

The default provider order is `https://ani.sidestore.io`,
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
| `ALTDAEMON_ANISETTE_URL` | One trusted anisette v3 base URL. Setting it disables public fallback. HTTPS is required by default. |
| `ALTDAEMON_ANISETTE_URLS` | Ordered comma-, semicolon-, or newline-separated anisette v3 URLs for automatic failover. |
| `ALTDAEMON_ANISETTE_CLIENT_INFO` | Override `X-Mme-Client-Info` without rebuilding. |
| `ALTDAEMON_ANISETTE_USER_AGENT` | Override the AuthKit user agent without rebuilding. |
| `ALTDAEMON_ALLOW_INSECURE_ANISETTE=1` | Explicitly permit HTTP/WS, intended only for a trusted local server. |
| `ALTDAEMON_ANISETTE_STATE_SUITE` | Use a separate UserDefaults suite instead of the default `io.altstore.altdaemon`, mainly for isolated diagnostics. |

The same server URL, client info, and user agent can be stored under the UserDefaults keys declared at the top of `AnisetteDataManager.swift`.

## Redacted self-test

After signing a copy with the required entitlements, run it outside the live launchd job:

```sh
ALTDAEMON_ANISETTE_STATE_SUITE=io.altstore.altdaemon.selftest ./AltDaemon --self-test-anisette
```

The command prints only pass/fail and the lengths of MID/OTP. It never prints their values. Use a separate state suite so testing cannot invalidate the live daemon's provisioning state.

The AltStore compatibility module writes only HTTP status, content type, byte
count, and retry timing to a bounded 64 KiB file in AltStore's temporary
container. It never records request bodies, response bodies, credentials,
anisette values, or Apple tokens.

## Security and trust

AltDaemon does not receive or transmit the user's Apple ID password. The anisette provider participates in MID provisioning and receives an opaque random identifier and ADI blob. Apple-account authentication remains between AltStore/AltSign and Apple.

Do not add raw header logging. `X-Apple-I-MD`, `X-Apple-I-MD-M`, and `adi.pb` must be treated as authentication material. Public providers are an availability and trust dependency; self-hosting is preferable.

## Installation

The build product is unsigned. A rootless installation must be signed with the entitlements in `AltDaemon.entitlements`, installed as `/var/jb/usr/bin/AltDaemon`, and bootstrapped with the rootless plist at `AltDaemon/package/var/jb/Library/LaunchDaemons/com.rileytestut.altdaemon.plist`. Back up an existing executable and validate a separately named, signed copy with `--self-test-anisette` before replacing anything. The obsolete private AuthKit entitlement is intentionally absent because the v3 implementation does not load AuthKit.

The standard build script does not create a `.deb` or modify a connected device. Packaging and installation are separate, explicit steps.
