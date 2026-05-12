import 'package:flutter/material.dart';

import '../../../config/device_utils.dart';
import '../../../models/models.dart';
import '../../../services/api_client.dart';
import '../../../services/playlist_store.dart';
import '../../../widgets/tv_focusable_tile.dart';
import '../home_types.dart';
import 'channel_action_sheet.dart';

class WatchPlaylistsPane extends StatefulWidget {
  final PlaylistStore store;
  final bool compact;
  final bool fullscreen;
  final WatchBrowseMode mode;
  final FocusNode? initialItemFocusNode;
  final Future<void> Function()? onPlaylistSelected;
  final Future<void> Function()? onGroupSelected;

  const WatchPlaylistsPane({
    super.key,
    required this.store,
    this.compact = false,
    this.fullscreen = false,
    this.mode = WatchBrowseMode.both,
    this.initialItemFocusNode,
    this.onPlaylistSelected,
    this.onGroupSelected,
  });

  @override
  State<WatchPlaylistsPane> createState() => _WatchPlaylistsPaneState();
}

class _WatchPlaylistsPaneState extends State<WatchPlaylistsPane> {
  final ScrollController _groupsScrollController = ScrollController();
  static const double _groupRowExtent = 56;
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

    // Simple scroll to position: just bring the item into view, let it land
    // at a natural position rather than forcing center alignment
    final targetOffset = targetIndex * _groupRowExtent;
    _groupsScrollController.animateTo(
      targetOffset.clamp(0, _groupsScrollController.position.maxScrollExtent),
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
    final isTv = isAndroidTv(context);

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
                  child: ListView.builder(
                    itemCount: playlists.length,
                    itemBuilder: (context, i) {
                      final p = playlists[i];
                      return _PlaylistTile(
                        playlist: p,
                        selected: p.id == store.selectedPlaylistId,
                        autofocus: isTv && i == 0,
                        focusNode: i == 0 ? widget.initialItemFocusNode : null,
                        onTap: () async {
                          await store.selectPlaylist(p.id);
                          await widget.onPlaylistSelected?.call();
                        },
                      );
                    },
                  ),
                )
              else
                SizedBox(
                  height: 220,
                  child: ListView.builder(
                    shrinkWrap: widget.compact,
                    itemCount: playlists.length,
                    itemBuilder: (context, i) {
                      final p = playlists[i];
                      return _PlaylistTile(
                        playlist: p,
                        selected: p.id == store.selectedPlaylistId,
                        autofocus: isTv && i == 0,
                        focusNode: i == 0 ? widget.initialItemFocusNode : null,
                        onTap: () async {
                          await store.selectPlaylist(p.id);
                          await widget.onPlaylistSelected?.call();
                        },
                      );
                    },
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
                          itemCount: groups.length + 1,
                          itemBuilder: (context, index) => _GroupTile(
                            index: index,
                            groups: groups,
                            store: store,
                            autofocus: isTv && index == 0,
                            focusNode: index == 0
                                ? widget.initialItemFocusNode
                                : null,
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
                          itemCount: groups.length + 1,
                          itemBuilder: (context, index) => _GroupTile(
                            index: index,
                            groups: groups,
                            store: store,
                            autofocus: isTv && index == 0,
                            focusNode: index == 0
                                ? widget.initialItemFocusNode
                                : null,
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
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback onTap;

  const _PlaylistTile({
    required this.playlist,
    required this.selected,
    required this.onTap,
    this.autofocus = false,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final isTv = isAndroidTv(context);
    final tile = ListTile(
      title: Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        playlist.type.toUpperCase(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      selected: selected,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      onTap: isTv ? null : onTap,
      dense: isTv,
    );

    if (!isTv) return tile;

    return TvFocusableTile(
      focusNode: focusNode,
      autofocus: autofocus,
      onTap: onTap,
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: tile,
    );
  }
}

class _GroupTile extends StatelessWidget {
  final int index;
  final List<Group> groups;
  final PlaylistStore store;
  final bool autofocus;
  final FocusNode? focusNode;
  final Future<void> Function()? onGroupSelected;

  const _GroupTile({
    required this.index,
    required this.groups,
    required this.store,
    required this.onGroupSelected,
    this.autofocus = false,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final isTv = isAndroidTv(context);

    if (index == 0) {
      final tile = ListTile(
        title: const Text('All channels'),
        selected: store.selectedGroup == null,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        onTap: isTv
            ? null
            : () async {
                await store.selectGroup(null);
                await onGroupSelected?.call();
              },
      );

      if (!isTv) return tile;

      return TvFocusableTile(
        focusNode: focusNode,
        autofocus: autofocus,
        onTap: () async {
          await store.selectGroup(null);
          await onGroupSelected?.call();
        },
        child: tile,
      );
    }

    final g = groups[index - 1];
    final isFavorite = store.isGroupFavorite(g.playlistId, g.name);
    Future<void> openGroup() async {
      await store.selectGroup(g.name);
      await onGroupSelected?.call();
    }

    final tile = ListTile(
      title: Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${g.channelCount}'),
          if (!isTv)
            IconButton(
              onPressed: () async {
                try {
                  await store.toggleFavoriteGroup(
                    g.copyWith(isFavorite: isFavorite),
                  );
                } on ApiException catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(e.message)));
                }
              },
              icon: Icon(
                isFavorite ? Icons.star : Icons.star_border,
                color: isFavorite ? Colors.amber : null,
              ),
            )
          else
            Icon(
              isFavorite ? Icons.star : Icons.star_border,
              color: isFavorite ? Colors.amber : null,
            ),
        ],
      ),
      selected: store.selectedGroup == g.name,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      onTap: isTv ? null : openGroup,
    );

    if (!isTv) return tile;

    return TvFocusableTile(
      focusNode: focusNode,
      autofocus: autofocus,
      onTap: openGroup,
      onLongPress: () => showGroupActionSheet(
        context,
        group: g,
        store: store,
        onOpen: openGroup,
      ),
      child: tile,
    );
  }
}
