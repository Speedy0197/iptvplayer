import 'package:flutter/material.dart';

import '../../../config/device_utils.dart';
import '../../../models/models.dart';
import 'channel_logo_avatar.dart';

class SearchChannelResultTile extends StatelessWidget {
  final Channel channel;
  final String playlistName;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  const SearchChannelResultTile({
    required super.key,
    required this.channel,
    required this.playlistName,
    required this.onTap,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final showDesktopTooltips = isMacOrWindowsDesktop();

    return ListTile(
      focusNode: focusNode,
      isThreeLine: false,
      leading: ChannelLogoAvatar(
        logoUrl: channel.logoUrl,
        radius: 14,
        iconSize: 16,
      ),
      title: showDesktopTooltips
          ? Tooltip(
              message: channel.name,
              child: Text(
                channel.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            )
          : Text(channel.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          playlistName,
          if (channel.groupName.trim().isNotEmpty) channel.groupName,
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onTap,
    );
  }
}
