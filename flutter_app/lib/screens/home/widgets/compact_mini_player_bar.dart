import 'package:flutter/material.dart';

import '../../../models/models.dart';
import 'channel_logo_avatar.dart';

class CompactMiniPlayerBar extends StatelessWidget {
  final Channel channel;
  final bool iosCompact;
  final VoidCallback onTap;
  final VoidCallback onStop;

  const CompactMiniPlayerBar({
    super.key,
    required this.channel,
    required this.iosCompact,
    required this.onTap,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        bottom: false,
        child: SizedBox(
          height: iosCompact ? 58 : 62,
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: onTap,
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      ChannelLogoAvatar(
                        logoUrl: channel.logoUrl,
                        radius: 16,
                        iconSize: 16,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              channel.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              channel.groupName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.expand_less),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Stop playback',
                onPressed: onStop,
                icon: const Icon(Icons.stop_circle_outlined),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}
