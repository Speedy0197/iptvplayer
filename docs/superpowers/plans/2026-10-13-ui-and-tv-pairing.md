# StreamPilot UI and TV pairing implementation plan

> **For agentic workers:** Use planning, parallel-agent dispatch for independent file ownership, TDD, and verification before completion. Integration and final review belong to the parent agent.

**Goal:** Implement the accepted UI proposals and scan-to-approve TV pairing across the existing Flutter app and Go service.

**Architecture:** Retain PlaylistStore and its media engine. Split work into independent server pairing, browsing surfaces, and player/guide domains; the parent implements account flows, app routing and platform association configuration, then integrates and verifies the complete app.

**Tech Stack:** Flutter/Dart, Go/SQLite, static HTML/JavaScript.

**Spec:** `docs/superpowers/specs/2026-10-13-ui-and-tv-pairing.md`.

## Global constraints

- Preserve the existing playback engine, buffering policy, receiver recordings and TV remote navigation.
- Flutter/Dart constraints remain as pinned by pubspec; preserve Go's existing dependencies.
- No real credentials, provider URLs or personal playlists in fixtures or captures.
- Device polling secrets remain only on the TV; app links use a separate expiring pairing token.
- An approval is an explicit user action by a verified authenticated account; TV tokens are distinct from phone tokens.
- Do not deploy, publish, push, or change external account permissions as part of implementation.

## Review focus

- An already signed-in phone opening a malicious/malformed link must not change API hosts or approve automatically.
- Pairing races, expired sessions and repeated claim/approval must not transfer an account or disclose a token twice.
- Switching source/group while watching must preserve playback identity and correctly attribute guide/recording actions.
- A narrow desktop/tablet and a phone with large text must have readable labels and no layout overflow.
- UI feedback must never expose raw stream/provider credential strings and must distinguish transient buffering from terminal failure.

### Task 1: Server pairing and web fallback

**Files:** Own backend auth handlers/migrations/routes/new backend assets, `docs/tv-login.html`, pairing deployment documentation. Do not edit Flutter or `docs/index.html`.

**Interfaces:** Produce the pairing HTTP endpoints and JSON fields defined in the spec. Keep current old-TV `/auth/tv/approve` and polling compatibility. Backend serves `/tv/activate`, `/.well-known/apple-app-site-association` and configured `/.well-known/assetlinks.json`.

- [x] Write handler tests using a fresh temporary SQLite database; prove unauthenticated/unverified approval fails, QR token cannot poll, authenticated approval generates an independent token, expiry/decline/repeated claim are handled, and concurrent approvals cannot reassign a session.
- [x] Run the tests and confirm missing behavior fails.
- [x] Add the migration, atomic pairing handlers, bounded/rate-limited code lookup, canonical browser page and association serving. Preserve old QR links through the legacy static page.
- [x] Run `GOCACHE=/tmp/streampilot-go-cache go test ./...` and `go vet ./...`; check web JavaScript syntax and exercise the page against a local test service.
- [x] Report edited files, exact test evidence and deployment prerequisites.

### Task 2: Browsing, Favorites, Sources and Search

**Files:** Own `home_screen.dart`, home navigation/source/group/compact/Favorites/source-management widgets, `dialogs/playlist_dialog.dart`, `search_result_tile.dart`, and tests specific to these widgets. Do not edit `main.dart`, account screens, player/guide files, ChannelsPane or PlaylistStore.

**Interfaces:** Continue consuming PlaylistStore's existing fields and methods; search uses the existing `filterChannels`/`filterGroups` APIs, whose relevance ranking Task 3 improves. Keep HomeSection values compatible. Account navigation can push the new `AccountScreen` provided by Task 4.

- [x] Write tests proving readable destinations, retained selection/page state, source switching without unintended tuning, content-sized Favorites and accessible source/search actions.
- [x] Confirm expected failures before changing behavior.
- [x] Implement branded desktop header/source selector/responsive panes, mobile source/group/channel browsing and labeled navigation, flexible Favorites, source refresh state/date, explained source choices and validation, and filtered/closable search.
- [x] Run focused widget tests and format/analyze owned files; report any cross-task integration requirements.

### Task 3: Player, guide, channel rows and relevance

**Files:** Own `widgets/channel_player.dart`, `home/widgets/player_pane.dart`, `home/widgets/channels_pane.dart`, `home/widgets/compact_mini_player_bar.dart`, TV programme/home visual refinements, `services/playlist_search.dart`, new focused helpers and their tests. Do not edit HomeScreen, account/main/routing, PlaylistStore or management/Favorites widgets.

