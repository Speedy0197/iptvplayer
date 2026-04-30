import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../config/device_utils.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class ChannelPlayer extends StatefulWidget {
  final String streamUrl;
  final bool isActiveRecording;

  const ChannelPlayer({
    super.key,
    required this.streamUrl,
    this.isActiveRecording = false,
  });

  @override
  State<ChannelPlayer> createState() => _ChannelPlayerState();
}

class _ChannelPlayerState extends State<ChannelPlayer>
    with WidgetsBindingObserver {
  static const int _maxRetries = 2;
  static const Duration _startupTimeout = Duration(seconds: 12);
  static const Duration _recordingStaleThreshold = Duration(seconds: 6);
  static const int _maxSoftResumeFailuresBeforeReopen = 2;
  static const Duration _preemptiveEdgeThreshold = Duration(seconds: 6);
  static const Duration _preemptiveResumeCooldown = Duration(seconds: 6);

  late Player _player;
  late VideoController _controller;
  final _videoKey = GlobalKey<VideoState>();

  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<bool>? _completedSub;
  Timer? _startupTimer;
  Timer? _fullscreenResumeTimer;
  Timer? _recordingResumeTimer;
  Timer? _stalenessTimer;

  int _attempt = 0;
  bool _loading = true;
  String? _error;
  bool _lastObservedPlaying = false;
  bool _inFullscreen = false;
  AppLifecycleState? _lifecycleState;
  Duration _lastKnownPosition = Duration.zero;
  DateTime _lastPositionAdvancedAt = DateTime.now();
  bool _resumingRecording = false;
  int _softResumeFailures = 0;
  DateTime _lastPreemptiveResumeAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _backgroundHandoffInProgress = false;

  static const Map<String, String> _streamHeaders = {
    'User-Agent': 'IPTVPlayer/1.0 media_kit',
    'Connection': 'keep-alive',
  };

  void _bindPlayerStreams() {
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    _errorSub?.cancel();
    _completedSub?.cancel();

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

    _completedSub = _player.stream.completed.listen((_) {
      // Unused — staleness poller handles the active-recording case.
    });
  }

  Future<bool> _positionAdvancesWithinForPlayer({
    required Player player,
    required Duration baseline,
    required Duration timeout,
  }) async {
    final endAt = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(endAt)) {
      if (!mounted) return false;
      if (player.state.position > baseline) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return player.state.position > baseline;
  }

  Future<bool> _tryBackgroundHandoff(Duration resumeAt) async {
    if (_backgroundHandoffInProgress || !mounted) return false;
    _backgroundHandoffInProgress = true;

    final shadowPlayer = Player(
      configuration: const PlayerConfiguration(
        title: 'StreamPilot',
        logLevel: MPVLogLevel.warn,
        bufferSize: 64 * 1024 * 1024,
      ),
    );
    final shadowController = VideoController(shadowPlayer);

    try {
      await shadowPlayer.open(
        Media(widget.streamUrl, httpHeaders: _streamHeaders),
        play: false,
      );

      await shadowPlayer.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 6));

      final duration = shadowPlayer.state.duration;
      var seekTo = resumeAt + const Duration(milliseconds: 300);
      if (duration > Duration.zero && seekTo > duration) seekTo = duration;

      await shadowPlayer.seek(seekTo);
      await shadowPlayer.play();

      final ready = await _positionAdvancesWithinForPlayer(
        player: shadowPlayer,
        baseline: seekTo,
        timeout: const Duration(seconds: 2),
      );
      if (!ready || !mounted) {
        await shadowPlayer.dispose();
        return false;
      }

      final oldPlayer = _player;
      _player = shadowPlayer;
      _controller = shadowController;
      _bindPlayerStreams();

      setState(() {
        _loading = false;
        _error = null;
      });

      await oldPlayer.dispose();
      return true;
    } catch (_) {
      await shadowPlayer.dispose();
      return false;
    } finally {
      _backgroundHandoffInProgress = false;
    }
  }

  Future<bool> _positionAdvancesWithin({
    required Duration baseline,
    required Duration timeout,
  }) async {
    final endAt = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(endAt)) {
      if (!mounted) return false;
      if (_player.state.position > baseline) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return _player.state.position > baseline;
  }

  Future<bool> _trySoftRecordingResume(Duration resumeAt) async {
    try {
      // First try to continue immediately without reopening the stream.
      await _player.play();
      if (await _positionAdvancesWithin(
        baseline: resumeAt,
        timeout: const Duration(seconds: 2),
      )) {
        return true;
      }

      // Nudge slightly forward (never backward) to avoid visible rewind.
      final nowPos = _player.state.position;
      final currentDuration = _player.state.duration;
      var nudgeTo = nowPos + const Duration(milliseconds: 300);
      if (currentDuration > Duration.zero && nudgeTo > currentDuration) {
        nudgeTo = currentDuration;
      }
      if (nudgeTo < nowPos) {
        nudgeTo = nowPos;
      }

      await _player.seek(nudgeTo);
      await _player.play();
      return await _positionAdvancesWithin(
        baseline: nowPos,
        timeout: const Duration(seconds: 2),
      );
    } catch (_) {
      return false;
    }
  }

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

    // Force software video decoding at the libmpv level on Android BEFORE
    // creating VideoController. NVIDIA Tegra and older Android TV chips cannot
    // synchronize ImageTextureEntry surfaces properly. Software decoding writes
    // plain YUV/RGB frames that pixel-buffer surfaces can display.
    if (Platform.isAndroid) {
      try {
        final nativePlayer = _player.platform;
        if (nativePlayer is NativePlayer) {
          debugPrint('Setting hwdec=no for Android');
          nativePlayer.setProperty('hwdec', 'no');
          debugPrint('hwdec property set successfully');
        } else {
          debugPrint(
            'Player platform is not NativePlayer: ${nativePlayer.runtimeType}',
          );
        }
      } catch (e) {
        debugPrint('Failed to configure hwdec: $e');
      }
    }

    _controller = VideoController(_player);

    _bindPlayerStreams();

    // If position hasn't advanced for a while while buffering/stalled and
    // we're watching an active recording, first try a soft resume (play/seek)
    // and only hard-reopen as a fallback.
    _stalenessTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted) return;
      final pos = _player.state.position;
      final duration = _player.state.duration;
      final isBuffering = _player.state.buffering;
      final isPlaying = _player.state.playing;
      if (!widget.isActiveRecording || _resumingRecording) return;

      // For growing recording files, proactively nudge the stream shortly
      // before the current known EOF to avoid an observable stop/reopen.
      final remaining = duration - pos;
      final nearKnownEdge =
          duration > Duration.zero &&
          pos > Duration.zero &&
          remaining <= _preemptiveEdgeThreshold;
      final canPreemptNow =
          DateTime.now().difference(_lastPreemptiveResumeAt) >=
          _preemptiveResumeCooldown;
      if (isPlaying && !isBuffering && nearKnownEdge && canPreemptNow) {
        _lastPreemptiveResumeAt = DateTime.now();
        final handoffOk = await _tryBackgroundHandoff(pos);
        if (handoffOk) {
          _softResumeFailures = 0;
          _lastPositionAdvancedAt = DateTime.now();
          _lastKnownPosition = _player.state.position;
          return;
        }

        final preemptiveOk = await _trySoftRecordingResume(pos);
        if (preemptiveOk) {
          _softResumeFailures = 0;
          _lastPositionAdvancedAt = DateTime.now();
          return;
        }
      }

      if (pos > Duration.zero && pos != _lastKnownPosition) {
        _lastKnownPosition = pos;
        _lastPositionAdvancedAt = DateTime.now();
        _softResumeFailures = 0;
        return;
      }

      // Only act if stalled (buffering or not playing) for >4s
      if (isPlaying && !isBuffering) return;
      if (_lastKnownPosition == Duration.zero) return;
      final staleFor = DateTime.now().difference(_lastPositionAdvancedAt);
      if (staleFor < _recordingStaleThreshold) return;

      _resumingRecording = true;
      _lastPositionAdvancedAt = DateTime.now();

      final resumeAt = _lastKnownPosition;
      try {
        final softResumed = await _trySoftRecordingResume(resumeAt);
        if (softResumed) {
          _softResumeFailures = 0;
          return;
        }

        _softResumeFailures += 1;
        if (_softResumeFailures < _maxSoftResumeFailuresBeforeReopen) {
          return;
        }

        await _player.open(
          Media(
            widget.streamUrl,
            httpHeaders: const {
              'User-Agent': 'IPTVPlayer/1.0 media_kit',
              'Connection': 'keep-alive',
            },
          ),
          play: false,
        );
        await _player.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 8));
        await _player.seek(resumeAt);
        await _player.play();
        _softResumeFailures = 0;
      } catch (e) {
        debugPrint('Recording resume failed: $e');
      } finally {
        if (mounted) _resumingRecording = false;
      }
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
      _lastKnownPosition = Duration.zero;
      _lastPositionAdvancedAt = DateTime.now();
      _resumingRecording = false;
      _softResumeFailures = 0;
      _recordingResumeTimer?.cancel();
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
        Media(widget.streamUrl, httpHeaders: _streamHeaders),
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
    _recordingResumeTimer?.cancel();
    _stalenessTimer?.cancel();
    _startupTimer?.cancel();
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    _errorSub?.cancel();
    _completedSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  void _enterFullscreen() {
    _videoKey.currentState?.enterFullscreen();
  }

  @override
  Widget build(BuildContext context) {
    final playerWidget = ClipRRect(
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

    // On non-Android-TV platforms just return the player as-is.
    if (!isAndroidTv(context)) return playerWidget;

    // On Android TV: overlay a focusable fullscreen button in the corner so
    // the user can reach it with the D-pad and press OK to go fullscreen.
    return Stack(
      children: [
        playerWidget,
        Positioned(
          right: 8,
          bottom: 8,
          child: Focus(
            autofocus: false,
            child: Builder(
              builder: (context) {
                final hasFocus = Focus.of(context).hasFocus;
                return Tooltip(
                  message: 'Fullscreen',
                  child: InkWell(
                    focusColor: Colors.white24,
                    onTap: _enterFullscreen,
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: hasFocus ? Colors.white30 : Colors.black54,
                        borderRadius: BorderRadius.circular(4),
                        border: hasFocus
                            ? Border.all(color: Colors.white, width: 2)
                            : null,
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.fullscreen, color: Colors.white, size: 16),
                          SizedBox(width: 4),
                          Text(
                            'OK',
                            style: TextStyle(color: Colors.white, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPlayer() {
    if (_error != null) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: SingleChildScrollView(
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
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
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
        ),
      );
    }

    return Video(
      key: _videoKey,
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
