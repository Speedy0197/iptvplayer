import 'package:flutter/material.dart';

import '../../../config/ui_constants.dart';
import '../../../services/playlist_store.dart';
import '../home_types.dart';
import 'compact_tab_strip.dart';
import 'favorites_view.dart';
import 'player_pane.dart';

class CompactFavoritesSection extends StatefulWidget {
  final PlaylistStore store;
  final PageController controller;
  final int currentPage;
  final GroupTapCallback onGroupTap;
  final ChannelTapCallback onChannelTap;
  final ValueChanged<int> onPageChanged;
  final Future<void> Function(int page) onGoToPage;
  final FocusNode? initialFocusNode;

  const CompactFavoritesSection({
    super.key,
    required this.store,
    required this.controller,
    required this.currentPage,
    required this.onGroupTap,
    required this.onChannelTap,
    required this.onPageChanged,
    required this.onGoToPage,
    this.initialFocusNode,
  });

  @override
  State<CompactFavoritesSection> createState() =>
      _CompactFavoritesSectionState();
}

class _CompactFavoritesSectionState extends State<CompactFavoritesSection> {
  late int _lastPage;
  late final FocusNode _firstGroupFocusNode;
  late final FocusNode _firstChannelFocusNode;

  @override
  void initState() {
    super.initState();
    _lastPage = widget.currentPage;
    _firstGroupFocusNode = FocusNode(debugLabel: 'compactFirstFavoriteGroup');
    _firstChannelFocusNode = FocusNode(
      debugLabel: 'compactFirstFavoriteChannel',
    );
  }

  @override
  void dispose() {
    _firstGroupFocusNode.dispose();
    _firstChannelFocusNode.dispose();
    super.dispose();
  }

  FocusNode? _focusNodeForPage(int page) {
    switch (page) {
      case 0:
        return _firstGroupFocusNode;
      case 1:
        return _firstChannelFocusNode;
      default:
        return null;
    }
  }

  @override
  void didUpdateWidget(CompactFavoritesSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When the page changes, restore focus to the page content
    if (widget.currentPage != _lastPage) {
      _lastPage = widget.currentPage;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        FocusScope.of(context).unfocus();
        Future<void>.delayed(const Duration(milliseconds: 50), () {
          if (!mounted) return;
          final focusNode = _focusNodeForPage(widget.currentPage);
          if (focusNode != null) {
            focusNode.requestFocus();
          } else {
            FocusScope.of(context).requestFocus();
          }
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
                    Icons.folder_open,
                    Icons.tv,
                    Icons.smart_display,
                  ],
                  labels: const ['Groups', 'Channels', 'Player'],
                  onSelected: (index) => widget.onGoToPage(index),
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
              if (isSmallCompact) ...[
                FavoriteGroupsList(
                  store: widget.store,
                  onGroupTap: widget.onGroupTap,
                  initialFocusNode: _firstGroupFocusNode,
                ),
                FavoriteChannelsList(
                  store: widget.store,
                  onChannelTap: widget.onChannelTap,
                  initialFocusNode: _firstChannelFocusNode,
                ),
                PlayerPane(store: widget.store),
              ] else ...[
                FavoritesView(
                  store: widget.store,
                  onGroupTap: widget.onGroupTap,
                  onChannelTap: widget.onChannelTap,
                  compact: true,
                  withPlayer: false,
                ),
                PlayerPane(store: widget.store),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
