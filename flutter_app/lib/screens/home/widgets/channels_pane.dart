import 'package:flutter/material.dart';

import '../../../config/device_utils.dart';
import '../../../models/models.dart';
import '../../../services/api_client.dart';
import '../../../services/playlist_store.dart';
import '../../../widgets/tv_focusable_tile.dart';
import 'channel_action_sheet.dart';
import 'channel_logo_avatar.dart';

class ChannelsPane extends StatelessWidget {
  final PlaylistStore store;
  final bool compact;
  final bool fullscreen;
  final FocusNode? initialChannelFocusNode;
  final Future<void> Function()? onChannelSelected;

  const ChannelsPane({
    super.key,
    required this.store,
    this.compact = false,
    this.fullscreen = false,
    this.initialChannelFocusNode,
    this.onChannelSelected,
  });

  @override
  Widget build(BuildContext context) {
    final channels = store.channels;
    final isTv = isAndroidTv(context);

    Widget buildList({required bool shrinkWrap}) {
      if (store.loadingChannels) {
        return const Center(child: CircularProgressIndicator());
      }
      if (channels.isEmpty) {
        return const Center(child: Text('No channels found'));
      }
      return ListView.builder(
        shrinkWrap: shrinkWrap,
        itemCount: channels.length,
        itemBuilder: (context, i) => _ChannelTile(
          channel: channels[i],
          store: store,
          onChannelSelected: onChannelSelected,
          isTv: isTv,
          autofocus: isTv && i == 0,
          focusNode: i == 0 ? initialChannelFocusNode : null,
        ),
      );
    }

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
              Expanded(child: buildList(shrinkWrap: false))
            else
              SizedBox(height: 360, child: buildList(shrinkWrap: compact)),
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
  final bool isTv;
  final bool autofocus;
  final FocusNode? focusNode;

  const _ChannelTile({
    required this.channel,
    required this.store,
    required this.onChannelSelected,
    required this.isTv,
    required this.autofocus,
    required this.focusNode,
  });

  Future<void> _play(BuildContext context) async {
    await store.play(channel);
    await onChannelSelected?.call();
  }

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
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(e.message)));
        }
      },
      icon: Icon(
        c.isFavorite ? Icons.star : Icons.star_border,
        color: c.isFavorite ? Colors.amber : null,
      ),
    );

    // On TV we drop the trailing IconButton from D-pad traversal — favoriting
    // happens via the long-press action sheet instead. Keep the star itself
    // as a visual indicator so users can see at a glance which channels are
    // already favorited.
    if (isTv) {
      trailing = ExcludeFocus(
        child: Icon(
          c.isFavorite ? Icons.star : Icons.star_border,
          color: c.isFavorite ? Colors.amber : null,
        ),
      );
    }

    final tile = ListTile(
      selected: selected,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      leading: ChannelLogoAvatar(logoUrl: c.logoUrl),
      title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(c.groupName, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailing,
      onTap: isTv ? null : () => _play(context),
    );

    if (!isTv) {
      return tile;
    }

    return TvFocusableTile(
      focusNode: focusNode,
      autofocus: autofocus,
      onTap: () => _play(context),
      onLongPress: () => showChannelActionSheet(
        context,
        channel: c,
        store: store,
        onPlay: () => _play(context),
      ),
      child: tile,
    );
  }
}
