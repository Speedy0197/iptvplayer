import 'package:flutter/material.dart';

import '../../../config/ui_constants.dart';
import '../../../services/playlist_store.dart';
import 'channels_pane.dart';
import 'compact_tab_strip.dart';
import 'player_pane.dart';
import '../home_types.dart';
import 'watch_playlists_pane.dart';

class CompactWatchSection extends StatelessWidget {
  static const int viewPlaylists = 0;
  static const int viewGroups = 1;
  static const int viewChannels = 2;
  static const int viewPlayer = 3;

  final PlaylistStore store;
  final PageController controller;
  final int currentPage;
  final Future<void> Function(int page) onGoToPage;
  final ValueChanged<int> onPageChanged;

  const CompactWatchSection({
    super.key,
    required this.store,
    required this.controller,
    required this.currentPage,
    required this.onGoToPage,
    required this.onPageChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isSmallCompact = MediaQuery.sizeOf(context).width < kCompactBreakpoint;

    return Column(
      children: [
        SizedBox(
          width: isSmallCompact ? double.infinity : null,
          child: isSmallCompact
              ? CompactTabStrip(
                  selectedIndex: currentPage,
                  icons: const [
                    Icons.playlist_play,
                    Icons.folder_open,
                    Icons.tv,
                    Icons.smart_display,
                  ],
                  labels: const ['Playlists', 'Groups', 'Channels', 'Player'],
                  onSelected: (index) => onGoToPage(index),
                )
              : SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment<int>(
                      value: viewPlaylists,
                      icon: Icon(Icons.playlist_play),
                      label: Text('Playlists'),
                    ),
                    ButtonSegment<int>(
                      value: viewGroups,
                      icon: Icon(Icons.folder_open),
                      label: Text('Groups'),
                    ),
                    ButtonSegment<int>(
                      value: viewChannels,
                      icon: Icon(Icons.tv),
                      label: Text('Channels'),
                    ),
                    ButtonSegment<int>(
                      value: viewPlayer,
                      icon: Icon(Icons.smart_display),
                      label: Text('Player'),
                    ),
                  ],
                  selected: {currentPage},
                  onSelectionChanged: (next) => onGoToPage(next.first),
                ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: PageView(
            controller: controller,
            onPageChanged: onPageChanged,
            children: [
              WatchPlaylistsPane(
                store: store,
                compact: true,
                fullscreen: true,
                mode: WatchBrowseMode.playlistsOnly,
                onPlaylistSelected: () => onGoToPage(viewGroups),
              ),
              WatchPlaylistsPane(
                store: store,
                compact: true,
                fullscreen: true,
                mode: WatchBrowseMode.groupsOnly,
                onGroupSelected: () => onGoToPage(viewChannels),
              ),
              ChannelsPane(
                store: store,
                compact: true,
                fullscreen: true,
                onChannelSelected: () => onGoToPage(viewPlayer),
              ),
              PlayerPane(store: store),
            ],
          ),
        ),
      ],
    );
  }
}
