# AltDaemon Modern 1.1.8

- Fixed Apple-ID login in AltStore Classic 2.2.1 by updating its obsolete GSA
  authentication user agent and enforcing the coherent anisette client tuple.
- Retries transient Apple authentication HTTP 429/500/502/503/504 responses
  three times with bounded 5, 15, and 30 second backoff.
- Replaces AltStore's misleading property-list format error with an accurate
  Apple-service HTTP error when all retries are exhausted.
- Persists one stable anisette machine identity across daemon restarts.
- Rotates stale state once when upgrading from the obsolete/incoherent Xcode
  11.2 client tuple; AltStore account and application data are untouched.
- Retains automatic anisette-provider failover and serialized provisioning.
- Retains the XPC receive-race fix for intermittent lost-connection errors.
- Retains stable iOS 26 InstallCoordination support.

Validated on a Dopamine rootless iPhone 13 mini running iOS 17.3.1. Apple-ID
authentication completed and AltStore 2.2.1 successfully refreshed AltStore,
Dopamine, and LiveContainer in one operation.
