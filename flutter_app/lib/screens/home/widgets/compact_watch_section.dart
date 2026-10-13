import 'package:flutter/material.dart';
import '../../../services/playlist_store.dart';
import 'browse_controls.dart';
import 'channels_pane.dart';
import 'player_pane.dart';

class CompactWatchSection extends StatelessWidget {
  static const int viewPlaylists = 0;
  static const int viewGroups = 0;
  static const int viewChannels = 0;
  static const int viewPlayer = 1;
  final PlaylistStore store;
  final GlobalKey? playerKey;
  final PageController controller;
  final int currentPage;
  final Future<void> Function(int page) onGoToPage;
  final ValueChanged<int> onPageChanged;
  final FocusNode? initialFocusNode;
  const CompactWatchSection({
    super.key,
    required this.store,
    this.playerKey,
    required this.controller,
    required this.currentPage,
    required this.onGoToPage,
    required this.onPageChanged,
    this.initialFocusNode,
  });
  @override
  Widget build(BuildContext context) {
    if (currentPage == viewPlayer) {
      return Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => onGoToPage(viewChannels),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Back to channels'),
            ),
          ),
          Expanded(
            child: PlayerPane(store: store, playerKey: playerKey),
          ),
        ],
      );
    }
    return Column(
      children: [
        Card(child: SourceSelector(store: store)),
        Card(child: GroupSelector(store: store)),
        const SizedBox(height: 4),
        Expanded(
          child: ChannelsPane(
            key: const PageStorageKey('watch-channels'),
            store: store,
            compact: true,
            fullscreen: true,
            initialChannelFocusNode: initialFocusNode,
            onChannelSelected: () => onGoToPage(viewPlayer),
          ),
        ),
      ],
    );
  }
}
