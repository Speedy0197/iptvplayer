import 'package:flutter/material.dart';

import '../../../models/models.dart';
import 'channel_logo_avatar.dart';

class SearchChannelResultTile extends StatelessWidget {
  final Channel channel;
  final String playlistName;
  final VoidCallback onTap;

  const SearchChannelResultTile({
    required super.key,
    required this.channel,
    required this.playlistName,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: ChannelLogoAvatar(
        logoUrl: channel.logoUrl,
        radius: 14,
        iconSize: 16,
      ),
      title: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Chip(
              label: Text(playlistName, style: const TextStyle(fontSize: 11)),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 4),
            Chip(
              label: Text(
                channel.groupName,
                style: const TextStyle(fontSize: 11),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
      onTap: onTap,
    );
  }
}
