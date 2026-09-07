# Stream on TV

Open StreamPilot on your phone, choose a channel, and tap the Cast icon beside
search. Pick your TV or streaming box. You can also connect first and choose a
channel afterwards.

Use the installed iOS or Android phone app for native casting. The browser
preview does not discover or control receivers.

The phone keeps its Playlists, Groups, Channels and Player selector, search,
programme guide and mini-player. The Player page shows the TV's reported state
and sends playback controls to it. **Watch on phone** returns the selected
channel to your phone, preserving a recording's position when the receiver
supports seeking. For Google Cast, this stops the receiver directly. For
AirPlay, choose **iPhone** in Apple's system output picker before local
playback resumes. Dismissing that picker keeps the current output; iOS does not
provide a reliable public API to force an audio AirPlay disconnect
([Apple's guidance](https://developer.apple.com/forums/thread/810035)).
If iOS still has an AirPlay output selected after switching to Google Cast,
the same iPhone output-selection step is required before phone playback.

**Disconnect** stops playback and leaves the selected channel paused. For
AirPlay, the system output may still be selected until you change it in the
output picker.

## Receivers

| Receiver | Phone route | StreamPilot needed on TV? |
| --- | --- | --- |
| NVIDIA Shield, Chromecast, Google TV, TVs with Google Cast | Google Cast from iPhone or Android | No |
| Apple TV, smart TVs with AirPlay video support | AirPlay from iPhone | No |
| Other smart TVs and streaming boxes | Requires one of those receiver capabilities | Compatibility varies |

Keep the phone and receiver on the same local network and allow local-network
access when prompted. Android TV installations of StreamPilot remain local
players; the Cast sender control is for phones. The Google Cast dependency
requires iOS 15 or later.

The TV fetches the original stream. Its supported formats, codecs, source access
and (for adaptive streams) server configuration determine whether it can play.
A VU+ stream working on the phone does not establish TV compatibility. There is
no automatic cloud relay or format conversion. StreamPilot account tokens are
not sent to receivers; a provider URL itself may contain credentials needed to
play that selected source.

## Development verification

Verified on Windows with Flutter 3.41.7 / Dart 3.11.5 on 2026-09-07:
**112 Flutter tests passed**, full `flutter analyze` reported no issues, and
the Android debug APK built successfully. The reviewed corrections include
receiver switching, interrupted operations, native request failures, AirPlay
output confirmation, recording recovery, and compact/tall/large-text layouts.

The Flutter tests cover the controller, source detection, native channel
boundaries, local playback suppression and the actual mobile widgets. A rendered
widget preview uses sample channel/EPG data rather than a physical receiver.

The APK is at `flutter_app/build/app/outputs/flutter-apk/app-debug.apk`.
Validation used `--no-pub` after dependency resolution; Windows plugin symlink
setup was unavailable, but the Android build completed with the resolved local
package. Build tools and caches were isolated under the ignored `.superpowers`
directory.

Physical acceptance still needs an iPhone and an Android phone with a NVIDIA
Shield, plus an AirPlay video receiver. Check discovery/permissions, compatible
live streams, VU+ streams, recordings, channel changes, pause, return to phone,
stop, network loss and phone background/lock-screen behavior. An iOS build
requires Xcode on macOS.

| Device check | Expected result | Status |
| --- | --- | --- |
| iPhone → Shield; Android → Shield | Explicit discovery, compatible stream plays on TV, phone decoder pauses | Not run |
| iPhone → AirPlay video receiver | Native picker selects TV; playing appears only after external video output is confirmed | Not run |
| AirPlay picker cancellation, including an already selected system route | Existing playback and target remain unchanged | Not run |
| Watch on phone after AirPlay | Choose iPhone in the system picker; audio then resumes on the phone | Not run |
| AirPlay → Google Cast → Watch on phone | Any remaining AirPlay system output is cleared through the picker before local audio starts | Not run |
| Switch TVs while the old disconnect fails | Old receiver remains reachable in controls; no overlapping phone playback | Not run |
| Channel change while resolving or loading | Only the latest channel starts | Not run |
| Recording pause, seek and return | TV controls follow receiver state; supported position survives handback | Not run |
| Buffering and recording completion | Player status follows the receiver instead of remaining Playing | Not run |
| Stop/logout during connect or load | Late callbacks cannot restart playback | Not run |
| Sign out, sign in, then reopen Cast on iPhone | Existing native context is reused without a crash or unsolicited playback | Not run |
| Denied local-network access, Wi-Fi loss, app background/lock | Clear recovery state, no surprise phone audio | Not run |

Use both a known receiver-compatible stream and the household's actual IPTV
sources. Record the tested phone OS, receiver model/firmware, source format and
result; one successful source does not establish compatibility with all feeds.

The Cast runtime is kept locally under
`flutter_app/packages/flutter_chrome_cast`; its provenance and native patches
are documented in `STREAMPILOT_PATCHES.md` there.
