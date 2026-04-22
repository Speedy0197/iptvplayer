import 'package:flutter/material.dart';

import '../../../services/api_client.dart';
import '../../../services/playlist_store.dart';
import '../home_types.dart';
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

  @override
  Widget build(BuildContext context) {
    final compactFullscreen = compact && !withPlayer;

    String playlistNameFor(int playlistId) {
      for (final p in store.playlists) {
        if (p.id == playlistId) return p.name;
      }
      return 'Playlist $playlistId';
    }

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
                    return ListTile(
                      dense: true,
                      title: Text(
                        g.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${playlistNameFor(g.playlistId)} • ${g.channelCount} channels',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        onPressed: () async {
                          try {
                            await store.toggleFavoriteGroup(g);
                          } on ApiException catch (e) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(e.message)),
                            );
                          }
                        },
                        icon: const Icon(Icons.star, color: Colors.amber),
                      ),
                      onTap: () async {
                        await onGroupTap(g);
                      },
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
                    final selected = store.nowPlaying?.id == c.id;
                    return ListTile(
                      selected: selected,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      leading: ChannelLogoAvatar(logoUrl: c.logoUrl),
                      title: Text(
                        c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        c.groupName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
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
                      ),
                      onTap: () => onChannelTap(c),
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
                      return ListTile(
                        dense: true,
                        title: Text(
                          g.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${playlistNameFor(g.playlistId)} • ${g.channelCount} channels',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          onPressed: () async {
                            try {
                              await store.toggleFavoriteGroup(g);
                            } on ApiException catch (e) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(e.message)),
                              );
                            }
                          },
                          icon: const Icon(Icons.star, color: Colors.amber),
                        ),
                        onTap: () async {
                          await onGroupTap(g);
                        },
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
                      final selected = store.nowPlaying?.id == c.id;
                      return ListTile(
                        selected: selected,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        leading: ChannelLogoAvatar(logoUrl: c.logoUrl),
                        title: Text(
                          c.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          c.groupName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
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
                        ),
                        onTap: () => onChannelTap(c),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
