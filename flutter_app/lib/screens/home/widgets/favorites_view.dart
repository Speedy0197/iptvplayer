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
  final GroupTapCallback onGroupTap;
  final ChannelTapCallback onChannelTap;
  final bool compact;
  final bool withPlayer;

  const FavoritesView({
    super.key,
    required this.store,
    required this.onGroupTap,
    required this.onChannelTap,
    this.compact = false,
    this.withPlayer = true,
  });

  String _playlistNameFor(int playlistId) {
    for (final p in store.playlists) {
      if (p.id == playlistId) return p.name;
    }
    return 'Playlist $playlistId';
  }

  @override
  Widget build(BuildContext context) {
    final compactFullscreen = compact && !withPlayer;
    final isTv = isAndroidTv(context);

    final favoriteLists = Column(
      children: [
        const ListTile(
          dense: true,
          leading: Icon(Icons.folder_open),
          title: Text('Favorite Groups'),
        ),
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
                      playlistName: _playlistNameFor(g.playlistId),
                      onTap: onGroupTap,
                      isTv: isTv,
                      autofocus: isTv && i == 0,
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        const ListTile(
          dense: true,
          leading: Icon(Icons.tv),
          title: Text('Favorite Channels'),
        ),
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
                    );
                  },
                ),
        ),
      ],
    );

    final favoritesCard = Card(
      child: Column(
        mainAxisSize: compactFullscreen
            ? MainAxisSize.max
            : (compact ? MainAxisSize.min : MainAxisSize.max),
        children: [
          ListTile(
            title: const Text('Favorites'),
            subtitle: const Text('Channels and groups'),
            trailing: IconButton(
              onPressed: () {
                store.fetchFavoriteGroups();
                store.fetchFavoriteChannels();
              },
              icon: const Icon(Icons.refresh),
            ),
          ),
          if (!compact || compactFullscreen)
            Expanded(child: favoriteLists)
          else
            SizedBox(height: 520, child: favoriteLists),
        ],
      ),
    );

    if (compact) {
      if (!withPlayer) {
        return favoritesCard;
      }
      return ListView(
        padding: EdgeInsets.zero,
        children: [
          favoritesCard,
          const SizedBox(height: 10),
          SizedBox(height: 420, child: PlayerPane(store: store)),
        ],
      );
    }

    return Row(
      children: [
        SizedBox(width: 480, child: favoritesCard),
        const SizedBox(width: 10),
        Expanded(child: PlayerPane(store: store)),
      ],
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

  const _FavoriteGroupTile({
    required this.group,
    required this.store,
    required this.playlistName,
    required this.onTap,
    required this.isTv,
    required this.autofocus,
  });

  Future<void> _open() => onTap(group);

  @override
  Widget build(BuildContext context) {
    Widget trailing = IconButton(
      onPressed: () async {
        try {
          await store.toggleFavoriteGroup(group);
        } on ApiException catch (e) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.message)),
          );
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
      dense: !isTv,
      title: Text(group.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '$playlistName • ${group.channelCount} channels',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: trailing,
      onTap: isTv ? null : _open,
    );

    if (!isTv) return tile;

    return TvFocusableTile(
      autofocus: autofocus,
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

  const _FavoriteChannelTile({
    required this.channel,
    required this.store,
    required this.onTap,
    required this.isTv,
  });

  Future<void> _play() => onTap(channel);

  @override
  Widget build(BuildContext context) {
    final c = channel;
    final selected = store.nowPlaying?.id == c.id;

    Widget trailing = IconButton(
      onPressed: () async {
        try {
          await store.toggleFavorite(c);
        } on ApiException catch (e) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.message)),
          );
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
      title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(c.groupName, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailing,
      onTap: isTv ? null : _play,
    );

    if (!isTv) return tile;

    return TvFocusableTile(
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

  const FavoriteGroupsList({
    super.key,
    required this.store,
    required this.onGroupTap,
  });

  @override
  Widget build(BuildContext context) {
    String playlistNameFor(int playlistId) {
      for (final p in store.playlists) {
        if (p.id == playlistId) return p.name;
      }
      return 'Playlist $playlistId';
    }

    final isTv = isAndroidTv(context);

    return Card(
      child: Column(
        children: [
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
                        autofocus: isTv && i == 0,
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

  const FavoriteChannelsList({
    super.key,
    required this.store,
    required this.onChannelTap,
  });

  @override
  Widget build(BuildContext context) {
    final isTv = isAndroidTv(context);

    return Card(
      child: Column(
        children: [
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
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
