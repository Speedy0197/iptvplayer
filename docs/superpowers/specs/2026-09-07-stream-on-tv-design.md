# Stream on TV design

Date: 2026-09-07

Status: mobile layout and technical design approved by the user on 2026-09-07.

## Intended outcome

Select a channel in StreamPilot, tap the Chromecast-style icon beside search,
and choose a television. The primary setup is iPhone to NVIDIA Shield. Android
phones must also be supported. Cover common televisions through Google Cast
and, on iPhone, AirPlay, without requiring StreamPilot to be installed on
compatible receivers.

This document defines real casting. The approved visual companion uses sample
channels and simulated devices and does not establish a TV connection.

## Approved mobile layout

Preserve the existing compact home screen in `flutter_app/lib/screens/home_screen.dart`:

- Keep `HomeSearchBar` in the app bar, using its existing search dialog.
- Add an icon-only `Icons.cast` action to the right of search. Its tooltip and
  accessibility label are `Stream on TV`. Use `Icons.cast_connected` and the
  active theme color while connected; include the device name in its label.
- Keep `CompactWatchSection` and its Playlists / Groups / Channels / Player
  strip. Inactive sections retain the existing icon-only presentation; the
  selected section displays its label.
- Keep the player card, channel name, group, and EPG.
- Keep `CompactMiniPlayerBar` and the existing Watch / Favorites / Playlists /
  Logout bottom navigation.
- Do not add a separate StreamPilot title bar or a large casting button below
  the video.
- Make the new icon available on iOS and Android phones. Hide the sender action
  on Android TV and desktop layouts; do not initialize mobile SDKs there.
- Verify the search field and Cast touch target at widths of 320, 390, and 430
  logical pixels, including increased text size.

## Receiver coverage

| Sender | Receiver route | Intended devices |
| --- | --- | --- |
| iPhone | Google Cast | NVIDIA Shield, Chromecast, Google TV, Cast-enabled TVs |
| Android phone | Google Cast | NVIDIA Shield, Chromecast, Google TV, Cast-enabled TVs |
| iPhone | AirPlay | Apple TV and AirPlay-enabled smart TVs |

Coverage depends on receiver capabilities, not a television brand alone.
An AirPlay-only TV is not a Google Cast target for an Android phone. Televisions
with neither supported protocol require a compatible receiver or a separate
receiver application. Universal support for every TV model or IPTV codec is
not a claim of this feature.

## Approach

Use the native Google Cast sender SDKs through a narrow Flutter adapter, with
Google's Default Media Receiver. The `flutter_chrome_cast` package is the
candidate bridge; inspect the selected package version and run dependency and
platform build checks before adopting it. The adapter must keep third-party
SDK types out of the UI and playback coordinator.

For iOS AirPlay, use Apple's `AVRoutePickerView` and an `AVPlayer`-based playback
path. The existing `media_kit` audio session's `allowAirPlay` setting is not a
complete implementation of remote video playback. Preserve `media_kit` for
ordinary local playback and desktop/TV behavior.

Alternatives considered:

1. A custom receiver installed on every TV offers tighter playback control but
   conflicts with the desired installation-free flow on compatible devices.
2. Adding DLNA immediately may cover additional televisions, but introduces a
   third discovery/control implementation and separate compatibility testing.
   It is not required for the Cast and AirPlay routes specified here.

## User flow

### Device selection

Tapping the header icon opens a bottom sheet titled `Stream on TV`.

On iPhone, show an AirPlay route-picker control plus discovered Google Cast
receivers. AirPlay selection must go through Apple's system picker; do not
invent a merged list of AirPlay and Cast devices or simulate taps on private
system controls. On Android, show the Google Cast receiver list.

Discovery starts when the user opens the sheet. Show a searching state followed
by discovered devices or an actionable empty state. Explain local-network
permission when requested and provide a retry action after a denial or network
change. Do not prompt for discovery permission during unrelated login or app
startup.

If no channel is selected, the sheet can connect a receiver and display
`Choose a channel to play on this TV`. It must not display a playing state.

### Handoff

Resolve the selected channel at playback time using
`PlaylistStore.resolveChannelStreamUrl`. Preserve the existing VU+ resolution
and recording behavior. Do not cast stale cached credentials or a stale channel
after the user changes their selection.

Record whether local playback was playing, its channel identity, and its
position when applicable. Pause the local decoder immediately before loading
the receiver to avoid duplicate audio and unnecessary simultaneous provider
connections. Confirm remote media status before declaring the transfer
successful. On failure, restore the previously active local playback when the
user has not stopped playback or selected a different channel.

Use monotonically increasing operation generations to ignore stale resolution,
connection, load, and reconnect completions. Stop, logout, a route change, or a
newer channel selection invalidates pending loads.

### While connected

Replace the video surface with receiver name and actual remote playback state.
Keep the channel information, EPG, and navigation in place. Route applicable
play/pause and stop controls to the active playback target. Only enable seeking
when supported by that stream and receiver.

Selecting another channel while connected sends it to the selected TV through
the same resolution and confirmation process. Preserve the existing behavior
of other browse actions; casting must not silently change playlist or group
selection semantics.

