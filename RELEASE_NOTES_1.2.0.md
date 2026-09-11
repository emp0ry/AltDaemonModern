# AltDaemon Modern 1.2.0

- Fixed Apple ID sign-in failures caused by Apple rejecting GSA authentication
  requests whose `X-MMe-Client-Info` identifies the client as Xcode.
- AltStore Classic authentication now identifies the request as `com.apple.akd`,
  matching the current macOS authentication daemon.
- Retains bounded retries and accurate HTTP errors for transient Apple service
  failures.
- Retains persistent anisette identity, automatic provider failover, XPC
  receive-race fixes, stable iOS 26 installation, extension refresh support,
  and the Shortcuts self-refresh completion fix.

Built as a rootless `iphoneos-arm64` package for Dopamine environments.
