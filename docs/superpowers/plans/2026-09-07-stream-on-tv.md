# Stream on TV Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add the approved mobile Cast header action with real Google Cast and iPhone AirPlay playback.

**Architecture:** SDK-independent transport models feed a casting coordinator that owns transfer, cancellation, remote status, and local recovery. The Google Cast package and a native iOS AirPlay bridge implement the transport boundary. Existing home/player widgets consume coordinator state through PlaylistStore integration.

**Tech Stack:** Flutter 3.41.7, Dart 3.11, media_kit, flutter_chrome_cast 1.4.8, AVKit/AVFoundation.

**Spec:** `docs/superpowers/specs/2026-09-07-stream-on-tv-design.md`

## Global constraints

- Preserve the approved search, compact navigation, EPG, mini-player, and bottom navigation.
- Use Icons.cast / Icons.cast_connected beside search on mobile senders only.
- Discover on explicit picker opening; initialization must not request discovery during startup.
- Never log credential-bearing URLs or publish/account tokens to a receiver.
- Real receiver status determines playing, paused, and reconnecting state.
- Ignore stale media loads after channel change, stop, logout, or route change.
- No automatic cloud relay, transcoding, custom receiver, or publication.
- Keep current platform minimums unless the selected dependency actually requires a change.

## Shared transport contract

File: `flutter_app/lib/services/casting/cast_transport.dart`.

```dart
enum CastRouteKind { googleCast, airPlay }
enum CastPlaybackState {
  disconnected, connecting, connected, loading, playing, paused,
  reconnecting, failed,
}

class CastDevice {
  const CastDevice({required this.id, required this.name, required this.kind});
  final String id;
  final String name;
  final CastRouteKind kind;
}

class CastMedia {
  const CastMedia({required this.id, required this.url, required this.title,
    required this.contentType, this.imageUrl, this.isLive = true,
    this.position = Duration.zero});
  final String id;
  final String url;
  final String title;
  final String contentType;
  final String? imageUrl;
  final bool isLive;
  final Duration position;
}

class CastStatus {
  const CastStatus({required this.state, this.device, this.mediaId,
    this.position = Duration.zero, this.canSeek = false, this.error});
  final CastPlaybackState state;
  final CastDevice? device;
  final String? mediaId;
  final Duration position;
  final bool canSeek;
  final String? error;
}

abstract class CastTransport {
  CastRouteKind get kind;
  Stream<List<CastDevice>> get devices;
  Stream<CastStatus> get statuses;
  Future<void> initialize();
  Future<void> startDiscovery();
  Future<void> stopDiscovery();
  Future<void> connect(CastDevice device);
  Future<void> load(CastMedia media);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> stop();
  Future<void> disconnect();
  Future<void> dispose();
}
```

## Task 1: Playback coordination and local adapter

**Files:** Create `lib/services/casting/cast_transport.dart`, `casting_controller.dart`, `cast_media_resolver.dart`, `playlist_casting_binding.dart`. Modify `lib/services/playlist_store.dart` and `lib/widgets/channel_player.dart`. Test `test/casting_controller_test.dart` and `test/cast_media_resolver_test.dart`.

**Interfaces:** Consume CastTransport. Expose ChangeNotifier state and operations `startDiscovery`, `stopDiscovery`, `connect`, `beginAirPlaySelection`, `returnToPhone`, `pause`, `play`, `seek`, `stopPlayback`, `shutdown`, and `retry`. A separate local playback boundary resolves current media, pauses/resumes local output, and observes channel changes without exposing native SDK types.

- [x] Write failing controller tests using a fake external transport and real controller, including delayed URL resolution, failed load, stop during connect, confirmed remote status, paused resume, and returning a seekable recording to its remote position.
- [x] Run `flutter test test/casting_controller_test.dart` and record the expected missing-feature failure.
- [x] Implement generation cancellation, serialized side effects, remote load acknowledgment, bounded timeout, and local recovery. Keep controller-generated errors credential-free.
- [x] Write resolver tests using a local HTTP fixture or an injected HTTP client to verify HLS/MP4/transport stream classification, failed requests, timeouts, invalid schemes, and cancellation of probes. Use source extension only as a type hint, not a claim that all URLs are HLS.
- [x] Connect PlaylistStore and ChannelPlayer so a remote target suppresses local opening/resume/retry callbacks. Stop/logout must invalidate pending work before native callbacks complete.
- [x] Run the focused tests and existing channel resolution tests. Review the full state transition behavior before adding the UI.

