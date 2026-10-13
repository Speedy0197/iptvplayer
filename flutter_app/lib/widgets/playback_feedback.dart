import 'package:flutter/material.dart';

/// Only allow-listed explanations reach the screen; native errors can contain
/// provider credentials even when they do not contain a recognizable URL.
const _sourceDenied =
    'This source did not allow playback. Check your source account and try again.';
const _sourceTimeout =
    'The channel is taking too long to respond. Check your connection and try again.';
const _channelUnavailable =
    'This channel could not be played. Check your connection or try another channel.';

String friendlyPlaybackError(String raw) {
  if (const {
    _sourceDenied,
    _sourceTimeout,
    _channelUnavailable,
  }.contains(raw)) {
    return raw;
  }
  final message = raw.toLowerCase();
  if (RegExp(r'\b(401|403)\b').hasMatch(message)) return _sourceDenied;
  if (message.contains('timed out') || message.contains('timeout')) {
    return _sourceTimeout;
  }
  return _channelUnavailable;
}

class PlaybackLoadingFeedback extends StatelessWidget {
  const PlaybackLoadingFeedback({super.key, required this.connecting});
  final bool connecting;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(),
        ),
        const SizedBox(height: 12),
        Text(
          connecting ? 'Connecting…' : 'Buffering…',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class PlaybackUnavailableFeedback extends StatelessWidget {
  const PlaybackUnavailableFeedback({
    super.key,
    required this.message,
    required this.onRetry,
    this.fullscreen = false,
  });
  final String message;
  final VoidCallback onRetry;
  final bool fullscreen;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.white70),
            const SizedBox(height: 8),
            const Text(
              'Unavailable',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Text(
                friendlyPlaybackError(message),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              autofocus: fullscreen,
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
            if (fullscreen) ...[
              const SizedBox(height: 12),
              const Text(
                'BACK to channels',
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
