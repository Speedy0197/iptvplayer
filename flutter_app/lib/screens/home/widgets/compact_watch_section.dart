import 'package:flutter/material.dart';

import '../../../config/ui_constants.dart';
import '../../../services/playlist_store.dart';
import 'channels_pane.dart';
import 'compact_tab_strip.dart';
import 'player_pane.dart';
import '../home_types.dart';
import 'watch_playlists_pane.dart';

class CompactWatchSection extends StatefulWidget {
  static const int viewPlaylists = 0;
  static const int viewGroups = 1;
  static const int viewChannels = 2;
  static const int viewPlayer = 3;

  final PlaylistStore store;
  final PageController controller;
  final int currentPage;
  final Future<void> Function(int page) onGoToPage;
  final ValueChanged<int> onPageChanged;
  final FocusNode? initialFocusNode;

  const CompactWatchSection({
    super.key,
    required this.store,
    required this.controller,
    required this.currentPage,
    required this.onGoToPage,
    required this.onPageChanged,
    this.initialFocusNode,
  });

  @override
  State<CompactWatchSection> createState() => _CompactWatchSectionState();
}

class _CompactWatchSectionState extends State<CompactWatchSection> {
  late int _lastPage;
  late final FocusNode _firstGroupFocusNode;
  late final FocusNode _firstChannelFocusNode;

  @override
  void initState() {
    super.initState();
    _lastPage = widget.currentPage;
    _firstGroupFocusNode = FocusNode(debugLabel: 'compactFirstGroup');
    _firstChannelFocusNode = FocusNode(debugLabel: 'compactFirstChannel');
  }

  @override
  void dispose() {
    _firstGroupFocusNode.dispose();
    _firstChannelFocusNode.dispose();
    super.dispose();
  }

  FocusNode? _focusNodeForPage(int page) {
    switch (page) {
      case CompactWatchSection.viewGroups:
        return _firstGroupFocusNode;
      case CompactWatchSection.viewChannels:
        return _firstChannelFocusNode;
      default:
        return null;
    }
  }

  @override
  void didUpdateWidget(CompactWatchSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentPage != _lastPage) {
      _lastPage = widget.currentPage;
      final focusNode = _focusNodeForPage(widget.currentPage);
      if (focusNode == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Future<void>.delayed(kTabAnimation, () {
          if (!mounted) return;
          focusNode.requestFocus();
        });
      });
    }
    // When initialFocusNode changes (e.g., section switched), request focus on the correct page
    if (widget.initialFocusNode != oldWidget.initialFocusNode &&
        widget.initialFocusNode != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Give the widget tree time to build
        Future<void>.delayed(const Duration(milliseconds: 150), () {
          if (!mounted) return;
          final focusNode = _focusNodeForPage(widget.currentPage);
          if (focusNode != null && focusNode.canRequestFocus) {
            FocusScope.of(context).requestFocus(focusNode);
          }
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSmallCompact =
        MediaQuery.sizeOf(context).width < kCompactBreakpoint;

    return Column(
      children: [
        SizedBox(
          width: isSmallCompact ? double.infinity : null,
          child: isSmallCompact
              ? CompactTabStrip(
                  selectedIndex: widget.currentPage,
                  icons: const [
                    Icons.playlist_play,
                    Icons.folder_open,
                    Icons.tv,
                    Icons.smart_display,
                  ],
                  labels: const ['Playlists', 'Groups', 'Channels', 'Player'],
                  onSelected: (index) => widget.onGoToPage(index),
                )
              : SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment<int>(
                      value: CompactWatchSection.viewPlaylists,
                      icon: Icon(Icons.playlist_play),
                      label: Text('Playlists'),
                    ),
                    ButtonSegment<int>(
                      value: CompactWatchSection.viewGroups,
                      icon: Icon(Icons.folder_open),
                      label: Text('Groups'),
                    ),
                    ButtonSegment<int>(
                      value: CompactWatchSection.viewChannels,
                      icon: Icon(Icons.tv),
                      label: Text('Channels'),
                    ),
                    ButtonSegment<int>(
                      value: CompactWatchSection.viewPlayer,
                      icon: Icon(Icons.smart_display),
                      label: Text('Player'),
                    ),
                  ],
                  selected: {widget.currentPage},
                  onSelectionChanged: (next) => widget.onGoToPage(next.first),
                ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: PageView(
            controller: widget.controller,
            physics: const NeverScrollableScrollPhysics(),
            onPageChanged: widget.onPageChanged,
            children: [
              WatchPlaylistsPane(
                store: widget.store,
                compact: true,
                fullscreen: true,
                mode: WatchBrowseMode.playlistsOnly,
                onPlaylistSelected: () =>
                    widget.onGoToPage(CompactWatchSection.viewGroups),
              ),
              WatchPlaylistsPane(
                store: widget.store,
                compact: true,
                fullscreen: true,
                mode: WatchBrowseMode.groupsOnly,
                initialItemFocusNode: _firstGroupFocusNode,
                onGroupSelected: () =>
                    widget.onGoToPage(CompactWatchSection.viewChannels),
              ),
              ChannelsPane(
                store: widget.store,
                compact: true,
                fullscreen: true,
                initialChannelFocusNode: _firstChannelFocusNode,
                onChannelSelected: () =>
                    widget.onGoToPage(CompactWatchSection.viewPlayer),
              ),
              PlayerPane(store: widget.store),
            ],
          ),
        ),
      ],
    );
  }
}