## Task 2: Native Google Cast adapter

**Files:** Create `lib/services/casting/google_cast_transport.dart`; modify `pubspec.yaml`, Android manifest/activity configuration as required, iOS Info.plist/Podfile only for verified Cast requirements. Tests: `test/google_cast_transport_test.dart` where meaningful method-channel boundaries can be exercised.

**Interfaces:** Implement the shared CastTransport contract above; class `GoogleCastTransport` has a no-argument constructor. Only native SDK initialization happens in `initialize`; discovery is explicit. Store the domain media ID in receiver media custom data and recover it from remote status.

- [x] Inspect the downloaded 1.4.8 package source, including native platform configuration and discovery defaults.
- [x] Write a failing boundary test for the request/remote-status transformation; keep package types inside the adapter.
- [x] Use `GoogleCastDiscoveryCriteria.kDefaultApplicationId`; initialize with options that avoid startup discovery and prevent automatically stopping the remote session on process termination.
- [x] Implement discovery, selection, media loading, native request failure propagation, reconnect status, and remote controls. Do not treat successful request enqueueing as playback confirmation.
- [x] Add the exact Android metadata and iOS Bonjour declarations required by the package. Do not initialize on desktop or Android TV.
- [x] Run adapter tests and analyzer; document platform build limitations without claiming native playback validation.

## Task 3: Native iOS AirPlay adapter

**Files:** Create `lib/services/casting/airplay_transport.dart`, `lib/widgets/casting/airplay_route_picker.dart`, and `ios/Runner/AirPlayPlugin.swift`. Modify `ios/Runner/AppDelegate.swift` and project file membership if required.

**Interfaces:** `AirPlayTransport` implements CastTransport using method channel `streampilot/airplay` and event channel `streampilot/airplay/events`. `AirPlayRoutePicker` is a Flutter widget with `VoidCallback? onPickerOpening`, backed by native view type `streampilot/airplay/route_picker`. Its native control is a real AVRoutePickerView. Route selection emits connected status; playing status requires actual external video playback, not merely an AirPlay audio route.

- [x] Define and test the platform-channel event mapping and media payload, then implement the Swift bridge.
- [x] Register through the project's implicit engine delegate. Use public AVKit APIs and retain observations/tokens with explicit cleanup.
- [x] Support load/play/pause/seek/stop/disconnect, AVPlayer item failure, external playback status, route changes, and elapsed position.
- [x] Ensure picker cancellation preserves local playback and route loss does not cause unexpected local audio. Use native picker delegate callbacks to report user intent; do not synthesize private-control taps.
- [x] Keep any iOS background audio setting tied to active playback and document exactly what can be validated on Windows versus an Apple toolchain.

## Task 4: Approved UI and acceptance

**Files:** Create `lib/widgets/casting/cast_button.dart`, `cast_device_sheet.dart`, `cast_player_surface.dart`. Modify `main.dart`, `home_screen.dart`, `player_pane.dart`, `compact_mini_player_bar.dart`. Tests: `test/casting_widgets_test.dart`.

- [x] Write widget tests proving the header Cast action coexists with search at 320/390/430 pixels, and playing state is not shown while only connecting.
- [x] Add the native Cast icon beside search; preserve all current navigation controls. Keep the sheet open while discovery is pending, offer retry on failure, and support connecting with no channel selected.
- [x] Show AirPlay's native route control on iPhone. Show Cast receivers and the selected device with return-to-phone and disconnect actions.
- [x] Replace only the local video surface while remote playback owns the channel. Route controls to the active transport; preserve EPG and mini-player navigation.
- [x] Run focused tests, existing tests, `flutter analyze`, and available platform builds. Run a final cross-file review for stale callbacks, discovery during startup, token logging, and native lifecycle leaks.
- [x] Leave the worktree reviewable and report physical-device and iOS build checks that remain unexecuted. Do not publish releases or push code as part of this task.