**Interfaces:** Existing widget constructors and store APIs remain compatible. Export any reusable pure error/programme-presentation helpers with focused tests. Keep existing channel sort as relevance tie-breaker.

- [x] Write tests for readable URL-free player errors, buffering vs connecting UI, accurate programme progress/Now/Next, explicit recording cancellation, quick favorites without playback, and exact/prefix/word ranking before incidental substrings.
- [x] Run failing tests before implementation.
- [x] Implement states and programme hierarchy, maintain fullscreen error/focus behavior, polish TV identity labels, and use only already cached programme metadata in row subtitles.
- [x] Run focused tests plus existing channel/TV/player regression tests; format/analyze owned files and report results.

### Task 4: Account, incoming links and download page (parent)

**Files:** Own `main.dart`, `config/app_config.dart`, account/login/register/recovery/pairing screens, pairing models/services, iOS/Android link configuration, `docs/index.html`, and focused tests. Parent integrates cross-task changes in PlaylistStore only if necessary.

**Interfaces:** Pairing screen uses AuthStore/ApiClient and Task 1's endpoints. Deep links recognize only the canonical host/path and the documented custom scheme. Login resumption keeps the pairing token out of logs and awaits initialized auth state.

- [x] Add link-parser and pairing-screen tests for malformed/untrusted hosts, valid signed-in approval, decline/expiry, and logged-out sign-in resumption. Observe RED.
- [x] Implement safe incoming-route handling, account screen and consistent authentication cards, autofill and stepped recovery. Update TV QR generation to use only the new pairing token. Configure verified link associations and browser custom-link fallback.
- [x] Highlight detected platform on the download page without hiding the other downloads.
- [x] Run focused tests and verify native configuration/build diagnostics.

### Task 5: Integration, captures and review

- [x] Run full Flutter tests/analyzer and Go tests/vet. Resolve all regressions.
- [x] Render the actual Flutter components with synthetic content at phone, tablet, minimum desktop and TV sizes; capture and inspect output, including large text.
- [x] Exercise new backend pairing and browser fallback end to end locally; verify no QR or page response exposes the polling secret or account token.
- [x] Request a fresh whole-change review, address important findings, rerun affected verification, and deliver the implementation with captures and any publication prerequisites.

## Final integration evidence — 2026-10-13

Implementation is complete locally. The accepted scope is implemented; deployment and signed release publication remain separate operations.

- Baseline Flutter suite: 74/74 passed before changes.
- Final complete Flutter suite: 135/135 passed (`flutter test --no-pub --reporter expanded`), including cold/warm native route dispatch, source deletion identity, private source errors, password recovery, retained playback state, remote navigation and layout regressions. Log: `/tmp/streampilot-final-full-flutter.log`.
- Final Flutter analysis: no issues. Log: `/tmp/streampilot-final-analysis.log`.
- Actual Flutter capture/layout suite: 8/8 passed at phone 390×844, phone 320×700 with 160% text, tablet 768×1024, desktop 1440×900, minimum desktop 901×640 with 160% text, TV 1280×720 and TV with 160% text. Account/pairing captures also use enlarged text. Native video output is replaced with a fixture; all UI widgets and stores are real. Log: `/tmp/streampilot-final-captures.log`.
- Go: all 19 handler tests passed, race checks and vet passed. Browser script: 6/6 passed; the backend agent additionally verified 7/7 against a localhost SQLite service with synthetic accounts.
- iOS arm64 simulator compilation succeeded via Xcode with `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES IPHONEOS_DEPLOYMENT_TARGET=15.0 CODE_SIGNING_ALLOWED=NO`. The plain Flutter simulator command encountered the local Xcode/Flutter framework architecture check and the Flutter pod’s older target; explicit build settings verified the app without changing the project’s existing iOS 15 minimum. Log: `/tmp/streampilot-ios-compatible-build.log`.
- Android release certificate was verified cryptographically with Google’s apksig verifier against the distributed GitHub APK. The verified certificate is the backend default and can be overridden for certificate rotation; see `docs/TV_PAIRING_DEPLOYMENT.md`.
- Initial independent reviews found player lifecycle, source deletion, raw source errors, native URL normalization, refresh metadata, recovery resend and enlarged TV row issues. Reproduced defects were fixed and tested. A fresh read-only review of all fixes returned no remaining findings.
- Native XML/plist configuration and Git whitespace checks passed. No remote deployment, publication, push or real-account changes occurred.

Captures are in `.superpowers/sdd/2026-10-13-ui-and-tv-pairing/captures/`. The visual companion now displays actual implementation captures. Physical OS app-link association still requires deploying the hostname endpoints and distributing the newly signed app build; the deployment document records those prerequisites.
