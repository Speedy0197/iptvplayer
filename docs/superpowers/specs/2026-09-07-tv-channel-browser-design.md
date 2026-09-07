# TV channel browser

Approved direction: option A in the visual companion, accepted by the user on 2026-09-07.

## Experience

Android TV opens a dedicated landscape browser with groups on the left, channels in the centre and the playing video plus programme information on the right. It replaces the mobile Playlists / Groups / Channels / Player pages on TV. Existing mobile and desktop flows remain supported.

Up/Down moves within the active list, Left/Right changes columns. Opening a group keeps playback running. Each playlist/group remembers its last focused channel and scroll position for the lifetime of the home screen. A high-contrast focused row and a separate playing indicator distinguish browsing from playback. OK on a channel starts playback and enters fullscreen immediately. Back closes the nearest layer, restores the channel row after fullscreen, then moves to groups, then the main menu, then permits exiting. Holding OK opens the existing channel actions and restores focus on dismissal.

The main menu exposes Live TV, Favorites, Search, Playlists and Logout with readable labels. Playlist switching is available without re-entering a four-page flow. Existing playlist management, search and recording/EPG actions remain reachable. The current playlist is selected on launch using the existing store bootstrap. Favorites use the same browser interaction rather than a separate compact pager.

## Architecture

Add a TV home widget selected before width-based mobile branches in HomeScreen. Use a reusable remote list with one logical focus node per list, explicit key handling and fixed row extents so long lists can move to unbuilt items and restore their position. Store logical focus by stable channel identity, not index alone. Channel focus only changes metadata; it never tunes the stream. The store gains opt-in preservation for playlist/group selection and a read-only EPG lookup for the focused channel. Async browse/EPG completions must not replace newer selections.

Retain the existing ChannelPlayer and its store-owned media engine. Add an explicit fullscreen request interface with completion notification, and suppress preview autofocus within the TV browser. Fullscreen keeps its existing player controls and recording support, with Back dismissing active controls before leaving playback.

## Constraints and verification

- Flutter 3.41.7 / Dart 3.11.5, as pinned by the project; no new runtime dependencies.
- Android TV selection takes precedence over the compact width breakpoint.
- Preserve existing non-TV behavior through defaulted opt-in APIs.
- No stream/provider credentials in logs, tests, screenshots or documentation.
- Widget tests cover arrows, held OK, focus restoration, offscreen items, empty/loading lists and Back layers. Store tests cover playback preservation and stale responses. Run analyzer and the existing suite; test physical remote repeat/scroll performance separately when hardware is available.
