# StreamPilot UI and TV pairing

## Approved brief

Implement the eight UI proposal areas in the visual companion and the subsequent QR login design. The user accepted the proposals and explicitly requested implementation of everything on 13 October 2026. Preserve the existing playback engine, buffering policy, receiver recordings and TV remote navigation.

## Experience

- Watch opens in the channel browser with the current source and group visible. Mobile has labeled Watch, Favorites and Sources destinations; Account holds sign-out. Preserve browsing position across sections. Source/group selectors replace the four-step mobile pager; retain a deliberate way to open the player and return to channels.
- Desktop has a branded header, source switcher, compact search, labeled navigation, a collapsible group pane, a readable channel pane and a dominant player. Layout must fit the supported minimum window and tablet sizes without overflow.
- Channel rows keep readable two-line names, logos and a playing indicator. Quick favorites must not start playback. Programme subtitles may use already cached data; do not fetch EPG separately for every row.
- Favorites use content-sized saved groups and the remaining space for channels, with useful empty-state actions. Sources show last successful refresh and persistent inline update feedback. Add-source choices explain Xtream, M3U and VU+; optional guide setup is separated from required fields, with inline field validation.
- Playback visibly distinguishes connecting, buffering and unavailable states. Never show provider URLs or credentials as user-facing errors; sanitized technical details may be secondary. An error overlay must not expose functioning playback controls beneath it.
- Programme guide emphasizes On now, remaining time/progress and Up next. Programme details remain available. Receiver recording state is explicit, and cancellation requires an explicit confirmation/action rather than tapping a status checkmark.
- Search has a close action, channel/group and source filters, readable source/group subtitles, and exact/name-prefix/word-prefix results before incidental substring matches. Existing stable channel sorting breaks equal-relevance ties.
- TV keeps all existing three-column, focus-memory, held-OK and layered-Back behavior. Distinguish Playing from Guide for, and improve programme hierarchy and readable status messages.
- Sign-in, registration and recovery use a consistent compact branded card, autofill, labeled accessible controls and one recovery step at a time. The download page highlights the visitor's platform while retaining access to all downloads.

## TV pairing contract

Use the existing TV polling mechanism with a separate short-lived approval token. A new TV start returns `device_code`, `user_code`, `pairing_token`, `expires_at`, `poll_interval_seconds`. The device code remains only on the TV; it must not appear in QR URLs, app links or approval-page responses. Existing old-TV password/code approvals continue working.

Canonical HTTPS link: `https://iptv.florian-zug.de/tv/activate#pairing_token=<token>`. The fragment avoids transmitting the approval token in HTTP request URLs. App links/universal links open this screen in an installed app; a custom `streampilot://tv/activate?pairing_token=<token>` link is a browser fallback. The app accepts only these known host/path combinations and cannot change API origin from link data.

Public `GET /api/v1/auth/tv/session?pairing_token=<token>` returns `user_code`, `expires_at`, `status` (`pending`, `approved`, or `declined`), and `device_name` for a valid unclaimed session, without poll secrets or auth tokens. Public `POST /api/v1/auth/tv/lookup` with `{user_code}` returns the corresponding approval token for manual-code entry, subject to rate limiting and expiry. An authenticated `POST /api/v1/auth/tv/approve-session` with `{pairing_token}` uses the verified account from the bearer token and issues a distinct TV token. An authenticated `POST /api/v1/auth/tv/decline-session` with `{pairing_token}` declines the request. Polling handles decline, expiry and one-time claim atomically. Approval cannot transfer an already approved session to another account. Expired or claimed sessions cannot be approved.

On phone: scan -> show account/device/matching code -> explicit Approve or Decline -> completion. Reuse a valid app login; otherwise show sign-in, then resume the pending request. On browser: code is carried by the scanned request; authenticate once and approve using the resulting bearer token. Manual-code entry is available when there is no scanned token. Expired requests show rescan/generate-new instructions. Never copy the phone token into the TV or include an account token in a link.

Serve the canonical browser approval page and Apple/Android association assets from the same backend hostname. Apple team ID is `FR7M4F46TP`, bundle ID `com.flo.streampilot`. Android association uses a verified release-signing certificate fingerprint, never a guessed value. Prepare deployment configuration/documentation if the fingerprint cannot be recovered from existing signed artifacts. Host deployment and store/release publication are separate from this implementation request.

## Constraints and verification

Flutter/Dart constraints remain as pinned by pubspec; preserve Go's existing dependencies. Prefer built-in Flutter deep-link handling over a new runtime package. No real credentials, provider URLs or personal playlists in fixtures or captures. Tests cover pairing permissions, expiry, one-time claims, independent tokens, malformed links, sign-in resumption, source changes, large text, search relevance and existing TV behavior. Run the complete Flutter and Go suites, analysis, and visual QA with synthetic data on desktop/mobile/TV. The optional later product ideas (full timeline guide, persisted recent channels, custom ordering and a new recordings destination) are a separate expansion, not part of the concrete mockups.
