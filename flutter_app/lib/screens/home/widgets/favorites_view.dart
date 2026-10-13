import 'package:flutter/material.dart';

import '../../../config/device_utils.dart';
import '../../../models/models.dart';
import '../../../services/api_client.dart';
import '../../../services/playlist_store.dart';
import '../../../widgets/tv_focusable_tile.dart';
import '../home_types.dart';
import 'channel_action_sheet.dart';
import 'channel_logo_avatar.dart';
import 'player_pane.dart';

class FavoritesView extends StatelessWidget {
  final PlaylistStore store;
  final GlobalKey? playerKey;
  final GroupTapCallback onGroupTap;
  final ChannelTapCallback onChannelTap;
  final bool compact;
  final bool withPlayer;
  final FocusNode? initialFocusNode;
  final VoidCallback? onBrowse;

  const FavoritesView({
    super.key,
    required this.store,
    this.playerKey,
    required this.onGroupTap,
    required this.onChannelTap,
    this.compact = false,
    this.withPlayer = true,
    this.initialFocusNode,
    this.onBrowse,
  });

  String _playlistNameFor(int playlistId) {
    for (final p in store.playlists) {
      if (p.id == playlistId) return p.name;
    }
    return 'Source $playlistId';
  }

  @override
  Widget build(BuildContext context) {
    final isTv = isAndroidTv(context);
    final card = Card(
      child: CustomScrollView(
        key: const PageStorageKey('favorite-list'),
        slivers: [
          SliverToBoxAdapter(
            child: ListTile(
              title: const Text('Favorites'),
              subtitle: const Text('Your channels and groups, across sources'),
              trailing: IconButton(
                tooltip: 'Refresh favorites',
                onPressed: () {
                  store.fetchFavoriteGroups();
                  store.fetchFavoriteChannels();
                },
                icon: const Icon(Icons.refresh),
              ),
            ),
          ),
          if (store.loadingFavoriteGroups)
            const SliverToBoxAdapter(child: LinearProgressIndicator()),
          if (store.favoriteGroups.isNotEmpty) ...[
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('Saved groups'),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: store.favoriteGroups
                      .map(
                        (g) => InputChip(
                          avatar: const Icon(Icons.folder_outlined, size: 18),
                          label: Text('${g.name} · ${g.channelCount}'),
                          tooltip: _playlistNameFor(g.playlistId),
                          onPressed: () => onGroupTap(g),
                          onDeleted: () => store.toggleFavoriteGroup(g),
                          deleteIcon: const Icon(
                            Icons.star,
                            color: Colors.amber,
                            size: 18,
                          ),
                          deleteButtonTooltipMessage: 'Remove saved group',
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
          ],
          const SliverToBoxAdapter(
            child: ListTile(
              leading: Icon(Icons.tv),
              title: Text('Saved channels'),
            ),
          ),
          if (store.loadingFavoriteChannels)
            const SliverToBoxAdapter(child: LinearProgressIndicator()),
          SliverList.builder(
            itemCount: store.favoriteChannels.length,
            itemBuilder: (context, i) => _FavoriteChannelTile(
              channel: store.favoriteChannels[i],
              store: store,
              onTap: onChannelTap,
              isTv: isTv,
              autofocus: i == 0 && initialFocusNode == null,
              focusNode: i == 0 ? initialFocusNode : null,
            ),
          ),
          if (store.favoriteChannels.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const Icon(Icons.star_outline, size: 36),
                    const SizedBox(height: 12),
                    const Text('Keep your favorites close'),
                    const SizedBox(height: 8),
                    const Text(
                      'Use the star beside a channel to save it here.',
                      textAlign: TextAlign.center,
                    ),
                    if (onBrowse != null)
                      TextButton.icon(
                        onPressed: onBrowse,
                        icon: const Icon(Icons.tv),
                        label: const Text('Browse channels'),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (compact || !withPlayer) return card;
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          SizedBox(
            width: (constraints.maxWidth * .42).clamp(300.0, 440.0),
            child: card,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: PlayerPane(store: store, playerKey: playerKey),
          ),
        ],
      ),
    );
  }
}

class _FavoriteGroupTile extends StatelessWidget {
  final Group group;
  final PlaylistStore store;
  final String playlistName;
  final GroupTapCallback onTap;
  final bool isTv;
  final bool autofocus;
  final FocusNode? focusNode;

  const _FavoriteGroupTile({
    required this.group,
    required this.store,
    required this.playlistName,
    required this.onTap,
    required this.isTv,
    required this.autofocus,
    this.focusNode,
  });

  Future<void> _open() => onTap(group);

  @override
  Widget build(BuildContext context) {
    final showDesktopTooltips = isMacOrWindowsDesktop();

    Widget trailing = IconButton(
      tooltip: 'Remove favorite',
      onPressed: () async {
        try {
          await store.toggleFavoriteGroup(group);
        } on ApiException catch (e) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(e.message)));
        }
      },
      icon: const Icon(Icons.star, color: Colors.amber),
    );

    if (isTv) {
      trailing = const ExcludeFocus(
        child: Icon(Icons.star, color: Colors.amber),
      );
    }

    final tile = ListTile(
      dense: true,
      visualDensity: isTv ? VisualDensity.compact : VisualDensity.standard,
      minVerticalPadding: isTv ? 0 : null,
      title: showDesktopTooltips
          ? Tooltip(
              message: group.name,
              child: Text(
                group.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            )
          : Text(group.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: isTv
          ? null
          : Text(
              '$playlistName • ${group.channelCount} channels',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: trailing,
      onTap: isTv ? null : _open,
    );

    if (!isTv) return tile;

    return TvFocusableTile(
      autofocus: autofocus && focusNode == null,
      focusNode: focusNode,
      onTap: _open,
      onLongPress: () => showGroupActionSheet(
        context,
        group: group,
        store: store,
        onOpen: _open,
      ),
      child: tile,
    );
  }
}

class _FavoriteChannelTile extends StatelessWidget {
  final Channel channel;
  final PlaylistStore store;
  final ChannelTapCallback onTap;
  final bool isTv;
  final bool autofocus;
  final FocusNode? focusNode;

  const _FavoriteChannelTile({
    required this.channel,
    required this.store,
    required this.onTap,
    required this.isTv,
    this.autofocus = false,
    this.focusNode,
  });

  Future<void> _play() => onTap(channel);

  @override
  Widget build(BuildContext context) {
    final c = channel;
    final selected = store.nowPlaying?.id == c.id;
    final sourceName =
        store.playlists.where((p) => p.id == c.playlistId).firstOrNull?.name ??
        'Source ${c.playlistId}';
    final subtitle = [
      sourceName,
      if (c.groupName.trim().isNotEmpty) c.groupName,
    ].join(' · ');
    final showDesktopTooltips = isMacOrWindowsDesktop();

    Widget trailing = IconButton(
      tooltip: 'Remove favorite',
      onPressed: () async {
        try {
          await store.toggleFavorite(c);
        } on ApiException catch (e) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(e.message)));
        }
      },
      icon: const Icon(Icons.star, color: Colors.amber),
    );

    if (isTv) {
      trailing = const ExcludeFocus(
        child: Icon(Icons.star, color: Colors.amber),
      );
    }

    final tile = ListTile(
      selected: selected,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      leading: ChannelLogoAvatar(logoUrl: c.logoUrl),
      dense: true,
      visualDensity: isTv ? VisualDensity.compact : VisualDensity.standard,
      minVerticalPadding: isTv ? 0 : null,
      title: showDesktopTooltips
          ? Tooltip(
              message: c.name,
              child: Text(c.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            )
          : Text(c.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: isTv
          ? null
          : (showDesktopTooltips
                ? Tooltip(
                    message: subtitle,
                    child: Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  )
                : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis)),
      trailing: trailing,
      onTap: isTv ? null : _play,
    );

    if (!isTv) return tile;

    return TvFocusableTile(
      autofocus: autofocus && focusNode == null,
      focusNode: focusNode,
      onTap: _play,
      onLongPress: () => showChannelActionSheet(
        context,
        channel: c,
        store: store,
        onPlay: _play,
      ),
      child: tile,
    );
  }
}

class FavoriteGroupsList extends StatelessWidget {
  final PlaylistStore store;
  final GroupTapCallback onGroupTap;
  final FocusNode? initialFocusNode;

  const FavoriteGroupsList({
    super.key,
    required this.store,
    required this.onGroupTap,
    this.initialFocusNode,
  });

  @override
  Widget build(BuildContext context) {
    String playlistNameFor(int playlistId) {
      for (final p in store.playlists) {
        if (p.id == playlistId) return p.name;
      }
      return 'Source $playlistId';
    }

    final isTv = isAndroidTv(context);

    return Card(
      child: Column(
        children: [
          if (!isTv) ...[
            ListTile(
              dense: true,
              leading: const Icon(Icons.folder_open),
              title: const Text('Favorite Groups'),
              trailing: IconButton(
                onPressed: store.fetchFavoriteGroups,
                icon: const Icon(Icons.refresh),
              ),
            ),
            const Divider(height: 1),
          ],
          Expanded(
            child: store.loadingFavoriteGroups
                ? const Center(child: CircularProgressIndicator())
                : store.favoriteGroups.isEmpty
                ? const Center(child: Text('No favorite groups yet'))
                : ListView.builder(
                    itemCount: store.favoriteGroups.length,
                    itemBuilder: (context, i) {
                      final g = store.favoriteGroups[i];
                      return _FavoriteGroupTile(
                        group: g,
                        store: store,
                        playlistName: playlistNameFor(g.playlistId),
                        onTap: onGroupTap,
                        isTv: isTv,
                        autofocus: isTv && i == 0 && initialFocusNode == null,
                        focusNode: i == 0 ? initialFocusNode : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class FavoriteChannelsList extends StatelessWidget {
  final PlaylistStore store;
  final ChannelTapCallback onChannelTap;
  final FocusNode? initialFocusNode;

  const FavoriteChannelsList({
    super.key,
    required this.store,
    required this.onChannelTap,
    this.initialFocusNode,
  });

  @override
  Widget build(BuildContext context) {
    final isTv = isAndroidTv(context);

    return Card(
      child: Column(
        children: [
          if (!isTv) ...[
            ListTile(
              dense: true,
              leading: const Icon(Icons.tv),
              title: const Text('Favorite Channels'),
              trailing: IconButton(
                onPressed: store.fetchFavoriteChannels,
                icon: const Icon(Icons.refresh),
              ),
            ),
            const Divider(height: 1),
          ],
          Expanded(
            child: store.loadingFavoriteChannels
                ? const Center(child: CircularProgressIndicator())
                : store.favoriteChannels.isEmpty
                ? const Center(child: Text('No favorite channels yet'))
                : ListView.builder(
                    itemCount: store.favoriteChannels.length,
                    itemBuilder: (context, i) {
                      final c = store.favoriteChannels[i];
                      return _FavoriteChannelTile(
                        channel: c,
                        store: store,
                        onTap: onChannelTap,
                        isTv: isTv,
                        autofocus: isTv && i == 0 && initialFocusNode == null,
                        focusNode: i == 0 ? initialFocusNode : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
