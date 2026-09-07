# TV Channel Browser Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the independent store task, with local integration and review. Steps use checkbox syntax for tracking.

**Goal:** Deliver approved option A as a dedicated Android TV home flow.

**Architecture:** Separate TV browsing state from the store-owned playing stream. A remote list handles directional movement and logical selection; the TV home arranges groups, channels and preview, and requests fullscreen from the existing player.

**Tech Stack:** Flutter 3.41.7, Dart 3.11.5, Provider, media_kit.

**Spec:** `docs/superpowers/specs/2026-09-07-tv-channel-browser-design.md`

## Global Constraints

- Flutter 3.41.7 / Dart 3.11.5, as pinned by the project; no new runtime dependencies.
- Android TV selection takes precedence over the compact width breakpoint.
- Preserve existing non-TV behavior through defaulted opt-in APIs.
- No stream/provider credentials in logs, tests, screenshots or documentation.

## Task 1: Playback-independent browsing

**Files:** `flutter_app/lib/services/playlist_store.dart`, `flutter_app/test/playlist_store_tv_test.dart`.

**Interfaces:**

```dart
Future<void> selectPlaylist(int playlistId, {bool preservePlayback = false});
Future<void> selectGroup(String? group, {bool preservePlayback = false});
Future<List<EpgEntry>> loadChannelEpg(Channel channel);
```

- [x] Add store regression tests using a fixture ApiClient for channel/group data. Set `nowPlaying` and `epgEntries`, call selection with `preservePlayback: true`, and verify the actual store preserves both; the default clears them. Use controlled delayed API responses to verify older selections cannot overwrite a newer playlist/group.
- [x] Run `flutter test test/playlist_store_tv_test.dart` before implementation and capture expected failures.
- [x] Add opt-in preservation and guard async browse results against stale requests. Add a side-effect-free EPG lookup using the existing playlist-specific VU+/XMLTV helpers and caches; do not alter current playback metadata when browsing.
- [x] Run focused tests and analyzer for the amended file; self-review the diff and report limitations.

## Task 2: Remote list and TV home

**Files:** new `flutter_app/lib/screens/home/tv/tv_remote_list.dart`, `tv_home_view.dart`, `tv_programme_panel.dart`; tests `flutter_app/test/tv_remote_list_test.dart`, `tv_home_view_test.dart`; integration `flutter_app/lib/screens/home_screen.dart`.

**Interfaces:** Remote list consumes item identities, row builder, focused identity, item-focus and activation callbacks plus left/right/back callbacks. TV home consumes `PlaylistStore`, search/management/logout callbacks and exposes channel/group search-result navigation via a typed State key. Programme panel consumes the focused channel and the existing store and fullscreen request.

- [x] Write arrow/Back/OK tests against the remote list, including movement beyond the first lazy viewport, identity preservation after reorder and one activation per held press.
- [x] Implement explicit key handling with bounded indices, stable identity, scroll-to-offset and a high-contrast row. Holding OK uses the existing threshold and supports returning from an actions sheet.
- [x] Add a TV home with stable groups/channels/preview columns, main menu, playlist chooser and Favorites mode. Keep it mounted while management is shown so browsing memory and the player survive.
- [x] Integrate before the compact branch; route TV search selections into the new browser. Focused EPG loads have a debounce and stale-result guard. Show loading, empty and failure states without losing access to groups/menu.
- [x] Verify channel/group movement preserves the stream and Back restores the same row, including async list updates and search results.

## Task 3: Fullscreen handoff and final verification

**Files:** `flutter_app/lib/widgets/channel_player.dart`, relevant TV tests.

**Interfaces:** Add optional `fullscreenRequest` integer, `onFullscreenClosed` callback and preview focus option to ChannelPlayer. Existing callers retain defaults.

- [x] Add tests for TV selection taking precedence over compact widths and the one-OK fullscreen request/return contract.
- [x] Process new fullscreen requests after layout, including the first frame, without waiting for EPG. Completion restores the TV channel list focus. Exclude the preview from list traversal; Right from channels intentionally enters programme actions.
- [x] Make fullscreen Back dismiss visible interactive controls before leaving the route; root fullscreen focus starts with controls hidden for one-Back return. Keep seek and recording behavior otherwise intact.
- [x] Format touched files, run `flutter analyze`, the complete `flutter test` suite and `git diff --check`. Obtain independent review of integration and focus lifecycle. Address concrete findings and document physical-device validation still needed.

## Progress

- [x] Existing isolated worktree verified; base `1cf924f`.
- [x] Approved design and interfaces recorded.
- [x] Flutter SDK setup and baseline tests (previous configured SDK absent).
- [x] Tasks 1–3 implementation and review.

## Verification result — 2026-09-07

Used the project's pinned Flutter 3.41.7 / Dart 3.11.5. The previously configured
SDK path was absent, so a local SDK was installed under the ignored
`flutter_app/build/tooling/flutter` directory. The lockfile now uses the SDK's
compatible `meta` 1.17.0 and `test_api` 0.7.10; no runtime dependency was added.

From `flutter_app`, using that SDK:

```text
flutter test --no-pub
29 tests passed

flutter analyze --no-pub lib test
No issues found

dart format --output=none --set-exit-if-changed <10 changed Dart files>
0 files changed

git diff --check
exit 0
```

The complete suite includes 12 store regressions, 16 TV widget/fullscreen
regressions, and the existing auth-gate test. Fullscreen tests use a controlled
media engine fixture. Independent reviews covered the store, focus lifecycle,
fullscreen handoff and navigation; concrete findings were fixed and tested.

A separate render of the actual TV widgets at 960 × 540 logical pixels was
visually checked with sample channel and programme data. The capture is
`flutter_app/build/tv-home-960x540.png`. The scratch capture test and SDK stay in
ignored build output.

Physical Android TV playback, remote repeat feel, and display scaling remain
device validation items. See
`docs/superpowers/specs/2026-09-07-tv-remote-validation.md`. The changes remain
in the current worktree; no build was installed, merged or published.

## Integration verification

The user subsequently requested committing to the primary branch (named `main`
in this repository). Integration onto `ccd1f1c` preserves the newer channel-name
and Vu+ stream-resolution changes. The TV player now uses the same receiver URL
resolver. The combined full Flutter suite passes all 52 tests.
