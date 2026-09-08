# AltDaemon Modern 1.1.9

- Fixed the false “Couldn’t communicate with a helper application” result from
  Shortcuts after an otherwise successful automatic refresh.
- AltStore self-refresh IPAs are copied to daemon-owned temporary storage before
  AltStore completes its operation, preventing cleanup and process termination
  from interrupting the final install.
- The daemon gives App Intents a short grace period to return success before it
  replaces AltStore. Other apps still wait for confirmed installation normally.
- Stale staged files are bounded and removed automatically.
- Retains Apple-ID authentication fixes, persistent anisette identity, provider
  failover, XPC receive-race fixes, and stable iOS 26 installation support.

Validated against AltStore Classic 2.2.1 on a Dopamine rootless iPhone 13 mini
running iOS 17.3.1.
