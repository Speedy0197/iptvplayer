import 'package:flutter/material.dart';

import '../../../config/device_utils.dart';
import '../../../models/models.dart';
import '../../../widgets/adaptive_single_line_text.dart';
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
    final isPhone = isIosOrAndroidPhone(context);
    final showDesktopTooltips = isMacOrWindowsDesktop();

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
                            showDesktopTooltips
                                ? Tooltip(
                                    message: channel.name,
                                    child: Text(
                                      channel.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  )
                                : (isPhone
                                      ? AdaptiveSingleLineText(
                                          text: channel.name,
                                          minFontSize: 13,
                                        )
                                      : Text(
                                          channel.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        )),
                            showDesktopTooltips
                                ? Tooltip(
                                    message: channel.groupName,
                                    child: Text(
                                      channel.groupName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  )
                                : (isPhone
                                      ? AdaptiveSingleLineText(
                                          text: channel.groupName,
                                          minFontSize: 10,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall,
                                        )
                                      : Text(
                                          channel.groupName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall,
                                        )),
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
