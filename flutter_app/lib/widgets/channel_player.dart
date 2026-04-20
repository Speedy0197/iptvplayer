import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class ChannelPlayer extends StatefulWidget {
  final String streamUrl;

  const ChannelPlayer({super.key, required this.streamUrl});

  @override
  State<ChannelPlayer> createState() => _ChannelPlayerState();
}

class _ChannelPlayerState extends State<ChannelPlayer> {
  static const int _maxRetries = 2;
  static const Duration _startupTimeout = Duration(seconds: 12);

  late final Player _player;
  late final VideoController _controller;

  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<String>? _errorSub;
  Timer? _startupTimer;

  int _attempt = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _player = Player(
      configuration: const PlayerConfiguration(
        title: 'StreamPilot',
        logLevel: MPVLogLevel.warn,
        bufferSize: 64 * 1024 * 1024,
      ),
    );
    _controller = VideoController(_player);

    _playingSub = _player.stream.playing.listen((playing) {
      if (!mounted) return;
      if (playing) {
        _startupTimer?.cancel();
        setState(() {
          _loading = false;
          _error = null;
        });
      }
    });

    _bufferingSub = _player.stream.buffering.listen((buffering) {
      if (!mounted) return;
      setState(() {
        _loading = buffering;
      });
    });

    _errorSub = _player.stream.error.listen((message) {
      _handleFailure('Playback error: $message');
    });

    _openCurrentStream(resetAttempts: true);
  }

  @override
  void didUpdateWidget(covariant ChannelPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.streamUrl != widget.streamUrl) {
      _openCurrentStream(resetAttempts: true);
    }
  }

  Future<void> _openCurrentStream({required bool resetAttempts}) async {
    if (resetAttempts) {
      _attempt = 0;
    }

    _startupTimer?.cancel();
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    _startupTimer = Timer(_startupTimeout, () {
      _handleFailure('Timed out while opening stream.');
    });

    try {
      await _player.open(
        Media(
          widget.streamUrl,
          httpHeaders: const {
            'User-Agent': 'IPTVPlayer/1.0 media_kit',
            'Connection': 'keep-alive',
          },
        ),
        play: true,
      );
    } catch (_) {
      _handleFailure('Could not open stream.');
    }
  }

  void _handleFailure(String message) {
    if (!mounted) return;
    _startupTimer?.cancel();

    if (_attempt < _maxRetries) {
      _attempt += 1;
      _openCurrentStream(resetAttempts: false);
      return;
    }

    setState(() {
      _loading = false;
      _error = message;
    });
  }

  @override
  void dispose() {
    _startupTimer?.cancel();
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    _errorSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          children: [
            Positioned.fill(child: _buildPlayer()),
            if (_loading && _error == null)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0x66000000),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayer() {
    if (_error != null) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent),
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                FilledButton.tonal(
                  onPressed: () => _openCurrentStream(resetAttempts: true),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Video(
      controller: _controller,
      controls: AdaptiveVideoControls,
      fit: BoxFit.contain,
      pauseUponEnteringBackgroundMode: false,
    );
  }
}
