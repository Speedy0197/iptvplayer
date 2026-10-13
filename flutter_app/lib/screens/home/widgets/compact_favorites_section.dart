import 'package:flutter/material.dart';
import '../../../services/playlist_store.dart';
import '../home_types.dart';
import 'favorites_view.dart';
import 'player_pane.dart';

class CompactFavoritesSection extends StatelessWidget {
  final PlaylistStore store;
  final GlobalKey? playerKey;
  final PageController controller;
  final int currentPage;
  final GroupTapCallback onGroupTap;
  final ChannelTapCallback onChannelTap;
  final ValueChanged<int> onPageChanged;
  final Future<void> Function(int page) onGoToPage;
  final FocusNode? initialFocusNode;
  final VoidCallback? onBrowse;
  const CompactFavoritesSection({
    super.key,
    required this.store,
    this.playerKey,
    required this.controller,
    required this.currentPage,
    required this.onGroupTap,
    required this.onChannelTap,
    required this.onPageChanged,
    required this.onGoToPage,
    this.initialFocusNode,
    this.onBrowse,
  });
  @override
  Widget build(BuildContext context) {
    if (currentPage == 1) {
      return Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => onGoToPage(0),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Back to favorites'),
            ),
          ),
          Expanded(
            child: PlayerPane(store: store, playerKey: playerKey),
          ),
        ],
      );
    }
    return FavoritesView(
      key: const PageStorageKey('favorites'),
      store: store,
      onGroupTap: onGroupTap,
      onChannelTap: onChannelTap,
      compact: true,
      withPlayer: false,
      onBrowse: onBrowse,
    );
  }
}
