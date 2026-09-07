# StreamPilot's Google Cast dependency

This directory contains the runtime sources of `flutter_chrome_cast` 1.4.8,
downloaded from https://pub.dev/api/archives/flutter_chrome_cast-1.4.8.tar.gz.
Upstream: https://github.com/felnanuke2/flutter_google_cast.

The original BSD-3-Clause license is retained in `LICENSE`. Example applications,
screenshots, videos and contributor tools are omitted.

StreamPilot maintains a local copy to remove native media/request logging that
can contain signed provider URLs, and to fix the native request/lifecycle
behavior needed by its casting coordinator. The app must use this path
dependency instead of the unpatched hosted package. Changes are documented
below as they are integrated.

## Local runtime patches (2026-09-07)

- Remove native and Dart print/debugPrint/Log calls across runtime sources; no URL redaction heuristics. Disable the iOS Cast SDK console logger, delegate and verbose filter.
- iOS initialization leaves discovery stopped and foreground resume disabled. The discovery manager's explicit start/stop methods retain control of scanning.
- Guard the process-wide iOS Cast singleton and register listeners idempotently across logout/login. Balanced listener cleanup and initialization guards preserve existing receiver sessions without starting discovery.
- Android load/play/pause/seek/stop now fail without a media client and complete Flutter results from Cast PendingResult callbacks, with ten-second cancellation deadlines and exactly-once completion. Client listener cleanup fails outstanding requests.
- iOS load/play/pause/seek/stop retain GCKRequest delegate waiters until completion/failure/abort, with ten-second deadlines and sanitized errors. Session end and cleanup release waiters and position timers.
- iOS suspended session events preserve device/session identity with a connecting wire state. Dart can distinguish reconnecting from a genuine ended session.
- Remove iOS last-sent content ID injection into receiver status. Only receiver media customData/contentID can establish a matching media identity.

The application adapter additionally uses a ten-second connection deadline with bounded native stop-casting cleanup, waits for ended events on disconnect, and ignores restored sessions until user intent. Source checks and mocked Flutter channel tests do not replace physical receiver or Xcode validation.
