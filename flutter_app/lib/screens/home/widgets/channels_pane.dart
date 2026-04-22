import 'package:flutter/material.dart';

import '../../../models/models.dart';
import '../../../services/api_client.dart';
import '../../../services/playlist_store.dart';
import 'channel_logo_avatar.dart';

class ChannelsPane extends StatelessWidget {
  final PlaylistStore store;
  final bool compact;
  final bool fullscreen;
  final Future<void> Function()? onChannelSelected;

  const ChannelsPane({
    super.key,
    required this.store,
    this.compact = false,
    this.fullscreen = false,
    this.onChannelSelected,
  });

  @override
  Widget build(BuildContext context) {
    final channels = store.channels;

    return SizedBox(
      width: compact ? null : 360,
      child: Card(
        child: Column(
          mainAxisSize: compact && !fullscreen
              ? MainAxisSize.min
              : MainAxisSize.max,
          children: [
            ListTile(
              title: const Text('Channels'),
              dense: true,
              trailing: IconButton(
                icon: Icon(
                  store.channelSortOrder == ChannelSortOrder.byName
                      ? Icons.sort_by_alpha
                      : Icons.sort,
                ),
                tooltip: store.channelSortOrder == ChannelSortOrder.byName
                    ? 'Sort by name (tap to sort by index)'
                    : 'Sort by index (tap to sort by name)',
                onPressed: () => store.toggleChannelSortOrder(),
              ),
            ),
            if (!compact || fullscreen)
              Expanded(
                child: store.loadingChannels
                    ? const Center(child: CircularProgressIndicator())
                    : channels.isEmpty
                    ? const Center(child: Text('No channels found'))
                    : ListView.builder(
                        itemCount: channels.length,
                        itemBuilder: (context, i) =>
                            _ChannelTile(
                              channel: channels[i],
                              store: store,
                              onChannelSelected: onChannelSelected,
                            ),
                      ),
              )
            else
              SizedBox(
                height: 360,
                child: store.loadingChannels
                    ? const Center(child: CircularProgressIndicator())
                    : channels.isEmpty
                    ? const Center(child: Text('No channels found'))
                    : ListView.builder(
                        shrinkWrap: compact,
                        itemCount: channels.length,
                        itemBuilder: (context, i) =>
                            _ChannelTile(
                              channel: channels[i],
                              store: store,
                              onChannelSelected: onChannelSelected,
                            ),
                      ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  final Channel channel;
  final PlaylistStore store;
  final Future<void> Function()? onChannelSelected;

  const _ChannelTile({
    required this.channel,
    required this.store,
    required this.onChannelSelected,
  });

  @override
  Widget build(BuildContext context) {
    final c = channel;
    final selected = store.nowPlaying?.id == c.id;
    return ListTile(
      selected: selected,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      leading: ChannelLogoAvatar(logoUrl: c.logoUrl),
      title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(c.groupName, maxLines: 1, overflow: TextOverflow.ellipsis),
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
        icon: Icon(
          c.isFavorite ? Icons.star : Icons.star_border,
          color: c.isFavorite ? Colors.amber : null,
        ),
      ),
      onTap: () async {
        await store.play(c);
        await onChannelSelected?.call();
      },
    );
  }
}
