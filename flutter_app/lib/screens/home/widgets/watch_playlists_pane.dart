import 'package:flutter/material.dart';

import '../../../models/models.dart';
import '../../../services/api_client.dart';
import '../../../services/playlist_store.dart';
import '../home_types.dart';

class WatchPlaylistsPane extends StatefulWidget {
  final PlaylistStore store;
  final bool compact;
  final bool fullscreen;
  final WatchBrowseMode mode;
  final Future<void> Function()? onPlaylistSelected;
  final Future<void> Function()? onGroupSelected;

  const WatchPlaylistsPane({
    super.key,
    required this.store,
    this.compact = false,
    this.fullscreen = false,
    this.mode = WatchBrowseMode.both,
    this.onPlaylistSelected,
    this.onGroupSelected,
  });

  @override
  State<WatchPlaylistsPane> createState() => _WatchPlaylistsPaneState();
}

class _WatchPlaylistsPaneState extends State<WatchPlaylistsPane> {
  final ScrollController _groupsScrollController = ScrollController();
  static const double _groupRowExtent = 56;
  static const double _groupTopInset = 10;
  String? _lastSelectedGroup;
  int _lastGroupCount = -1;
  String _lastSearchQuery = '';

  @override
  void dispose() {
    _groupsScrollController.dispose();
    super.dispose();
  }

  void _scrollToSelectedGroup(
    String? selectedGroup,
    List<Group> visibleGroups,
  ) {
    if (!mounted || !_groupsScrollController.hasClients) return;

    int targetIndex = 0;
    if (selectedGroup != null) {
      final groupIndex = visibleGroups.indexWhere(
        (g) => g.name == selectedGroup,
      );
      if (groupIndex < 0) return;
      targetIndex = groupIndex + 1;
    }

    final targetOffset = ((targetIndex * _groupRowExtent) - _groupTopInset)
        .clamp(0, _groupsScrollController.position.maxScrollExtent)
        .toDouble();

    _groupsScrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final playlists = store.playlists;
    final groups = store.filteredGroups;
    final showPlaylists = widget.mode != WatchBrowseMode.groupsOnly;
    final showGroups = widget.mode != WatchBrowseMode.playlistsOnly;

    final shouldRefocus =
        _lastSelectedGroup != store.selectedGroup ||
        _lastGroupCount != groups.length ||
        _lastSearchQuery != store.searchQuery;

    if (shouldRefocus) {
      _lastSelectedGroup = store.selectedGroup;
      _lastGroupCount = groups.length;
      _lastSearchQuery = store.searchQuery;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToSelectedGroup(store.selectedGroup, groups);
        Future<void>.delayed(const Duration(milliseconds: 80), () {
          if (!mounted) return;
          _scrollToSelectedGroup(store.selectedGroup, groups);
        });
      });
    }

    return SizedBox(
      width: widget.compact ? null : 280,
      child: Card(
        child: Column(
          mainAxisSize: widget.compact && !widget.fullscreen
              ? MainAxisSize.min
              : MainAxisSize.max,
          children: [
            if (showPlaylists) ...[
              const ListTile(title: Text('Playlists'), dense: true),
              if (!widget.compact || widget.fullscreen)
                Expanded(
                  flex: showGroups ? 2 : 1,
                  child: ListView(
                    children: [
                      for (final p in playlists)
                        _PlaylistTile(
                          playlist: p,
                          selected: p.id == store.selectedPlaylistId,
                          onTap: () async {
                            await store.selectPlaylist(p.id);
                            await widget.onPlaylistSelected?.call();
                          },
                        ),
                    ],
                  ),
                )
              else
                SizedBox(
                  height: 220,
                  child: ListView(
                    shrinkWrap: widget.compact,
                    children: [
                      for (final p in playlists)
                        _PlaylistTile(
                          playlist: p,
                          selected: p.id == store.selectedPlaylistId,
                          onTap: () async {
                            await store.selectPlaylist(p.id);
                            await widget.onPlaylistSelected?.call();
                          },
                        ),
                    ],
                  ),
                ),
            ],
            if (showPlaylists && showGroups) const Divider(height: 1),
            if (showGroups) ...[
              const ListTile(title: Text('Groups'), dense: true),
              if (!widget.compact || widget.fullscreen)
                Expanded(
                  flex: showPlaylists ? 3 : 1,
                  child: store.loadingGroups
                      ? const Center(child: CircularProgressIndicator())
                      : ListView.builder(
                          controller: _groupsScrollController,
                          itemExtent: _groupRowExtent,
                          itemCount: groups.length + 1,
                          itemBuilder: (context, index) => _GroupTile(
                            index: index,
                            groups: groups,
                            store: store,
                            onGroupSelected: widget.onGroupSelected,
                          ),
                        ),
                )
              else
                SizedBox(
                  height: 320,
                  child: store.loadingGroups
                      ? const Center(child: CircularProgressIndicator())
                      : ListView.builder(
                          shrinkWrap: widget.compact,
                          controller: _groupsScrollController,
                          itemExtent: _groupRowExtent,
                          itemCount: groups.length + 1,
                          itemBuilder: (context, index) => _GroupTile(
                            index: index,
                            groups: groups,
                            store: store,
                            onGroupSelected: widget.onGroupSelected,
                          ),
                        ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlaylistTile extends StatelessWidget {
  final Playlist playlist;
  final bool selected;
  final VoidCallback onTap;

  const _PlaylistTile({
    required this.playlist,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(
        playlist.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(playlist.type.toUpperCase()),
      selected: selected,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      onTap: onTap,
    );
  }
}

class _GroupTile extends StatelessWidget {
  final int index;
  final List<Group> groups;
  final PlaylistStore store;
  final Future<void> Function()? onGroupSelected;

  const _GroupTile({
    required this.index,
    required this.groups,
    required this.store,
    required this.onGroupSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (index == 0) {
      return ListTile(
        title: const Text('All channels'),
        selected: store.selectedGroup == null,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        onTap: () async {
          await store.selectGroup(null);
          await onGroupSelected?.call();
        },
      );
    }

    final g = groups[index - 1];
    final isFavorite = store.isGroupFavorite(g.playlistId, g.name);
    return ListTile(
      title: Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${g.channelCount}'),
          IconButton(
            onPressed: () async {
              try {
                await store.toggleFavoriteGroup(
                  g.copyWith(isFavorite: isFavorite),
                );
              } on ApiException catch (e) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(e.message)),
                );
              }
            },
            icon: Icon(
              isFavorite ? Icons.star : Icons.star_border,
              color: isFavorite ? Colors.amber : null,
            ),
          ),
        ],
      ),
      selected: store.selectedGroup == g.name,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      onTap: () async {
        await store.selectGroup(g.name);
        await onGroupSelected?.call();
      },
    );
  }
}
