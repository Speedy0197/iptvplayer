import 'package:flutter/material.dart';

import '../../services/casting/cast_transport.dart';
import '../../services/casting/casting_controller.dart';
import 'airplay_route_picker.dart';

String castStatusLabel(CastingController controller) {
  final device = controller.target?.name ?? 'TV';
  return switch (controller.status.state) {
    CastPlaybackState.disconnected => 'Watch on your phone',
    CastPlaybackState.connecting => 'Connecting to $device…',
    CastPlaybackState.connected => 'Connected to $device',
    CastPlaybackState.loading => 'Starting on $device…',
    CastPlaybackState.playing => 'Playing on $device',
    CastPlaybackState.paused => 'Paused on $device',
    CastPlaybackState.reconnecting => 'Reconnecting to $device…',
    CastPlaybackState.failed => 'Could not play on $device',
  };
}

class CastPlayerSurface extends StatelessWidget {
  const CastPlayerSurface({
    super.key,
    required this.controller,
    this.onNextChannel,
    this.onPreviousChannel,
  });
  final CastingController controller;
  final VoidCallback? onNextChannel;
  final VoidCallback? onPreviousChannel;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final state = controller.status.state;
      final controllable =
          state == CastPlaybackState.playing ||
          state == CastPlaybackState.paused;
      return DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF0B1628),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: .3),
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  state == CastPlaybackState.failed
                      ? Icons.cast
                      : Icons.cast_connected,
                  size: 32,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 8),
                Text(
                  castStatusLabel(controller),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (state == CastPlaybackState.loading ||
                    state == CastPlaybackState.connecting ||
                    state == CastPlaybackState.reconnecting)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: SizedBox(
                      width: 100,
                      child: LinearProgressIndicator(),
                    ),
                  ),
                if (state == CastPlaybackState.failed)
                  TextButton.icon(
                    onPressed: controller.retry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                if (controllable)
                  Wrap(
                    alignment: WrapAlignment.center,
                    children: [
                      IconButton(
                        tooltip: 'Previous channel',
                        onPressed: onPreviousChannel,
                        icon: const Icon(Icons.skip_previous),
                      ),
                      if (controller.status.canSeek)
                        IconButton(
                          tooltip: 'Back 30 seconds',
                          onPressed: () => controller.seek(
                            Duration(
                              seconds:
                                  (controller.status.position.inSeconds - 30)
                                      .clamp(0, 1 << 31),
                            ),
                          ),
                          icon: const Icon(Icons.replay_30),
                        ),
                      IconButton(
                        tooltip: state == CastPlaybackState.paused
                            ? 'Play on TV'
                            : 'Pause on TV',
                        onPressed: state == CastPlaybackState.paused
                            ? controller.play
                            : controller.pause,
                        icon: Icon(
                          state == CastPlaybackState.paused
                              ? Icons.play_arrow
                              : Icons.pause,
                        ),
                      ),
                      if (controller.status.canSeek)
                        IconButton(
                          tooltip: 'Forward 30 seconds',
                          onPressed: () => controller.seek(
                            controller.status.position +
                                const Duration(seconds: 30),
                          ),
                          icon: const Icon(Icons.forward_30),
                        ),
                      IconButton(
                        tooltip: 'Next channel',
                        onPressed: onNextChannel,
                        icon: const Icon(Icons.skip_next),
                      ),
                    ],
                  ),
                PhonePlaybackButton(controller: controller),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class PhonePlaybackButton extends StatelessWidget {
  const PhonePlaybackButton({super.key, required this.controller});
  final CastingController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.awaitingPhoneOutput) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Choose iPhone in the AirPlay picker to watch on your phone. Closing the picker keeps playback on your TV.',
            textAlign: TextAlign.center,
          ),
          Semantics(
            label: 'Choose iPhone audio output',
            child: const AirPlayRoutePicker(),
          ),
        ],
      );
    }
    return TextButton(
      onPressed: controller.returnToPhone,
      child: const Text('Watch on phone'),
    );
  }
}
