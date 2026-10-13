# TV pairing deployment

The approved link is `https://iptv.florian-zug.de/tv/activate#pairing_token=<approval-token>`.
The device polling code stays on the TV. The fragment carries only the short-lived approval token; the browser keeps account tokens in memory and asks for an explicit Approve or Decline action after sign-in.

## Backend and hostname

Build and restart the backend using the existing Docker build context (`./backend`). The canonical approval page is embedded in the Go executable, so it does not need a separate static volume. Startup applies migration 9 automatically to the persistent SQLite database; back up the database before deployment. Existing TV sessions and `/api/v1/auth/tv/approve` remain compatible with older installed TVs.

The HTTPS reverse proxy for `iptv.florian-zug.de` must forward these paths to the backend without replacing them with the download page or redirecting them to a different hostname:

- `/tv/activate`
- `/api/v1/auth/tv/*` and the existing account-auth endpoints
- `/.well-known/apple-app-site-association`
- `/.well-known/assetlinks.json`

Serve the two association documents directly as JSON over trusted HTTPS, without sign-in or redirect requirements. The canonical page sends `no-store`, `no-referrer`, and a Content Security Policy that permits only its bundled script and same-origin API requests. Preserve those headers through the proxy.

Keep `docs/tv-login.html` published at its existing static URL. It handles old QR links containing `device_code` and asks for the code shown on the TV. Link-supplied `api_base` is ignored; the legacy page uses the fixed production API. The static page and embedded page share the same UI; update both files together when changing that UI.

## Environment

Retain a strong `JWT_SECRET`, persistent `DB_PATH`, and working SMTP settings for verified accounts. `TV_LOGIN_TTL_MINUTES` remains supported (default 10 minutes). Approval and decline require an authenticated, email-verified account.

Set `ANDROID_APP_SHA256` to the SHA-256 fingerprint of the certificate that actually signs the distributed Android application. Use the colon-separated, 32-byte fingerprint shown by `apksigner verify --print-certs path/to/release.apk`, or the **app signing certificate** from Play Console when using Play App Signing. Do not substitute an upload certificate or debug certificate. Comma-separated fingerprints support a certificate rotation overlap.

The default fingerprint is `B0:07:BE:2E:17:C7:48:75:08:78:D5:76:D6:76:D6:E8:CD:CA:13:D1:ED:A1:FF:AC:41:CA:03:49:FD:F0:59:7D`, verified on 2026-10-13 with Google’s `apksig` verifier against the signed [distributed GitHub APK](https://github.com/Speedy0197/iptvplayer/releases/latest/download/streampilot-android.apk). Override it if the distribution certificate changes.

With an explicitly invalid fingerprint configured, `/.well-known/assetlinks.json` deliberately returns HTTP 503 instead of publishing a guessed association. Apple association is configured for `FR7M4F46TP.com.flo.streampilot` and `/tv/activate`.

The Android manifest and iOS entitlements include the canonical host. Both platforms also register `streampilot://tv/activate` for the browser’s explicit Open in StreamPilot fallback. Flutter’s built-in route handler retains the request through sign-in and sanitizes route names. See the official [Android app-link](https://docs.flutter.dev/cookbook/navigation/set-up-app-links) and [iOS universal-link](https://docs.flutter.dev/cookbook/navigation/set-up-universal-links) setup references. Deploying these documents alone does not update an already installed release. App-store/release publication and production-host deployment remain separate operations.

## Logs and lookup limits

The backend no longer logs request URLs because polling, pairing and stream requests can contain secrets in their query strings. Password-reset and verification codes are also omitted when SMTP is unavailable. Configure the reverse proxy/CDN to log the path without query parameters, and never log Authorization headers or request bodies for auth endpoints. Older static QR links include a polling secret in their query string, making this especially important.

Manual-code lookup accepts exactly six digits and limits attempts to five per minute per socket peer, with a process-wide ceiling of 120 attempts per minute and bounded tracking memory. Forwarded-IP headers are deliberately ignored because they can be spoofed. If a reverse proxy fronts the backend, its users share that peer limit. For a larger deployment, enforce a trusted client-IP rate limit at the ingress and adjust the backend limiter deliberately; scanning the QR token does not consume manual-code attempts.

Pairing/account tokens should be kept out of browser analytics, screenshot automation and support logs. The page removes the original fragment/query from its current history entry, does not load third-party assets and clears the password after sign-in. The TV token has an independent random JWT ID and is removed from the temporary session when claimed.

## Verification

From the repository root:

```sh
GOCACHE=/tmp/streampilot-go-cache go -C backend test ./...
GOCACHE=/tmp/streampilot-go-cache go -C backend test -race ./...
GOCACHE=/tmp/streampilot-go-cache go -C backend vet ./...
node --test backend/web-tests/tv-activate.test.cjs
```

Go tests use fresh temporary SQLite databases and synthetic accounts. The Node suite exercises the actual page script, including an optional real-service check when `STREAMPILOT_TEST_ORIGIN` points at a local test backend seeded with the suite's synthetic account. Do not point that optional fixture check at production.

After deployment, check that the canonical page and both association documents are reachable through HTTPS, then verify a fresh TV scan on installed iOS and Android releases. Confirm the matching code and account before approval, test decline, and verify that claiming a request a second time fails. Device testing of OS app-link routing requires the correctly signed app and the deployed hostname.
