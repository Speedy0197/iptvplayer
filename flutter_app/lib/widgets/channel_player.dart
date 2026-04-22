import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class ChannelPlayer extends StatefulWidget {
  final String streamUrl;

  const ChannelPlayer({super.key, required this.streamUrl});

  @override
  State<ChannelPlayer> createState() => _ChannelPlayerState();
}

class _ChannelPlayerState extends State<ChannelPlayer>
    with WidgetsBindingObserver {
  static const int _maxRetries = 2;
  static const Duration _startupTimeout = Duration(seconds: 12);

  late final Player _player;
  late final VideoController _controller;

  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<String>? _errorSub;
  Timer? _startupTimer;
  Timer? _fullscreenResumeTimer;

  int _attempt = 0;
  bool _loading = true;
  String? _error;
  bool _lastObservedPlaying = false;
  bool _inFullscreen = false;
  AppLifecycleState? _lifecycleState;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
  }

  Future<void> _toggleNativeFullscreen({required bool entering}) async {
    _inFullscreen = entering;

    final shouldResume =
        _player.state.playing ||
        _lastObservedPlaying ||
        (Platform.isIOS && entering);

    if (entering) {
      await defaultEnterNativeFullscreen();
    } else {
      await defaultExitNativeFullscreen();
    }

    _refreshVideoOutputAfterTransition(shouldResume: shouldResume);
  }

  void _refreshVideoOutputAfterTransition({required bool shouldResume}) {
    _fullscreenResumeTimer?.cancel();
    if (!mounted) return;

    if (!Platform.isIOS) {
      _fullscreenResumeTimer = Timer(const Duration(milliseconds: 400), () {
        if (!mounted || _player.state.playing) return;
        _player.play();
      });
      return;
    }

    // iOS: the player state reports playing=true throughout the fullscreen
    // transition, but the video appears frozen because media_kit_video's
    // fullscreen route attaches a new rendering surface and the decoder has
    // not yet flushed a frame to it.
    //
    // Seeking to the current position forces the decoder to deliver a fresh
    // frame to the new surface, unfreezing the video. We wait 400 ms to give
    // the route animation time to attach the surface before seeking.
    _fullscreenResumeTimer = Timer(const Duration(milliseconds: 400), () async {
      if (!mounted) return;

      final pos = _player.state.position;
      try {
        await _player.seek(pos);
      } catch (_) {
        // Ignore transient seek failures during fullscreen transition.
      }

      if (mounted && shouldResume && !_player.state.playing) {
        await _player.play();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _player = Player(
      configuration: const PlayerConfiguration(
        title: 'StreamPilot',
        logLevel: MPVLogLevel.warn,
        bufferSize: 64 * 1024 * 1024,
      ),
    );
    _controller = VideoController(_player);

    _playingSub = _player.stream.playing.listen((playing) {
      _lastObservedPlaying = playing;
      if (!mounted) return;

      // While in fullscreen on iOS, the inner Video widget created by
      // media_kit_video's fullscreen route can pause the player on any
      // lifecycle transition. Only honour a pause when truly backgrounded.
      if (!playing &&
          Platform.isIOS &&
          _inFullscreen &&
          _lifecycleState != AppLifecycleState.paused) {
        _player.play();
        return;
      }

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
    WidgetsBinding.instance.removeObserver(this);
    _fullscreenResumeTimer?.cancel();
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
      pauseUponEnteringBackgroundMode: !Platform.isIOS,
      resumeUponEnteringForegroundMode: true,
      onEnterFullscreen: () => _toggleNativeFullscreen(entering: true),
      onExitFullscreen: () => _toggleNativeFullscreen(entering: false),
    );
  }
}
