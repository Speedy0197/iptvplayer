import 'package:flutter/material.dart';

import '../../../config/ui_constants.dart';
import '../../../services/playlist_store.dart';
import '../home_types.dart';
import 'compact_tab_strip.dart';
import 'favorites_view.dart';
import 'player_pane.dart';

class CompactFavoritesSection extends StatelessWidget {
  final PlaylistStore store;
  final PageController controller;
  final int currentPage;
  final GroupTapCallback onGroupTap;
  final ChannelTapCallback onChannelTap;
  final ValueChanged<int> onPageChanged;
  final Future<void> Function(int page) onGoToPage;

  const CompactFavoritesSection({
    super.key,
    required this.store,
    required this.controller,
    required this.currentPage,
    required this.onGroupTap,
    required this.onChannelTap,
    required this.onPageChanged,
    required this.onGoToPage,
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
                    Icons.folder_open,
                    Icons.tv,
                    Icons.smart_display,
                  ],
                  labels: const ['Groups', 'Channels', 'Player'],
                  onSelected: (index) => onGoToPage(index),
                )
              : SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment<int>(
                      value: 0,
                      icon: Icon(Icons.star),
                      label: Text('Favorites'),
                    ),
                    ButtonSegment<int>(
                      value: 1,
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
              if (isSmallCompact) ...[
                FavoriteGroupsList(store: store, onGroupTap: onGroupTap),
                FavoriteChannelsList(store: store, onChannelTap: onChannelTap),
                PlayerPane(store: store),
              ] else ...[
                FavoritesView(
                  store: store,
                  onGroupTap: onGroupTap,
                  onChannelTap: onChannelTap,
                  compact: true,
                  withPlayer: false,
                ),
                PlayerPane(store: store),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
