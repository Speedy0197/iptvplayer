import 'package:flutter/material.dart';

import '../../../config/device_utils.dart';
import '../../../models/models.dart';
import '../../../services/playlist_store.dart';
import '../../../widgets/adaptive_single_line_text.dart';
import 'channel_logo_avatar.dart';

class CompactMiniPlayerBar extends StatelessWidget {
  final PlaylistStore? store;
  final Channel channel;
  final bool iosCompact;
  final VoidCallback onTap;
  final VoidCallback onStop;

  const CompactMiniPlayerBar({
    super.key,
    this.store,
    required this.channel,
    required this.iosCompact,
    required this.onTap,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final source = store;
    if (source == null || !source.hasPlayer) {
      return _buildBar(context, status: 'Connecting… · Open player');
    }
    final player = source.player;
    return ValueListenableBuilder<String?>(
      valueListenable: source.playbackError,
      builder: (context, error, _) => StreamBuilder<bool>(
        stream: player.stream.playing,
        initialData: player.state.playing,
        builder: (context, playing) => StreamBuilder<bool>(
          stream: player.stream.buffering,
          initialData: player.state.buffering,
          builder: (context, buffering) {
            final isPlaying = playing.data ?? false;
            final status = error != null
                ? 'Unavailable'
                : buffering.data == true
                ? (player.state.position == Duration.zero && !isPlaying
                      ? 'Connecting…'
                      : 'Buffering…')
                : isPlaying
                ? 'Playing'
                : player.state.position == Duration.zero
                ? 'Connecting…'
                : 'Paused';
            return _buildBar(
              context,
              status: '$status · Open player',
              playing: isPlaying,
              toggle: error != null
                  ? null
                  : () {
                      if (source.nowPlaying?.streamUrl != channel.streamUrl) {
                        return;
                      }
                      if (player.state.playing) {
                        player.pause();
                      } else {
                        player.play();
                      }
                    },
            );
          },
        ),
      ),
    );
  }

  Widget _buildBar(
    BuildContext context, {
    required String status,
    bool playing = false,
    VoidCallback? toggle,
  }) {
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
                                    message: status,
                                    child: Text(
                                      status,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  )
                                : (isPhone
                                      ? AdaptiveSingleLineText(
                                          text: status,
                                          minFontSize: 10,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall,
                                        )
                                      : Text(
                                          status,
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
                tooltip: playing ? 'Pause' : 'Play',
                onPressed: toggle,
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
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