The header icon remains reachable from all compact browse pages. Reopening it
shows the active receiver and `Watch on iPhone` or `Watch on phone`. Returning to
the phone stops remote playback and resumes the selected channel locally. Use
the receiver's position for seekable recordings and the live edge for live TV.
Distinguish stopping playback from disconnecting a receiver.

Implementation clarification: iOS requires its public system output picker to
leave an AirPlay audio route. Confirm built-in phone output before restoring
local playback, including when an AirPlay route remains selected after a switch
to Google Cast. Picker cancellation keeps the current playback ownership.

### Interruptions

Show `Reconnecting` when the SDK reports a suspended connection. Do not treat a
temporary network failure as a successful disconnect or start phone audio
unexpectedly. If reconnection fails, offer retry and return-to-phone actions.

Reconcile resumed sessions against SDK-reported receiver and media state. Do
not overwrite content playing in a receiver session solely because the phone
still has a cached channel. Closing a picker must not stop an active cast.

## Stream compatibility and access

The TV downloads the stream directly. It must be able to reach the URL and
support its container, codecs, authentication, and delivery method. Identify
the media type from trustworthy source metadata or a bounded response probe;
do not label every IPTV URL as HLS based on guesswork.

Use HLS or another receiver-supported source as supplied by the provider. VU+
transport streams and recordings require explicit device testing; a stream
playing in `media_kit` does not establish that Cast or AirPlay can play it.
Report unsupported media or inaccessible URLs clearly and offer phone playback.

Do not silently add a cloud relay, upload a household receiver's credentials,
or introduce server transcoding. The existing public backend proxy only copies
bytes and does not convert formats or make private LAN receivers reachable.
If actual-device testing identifies required conversion, treat that as a
separate architecture decision with concrete resource and network requirements.

Stream URLs may contain provider or receiver credentials. Pass them only to the
selected playback route and never include them in logs, visible errors, device
labels, or analytics. Do not pass the StreamPilot account token to a TV merely
to play a provider URL. Do not disable certificate verification or broaden the
existing network policy as a workaround for casting failures.

## Implementation boundaries

Create a focused `lib/services/casting/` area containing:

- Route and playback state models independent of native SDK types.
- A Google Cast adapter owning SDK initialization, discovery, session events,
  media requests, and remote controls.
- An AirPlay adapter owning the iOS platform channel, route state, and native
  playback lifecycle.
- A casting coordinator owning operation generations, selected target,
  handoff, error recovery, and local/remote playback ownership.

Add small casting widgets under `lib/widgets/casting/` for the header action,
device sheet, and remote playback surface. Modify `HomeScreen`, `PlayerPane`,
`CompactMiniPlayerBar`, and `PlaylistStore` only at the integration points.

Add native iOS AirPlay implementation and registration compatible with the
project's implicit Flutter engine and `SceneDelegate`. Add the Cast SDK's
required iOS Bonjour/local-network declarations and Android configuration.
Preserve current package identity, signing, release workflow, and minimum
platform versions unless a verified dependency requires a documented change.

## Verification and acceptance

Automated behavioral tests must cover:

- Casting fails: local playback is restored without duplicate playback.
- Channel changes during URL resolution: stale content is never loaded.
- Stop or logout during connection: a late callback cannot start playback.
- Remote status is not yet confirmed: the UI does not claim `Playing on TV`.
- A remote pause updates controls without resuming the local decoder.
- Returning to the phone uses the correct live or recorded position.
- Discovery denial, no devices, initialization failure, and reconnect failure
  produce useful states without blocking the rest of the application.
- The header retains search and all compact navigation remains usable.
- Desktop and Android TV do not initialize unsupported mobile casting APIs.

Run the existing Flutter tests, the new targeted tests, `flutter analyze`, an
Android build, and an iOS build. Validate both Cast and AirPlay on physical
devices; emulator tests alone cannot establish receiver compatibility.

Physical acceptance matrix:

1. iPhone to NVIDIA Shield: discover, start a compatible live stream, change
   channel, pause when supported, return to phone, and stop.
2. Android to NVIDIA Shield: repeat the same flow.
3. iPhone to an AirPlay receiver: system picker, video handoff, control, and
   return to phone.
4. Test a representative M3U/Xtream stream, a VU+ live stream, and a seekable
   recording. Record actual results and any format/access limitations.
5. Deny discovery permission, disconnect Wi-Fi, suspend/resume the phone app,
   and reject or interrupt a media load. Confirm recovery and no surprise audio.

The current Windows workspace does not expose Flutter or Dart on PATH. Locate
an existing SDK or provision an isolated development toolchain before test
execution. iOS builds and real-device checks require the corresponding Apple
toolchain and devices. Record unexecuted checks explicitly.

## References

- [NVIDIA: devices that can cast to Shield](https://nvidia.custhelp.com/app/answers/detail/a_id/3681/~/what-devices-can-cast-to-shield-tv)
- [Google Cast receiver overview](https://developers.google.com/cast/docs/web_receiver)
- [Google Cast supported media](https://developers.google.com/cast/docs/media)
- [Apple: supporting AirPlay in an app](https://developer.apple.com/documentation/avfoundation/supporting-airplay-in-your-app)
- [Apple route picker](https://developer.apple.com/documentation/avkit/avroutepickerview)
- [Flutter Google Cast package](https://pub.dev/packages/flutter_chrome_cast)
