import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../config/device_utils.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class ChannelPlayer extends StatefulWidget {
  final String streamUrl;
  final bool isActiveRecording;
  final VoidCallback? onNextChannel;
  final VoidCallback? onPreviousChannel;

  const ChannelPlayer({
    super.key,
    required this.streamUrl,
    this.isActiveRecording = false,
    this.onNextChannel,
    this.onPreviousChannel,
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
  Timer? _recordingResumeTimer;
  Timer? _stalenessTimer;

  int _attempt = 0;
  bool _loading = true;
  String? _error;
  bool _inFullscreen = false;
  AppLifecycleState? _lifecycleState;
  Duration _lastKnownPosition = Duration.zero;
  DateTime _lastPositionAdvancedAt = DateTime.now();
  bool _resumingRecording = false;
  int _softResumeFailures = 0;
  DateTime _lastPreemptiveResumeAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _backgroundHandoffInProgress = false;
  bool _controlsVisibleNonFullscreen = true;
  Timer? _hideControlsNonFullscreenTimer;
  FocusNode? _tvFullscreenFocusNode;

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isAndroid) {
      _tvFullscreenFocusNode = FocusNode();
      _tvFullscreenFocusNode!.addListener(() {
        if (mounted) setState(() {});
      });
    }
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
    _recordingResumeTimer?.cancel();
    _stalenessTimer?.cancel();
    _startupTimer?.cancel();
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    _errorSub?.cancel();
    _completedSub?.cancel();
    _hideControlsNonFullscreenTimer?.cancel();
    _tvFullscreenFocusNode?.dispose();
    _player.dispose();
    super.dispose();
  }

  void _enterFullscreen() {
    if (_inFullscreen || !mounted) return;

    setState(() => _inFullscreen = true);
    unawaited(_setMacOSNativeFullscreen(true));

    Navigator.of(context, rootNavigator: true)
        .push(
          PageRouteBuilder<void>(
            opaque: true,
            pageBuilder: (context, animation, secondaryAnimation) =>
                _FullscreenChannelView(
                  player: _player,
                  controller: _controller,
                  onNextChannel: widget.onNextChannel,
                  onPreviousChannel: widget.onPreviousChannel,
                ),
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) =>
                    FadeTransition(opacity: animation, child: child),
          ),
        )
        .whenComplete(() {
          if (mounted) {
            setState(() => _inFullscreen = false);
          }
          unawaited(_setMacOSNativeFullscreen(false));
        });
  }

  Future<void> _setMacOSNativeFullscreen(bool enabled) async {
    if (!Platform.isMacOS) return;
    try {
      final currentlyFullscreen = await windowManager.isFullScreen();
      if (currentlyFullscreen != enabled) {
        await windowManager.setFullScreen(enabled);
      }
    } catch (e) {
      debugPrint('Failed to toggle macOS native fullscreen: $e');
    }
  }

  void _showControlsNonFullscreen() {
    if (!mounted) return;
    setState(() => _controlsVisibleNonFullscreen = true);
    _hideControlsNonFullscreenTimer?.cancel();
    _hideControlsNonFullscreenTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() => _controlsVisibleNonFullscreen = false);
      }
    });
  }

  String _formatDuration(Duration value) {
    final totalSeconds = value.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _togglePlayPause() async {
    if (_player.state.playing) {
      await _player.pause();
      return;
    }
    await _player.play();
  }

  Future<void> _seekBy(Duration delta) async {
    final current = _player.state.position;
    final duration = _player.state.duration;
    var target = current + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    await _player.seek(target);
  }

  double _lastNonZeroVolume = 100.0;

  Future<void> _toggleMute() async {
    final volume = _player.state.volume;
    if (volume > 0) {
      _lastNonZeroVolume = volume;
      await _player.setVolume(0);
      return;
    }
    final restore = _lastNonZeroVolume <= 0 ? 100.0 : _lastNonZeroVolume;
    await _player.setVolume(restore);
  }

  Widget _buildControlBar() {
    final isCompactIos = Platform.isIOS;
    final horizontalPadding = isCompactIos ? 6.0 : 8.0;
    final verticalPadding = isCompactIos ? 4.0 : 6.0;
    final timeFontSize = isCompactIos ? 9.0 : 10.0;
    final trackHeight = isCompactIos ? 1.5 : 2.0;
    final thumbRadius = isCompactIos ? 3.0 : 4.0;
    final rowGap = isCompactIos ? 1.0 : 2.0;
    final smallButtonSize = isCompactIos ? 24.0 : 28.0;
    final playButtonSize = isCompactIos ? 28.0 : 32.0;
    final iconSize = isCompactIos ? 14.0 : 16.0;
    final playIconSize = isCompactIos ? 22.0 : 26.0;

    return StreamBuilder<Duration>(
      stream: _player.stream.position,
      initialData: _player.state.position,
      builder: (context, positionSnapshot) {
        final position = positionSnapshot.data ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: _player.stream.duration,
          initialData: _player.state.duration,
          builder: (context, durationSnapshot) {
            final duration = durationSnapshot.data ?? Duration.zero;
            final hasFiniteDuration = duration > Duration.zero;
            final maxMs = hasFiniteDuration
                ? duration.inMilliseconds.toDouble()
                : 1.0;
            final currentMs = hasFiniteDuration
                ? position.inMilliseconds
                      .clamp(0, duration.inMilliseconds)
                      .toDouble()
                : 0.0;

            return Material(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: horizontalPadding,
                  vertical: verticalPadding,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          _formatDuration(position),
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: timeFontSize,
                          ),
                        ),
                        SizedBox(width: isCompactIos ? 4 : 6),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: trackHeight,
                              thumbShape: RoundSliderThumbShape(
                                enabledThumbRadius: thumbRadius,
                              ),
                            ),
                            child: Slider(
                              value: currentMs,
                              min: 0,
                              max: maxMs,
                              onChanged: !hasFiniteDuration
                                  ? null
                                  : (value) {
                                      _player.seek(
                                        Duration(milliseconds: value.round()),
                                      );
                                    },
                            ),
                          ),
                        ),
                        SizedBox(width: isCompactIos ? 4 : 6),
                        Text(
                          hasFiniteDuration
                              ? _formatDuration(duration)
                              : 'LIVE',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: timeFontSize,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: rowGap),
                    Row(
                      children: [
                        Expanded(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: smallButtonSize,
                                height: smallButtonSize,
                                child: IconButton(
                                  padding: EdgeInsets.zero,
                                  tooltip: 'Back 10s',
                                  iconSize: iconSize,
                                  icon: const Icon(
                                    Icons.replay_10,
                                    color: Colors.white,
                                  ),
                                  onPressed: () =>
                                      _seekBy(const Duration(seconds: -10)),
                                ),
                              ),
                              SizedBox(width: isCompactIos ? 2 : 4),
                              StreamBuilder<bool>(
                                stream: _player.stream.playing,
                                initialData: _player.state.playing,
                                builder: (context, playingSnapshot) {
                                  final playing =
                                      playingSnapshot.data ??
                                      _player.state.playing;
                                  return SizedBox(
                                    width: playButtonSize,
                                    height: playButtonSize,
                                    child: IconButton(
                                      padding: EdgeInsets.zero,
                                      tooltip: playing ? 'Pause' : 'Play',
                                      icon: Icon(
                                        playing
                                            ? Icons.pause_circle_filled
                                            : Icons.play_circle_fill,
                                        color: Colors.white,
                                        size: playIconSize,
                                      ),
                                      onPressed: _togglePlayPause,
                                    ),
                                  );
                                },
                              ),
                              SizedBox(width: isCompactIos ? 2 : 4),
                              SizedBox(
                                width: smallButtonSize,
                                height: smallButtonSize,
                                child: IconButton(
                                  padding: EdgeInsets.zero,
                                  tooltip: 'Forward 10s',
                                  iconSize: iconSize,
                                  icon: const Icon(
                                    Icons.forward_10,
                                    color: Colors.white,
                                  ),
                                  onPressed: () =>
                                      _seekBy(const Duration(seconds: 10)),
                                ),
                              ),
                              SizedBox(width: isCompactIos ? 4 : 8),
                              StreamBuilder<double>(
                                stream: _player.stream.volume,
                                initialData: _player.state.volume,
                                builder: (context, volumeSnapshot) {
                                  final volume =
                                      volumeSnapshot.data ??
                                      _player.state.volume;
                                  final muted = volume <= 0.0;
                                  return SizedBox(
                                    width: smallButtonSize,
                                    height: smallButtonSize,
                                    child: IconButton(
                                      padding: EdgeInsets.zero,
                                      tooltip: muted ? 'Unmute' : 'Mute',
                                      iconSize: iconSize,
                                      icon: Icon(
                                        muted
                                            ? Icons.volume_off
                                            : Icons.volume_up,
                                        color: Colors.white,
                                      ),
                                      onPressed: _toggleMute,
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                        if (!isAndroidTv(context))
                          SizedBox(
                            width: smallButtonSize,
                            height: smallButtonSize,
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              tooltip: 'Fullscreen',
                              iconSize: iconSize,
                              icon: const Icon(
                                Icons.fullscreen,
                                color: Colors.white,
                              ),
                              onPressed: _enterFullscreen,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTv = isAndroidTv(context);
    final hasTvFocus = _tvFullscreenFocusNode?.hasFocus ?? false;

    final playerWidget = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: MouseRegion(
          onEnter: (_) => _showControlsNonFullscreen(),
          onHover: (_) => _showControlsNonFullscreen(),
          child: GestureDetector(
            onTapDown: (_) => _showControlsNonFullscreen(),
            behavior: HitTestBehavior.translucent,
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
                // Nav arrows (non-fullscreen) with auto-hide
                if (!isTv && widget.onPreviousChannel != null)
                  Positioned(
                    left: 8,
                    top: 50,
                    bottom: 50,
                    width: 24,
                    child: AnimatedOpacity(
                      opacity: _controlsVisibleNonFullscreen ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 300),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.onPreviousChannel,
                        child: const Center(
                          child: Icon(
                            Icons.chevron_left,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (!isTv && widget.onNextChannel != null)
                  Positioned(
                    right: 8,
                    top: 50,
                    bottom: 50,
                    width: 24,
                    child: AnimatedOpacity(
                      opacity: _controlsVisibleNonFullscreen ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 300),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.onNextChannel,
                        child: const Center(
                          child: Icon(
                            Icons.chevron_right,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                  ),
                // Bottom control bar (non-fullscreen) — hidden from D-pad focus on TV
                if (!isTv)
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: AnimatedOpacity(
                      opacity: _controlsVisibleNonFullscreen ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 300),
                      child: _buildControlBar(),
                    ),
                  ),
                if (isTv)
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: Focus(
                      focusNode: _tvFullscreenFocusNode,
                      autofocus: true,
                      onKeyEvent: (node, event) {
                        if (event is KeyDownEvent &&
                            (event.logicalKey == LogicalKeyboardKey.select ||
                                event.logicalKey == LogicalKeyboardKey.enter)) {
                          _enterFullscreen();
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: GestureDetector(
                        onTap: _enterFullscreen,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: hasTvFocus ? Colors.white30 : Colors.black54,
                            borderRadius: BorderRadius.circular(8),
                            border: hasTvFocus
                                ? Border.all(color: Colors.white, width: 2)
                                : null,
                          ),
                          child: const Icon(
                            Icons.fullscreen,
                            color: Colors.white,
                            size: 22,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    // On non-Android-TV platforms just return the player as-is.
    return playerWidget;
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
      controls: NoVideoControls,
      fit: BoxFit.contain,
      pauseUponEnteringBackgroundMode: !Platform.isIOS,
      resumeUponEnteringForegroundMode: true,
    );
  }
}

class _FullscreenChannelView extends StatefulWidget {
  const _FullscreenChannelView({
    required this.player,
    required this.controller,
    required this.onNextChannel,
    required this.onPreviousChannel,
  });

  final Player player;
  final VideoController controller;
  final VoidCallback? onNextChannel;
  final VoidCallback? onPreviousChannel;

  @override
  State<_FullscreenChannelView> createState() => _FullscreenChannelViewState();
}

class _FullscreenChannelViewState extends State<_FullscreenChannelView>
    with WidgetsBindingObserver {
  double _lastNonZeroVolume = 100.0;
  bool _controlsVisible = true;
  Timer? _hideControlsTimer;
  FocusNode? _tvFocusNode;
  FocusNode? _tvPreviousChannelFocusNode;
  FocusNode? _tvTimelineFocusNode;
  FocusNode? _tvBack10FocusNode;
  FocusNode? _tvPlayPauseFocusNode;
  FocusNode? _tvForward10FocusNode;
  FocusNode? _tvMuteFocusNode;
  FocusNode? _tvNextChannelFocusNode;
  FocusNode? _tvExitFullscreenFocusNode;
  bool _tvControlsMode = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      _tvFocusNode = FocusNode();
      _tvPreviousChannelFocusNode = FocusNode();
      _tvTimelineFocusNode = FocusNode();
      _tvBack10FocusNode = FocusNode();
      _tvPlayPauseFocusNode = FocusNode();
      _tvForward10FocusNode = FocusNode();
      _tvMuteFocusNode = FocusNode();
      _tvNextChannelFocusNode = FocusNode();
      _tvExitFullscreenFocusNode = FocusNode();
      for (final node in _tvControlNodes()) {
        node?.addListener(_onAnyTvFocusChange);
      }
    }
    _resetHideControlsTimer();
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    for (final node in _tvControlNodes()) {
      node?.removeListener(_onAnyTvFocusChange);
    }
    _tvFocusNode?.dispose();
    _tvPreviousChannelFocusNode?.dispose();
    _tvTimelineFocusNode?.dispose();
    _tvBack10FocusNode?.dispose();
    _tvPlayPauseFocusNode?.dispose();
    _tvForward10FocusNode?.dispose();
    _tvMuteFocusNode?.dispose();
    _tvNextChannelFocusNode?.dispose();
    _tvExitFullscreenFocusNode?.dispose();
    super.dispose();
  }

  void _onAnyTvFocusChange() {
    if (!mounted) return;
    setState(() {});
  }

  bool _hasFocusedFullscreenControl() {
    return (_tvPreviousChannelFocusNode?.hasFocus ?? false) ||
        (_tvTimelineFocusNode?.hasFocus ?? false) ||
        (_tvBack10FocusNode?.hasFocus ?? false) ||
        (_tvPlayPauseFocusNode?.hasFocus ?? false) ||
        (_tvForward10FocusNode?.hasFocus ?? false) ||
        (_tvMuteFocusNode?.hasFocus ?? false) ||
        (_tvNextChannelFocusNode?.hasFocus ?? false) ||
        (_tvExitFullscreenFocusNode?.hasFocus ?? false);
  }

  List<FocusNode?> _tvControlNodes() {
    return [
      _tvPreviousChannelFocusNode,
      _tvTimelineFocusNode,
      _tvBack10FocusNode,
      _tvPlayPauseFocusNode,
      _tvForward10FocusNode,
      _tvMuteFocusNode,
      _tvNextChannelFocusNode,
      _tvExitFullscreenFocusNode,
    ];
  }

  List<FocusNode> _enabledBottomControlNodes() {
    final nodes = <FocusNode>[];
    if (_tvBack10FocusNode != null) nodes.add(_tvBack10FocusNode!);
    if (_tvPlayPauseFocusNode != null) nodes.add(_tvPlayPauseFocusNode!);
    if (_tvForward10FocusNode != null) nodes.add(_tvForward10FocusNode!);
    if (_tvMuteFocusNode != null) nodes.add(_tvMuteFocusNode!);
    if (_tvExitFullscreenFocusNode != null) {
      nodes.add(_tvExitFullscreenFocusNode!);
    }
    return nodes;
  }

  bool _isSideChannelFocusActive() {
    return (_tvPreviousChannelFocusNode?.hasFocus ?? false) ||
        (_tvNextChannelFocusNode?.hasFocus ?? false);
  }

  bool _isTimelineFocusActive() {
    return _tvTimelineFocusNode?.hasFocus ?? false;
  }

  bool _isBottomControlFocusActive() {
    return (_tvBack10FocusNode?.hasFocus ?? false) ||
        (_tvPlayPauseFocusNode?.hasFocus ?? false) ||
        (_tvForward10FocusNode?.hasFocus ?? false) ||
        (_tvMuteFocusNode?.hasFocus ?? false) ||
        (_tvExitFullscreenFocusNode?.hasFocus ?? false);
  }

  void _focusPlayPauseControl() {
    (_tvPlayPauseFocusNode ?? _tvFocusNode)?.requestFocus();
  }

  void _focusTimelineControl() {
    (_tvTimelineFocusNode ?? _tvPlayPauseFocusNode ?? _tvFocusNode)
        ?.requestFocus();
  }

  bool _focusPreferredSideChannelControl() {
    final rightBias =
        (_tvNextChannelFocusNode?.hasFocus ?? false) ||
        (_tvForward10FocusNode?.hasFocus ?? false) ||
        (_tvMuteFocusNode?.hasFocus ?? false) ||
        (_tvExitFullscreenFocusNode?.hasFocus ?? false);

    if (rightBias && widget.onNextChannel != null) {
      _tvNextChannelFocusNode?.requestFocus();
      return true;
    }
    if (!rightBias && widget.onPreviousChannel != null) {
      _tvPreviousChannelFocusNode?.requestFocus();
      return true;
    }

    if (widget.onNextChannel != null) {
      _tvNextChannelFocusNode?.requestFocus();
      return true;
    }
    if (widget.onPreviousChannel != null) {
      _tvPreviousChannelFocusNode?.requestFocus();
      return true;
    }
    return false;
  }

  bool _moveBottomControlFocus({required bool forward}) {
    final nodes = _enabledBottomControlNodes();
    if (nodes.isEmpty) return false;
    var currentIndex = nodes.indexWhere(
      (node) => node.hasPrimaryFocus || node.hasFocus,
    );
    if (currentIndex < 0) {
      currentIndex = 1; // default to Play/Pause if focus is unclear
    }
    final nextIndex = forward
        ? (currentIndex + 1).clamp(0, nodes.length - 1)
        : (currentIndex - 1).clamp(0, nodes.length - 1);
    if (nextIndex == currentIndex) return false;
    nodes[nextIndex].requestFocus();
    return true;
  }

  bool _moveSideChannelFocus({required bool forward}) {
    final nodes = <FocusNode>[];
    if (widget.onPreviousChannel != null &&
        _tvPreviousChannelFocusNode != null) {
      nodes.add(_tvPreviousChannelFocusNode!);
    }
    if (widget.onNextChannel != null && _tvNextChannelFocusNode != null) {
      nodes.add(_tvNextChannelFocusNode!);
    }
    if (nodes.length < 2) return false;
    final currentIndex = nodes.indexWhere(
      (node) => node.hasPrimaryFocus || node.hasFocus,
    );
    if (currentIndex < 0) {
      nodes.first.requestFocus();
      return true;
    }
    final nextIndex = forward ? currentIndex + 1 : currentIndex - 1;
    if (nextIndex < 0 || nextIndex >= nodes.length) return false;
    nodes[nextIndex].requestFocus();
    return true;
  }

  Widget _buildTvFocusFrame({
    required FocusNode? focusNode,
    required Widget child,
  }) {
    final focused = focusNode?.hasFocus ?? false;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: focused
            ? Colors.white.withValues(alpha: 0.14)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: focused
            ? Border.all(color: Colors.white, width: 2)
            : Border.all(color: Colors.transparent, width: 2),
      ),
      child: child,
    );
  }

  void _resetHideControlsTimer() {
    _hideControlsTimer?.cancel();
    if (!mounted) return;
    setState(() => _controlsVisible = true);
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      if (isAndroidTv(context)) {
        _tvControlsMode = false;
        _tvFocusNode?.requestFocus();
      }
      setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    if (!mounted) return;
    setState(() => _controlsVisible = true);
    _resetHideControlsTimer();
  }

  String _formatDuration(Duration value) {
    final totalSeconds = value.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _togglePlayPause() async {
    if (widget.player.state.playing) {
      await widget.player.pause();
      return;
    }
    await widget.player.play();
  }

  Future<void> _seekBy(Duration delta) async {
    final current = widget.player.state.position;
    final duration = widget.player.state.duration;
    var target = current + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    await widget.player.seek(target);
  }

  Future<void> _toggleMute() async {
    final volume = widget.player.state.volume;
    if (volume > 0) {
      _lastNonZeroVolume = volume;
      await widget.player.setVolume(0);
      return;
    }
    final restore = _lastNonZeroVolume <= 0 ? 100.0 : _lastNonZeroVolume;
    await widget.player.setVolume(restore);
  }

  @override
  Widget build(BuildContext context) {
    final safePadding = MediaQuery.paddingOf(context);
    final isTv = isAndroidTv(context);

    Widget scaffold = Scaffold(
      backgroundColor: Colors.black,
      body: MouseRegion(
        onEnter: (_) => _showControls(),
        onHover: (_) => _showControls(),
        child: GestureDetector(
          onTapDown: (_) => _showControls(),
          behavior: HitTestBehavior.translucent,
          child: Stack(
            children: [
              // Video
              Positioned.fill(
                child: StreamBuilder<bool>(
                  stream: widget.player.stream.playing,
                  initialData: widget.player.state.playing,
                  builder: (context, snapshot) {
                    final hasStartedPlayback =
                        (snapshot.data ?? false) ||
                        widget.player.state.position > Duration.zero;
                    return Center(
                      child: hasStartedPlayback
                          ? Video(
                              controller: widget.controller,
                              controls: NoVideoControls,
                              fit: BoxFit.contain,
                              pauseUponEnteringBackgroundMode: !Platform.isIOS,
                              resumeUponEnteringForegroundMode: true,
                            )
                          : const SizedBox(
                              width: 40,
                              height: 40,
                              child: CircularProgressIndicator(),
                            ),
                    );
                  },
                ),
              ),
              if (widget.onPreviousChannel != null)
                Positioned(
                  left: safePadding.left + 8,
                  top: 0,
                  bottom: 0,
                  width: 52,
                  child: AnimatedOpacity(
                    opacity: _controlsVisible ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 300),
                    child: Center(
                      child: _buildTvFocusFrame(
                        focusNode: isTv ? _tvPreviousChannelFocusNode : null,
                        child: IconButton(
                          tooltip: 'Previous channel',
                          focusNode: isTv ? _tvPreviousChannelFocusNode : null,
                          onPressed: widget.onPreviousChannel,
                          icon: const Icon(
                            Icons.chevron_left,
                            color: Colors.white,
                            size: 34,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (widget.onNextChannel != null)
                Positioned(
                  right: safePadding.right + 8,
                  top: 0,
                  bottom: 0,
                  width: 52,
                  child: AnimatedOpacity(
                    opacity: _controlsVisible ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 300),
                    child: Center(
                      child: _buildTvFocusFrame(
                        focusNode: isTv ? _tvNextChannelFocusNode : null,
                        child: IconButton(
                          tooltip: 'Next channel',
                          focusNode: isTv ? _tvNextChannelFocusNode : null,
                          onPressed: widget.onNextChannel,
                          icon: const Icon(
                            Icons.chevron_right,
                            color: Colors.white,
                            size: 34,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              // Bottom control bar
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 300),
                  child: _buildFullscreenControlBar(isTv: isTv),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (!isTv) return scaffold;

    // On Android TV: wrap in a focusable widget so D-pad keys are delivered
    // here instead of to child widgets (Slider, buttons).
    return Focus(
      focusNode: _tvFocusNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final controlFocused = _hasFocusedFullscreenControl();
        if ((event.logicalKey == LogicalKeyboardKey.arrowDown ||
                event.logicalKey == LogicalKeyboardKey.arrowUp) &&
            !_tvControlsMode &&
            !controlFocused) {
          _showControls();
          _tvControlsMode = true;
          _focusPlayPauseControl();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
            (_tvControlsMode || controlFocused)) {
          _showControls();
          if (_isSideChannelFocusActive()) {
            _focusTimelineControl();
            return KeyEventResult.handled;
          }
          if (_isTimelineFocusActive()) {
            _focusPlayPauseControl();
            return KeyEventResult.handled;
          }
          if (!_isBottomControlFocusActive()) {
            _focusPlayPauseControl();
            return KeyEventResult.handled;
          }
          _focusPlayPauseControl();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
            (_tvControlsMode || controlFocused)) {
          _showControls();
          if (_isSideChannelFocusActive()) {
            _tvControlsMode = false;
            _tvFocusNode?.requestFocus();
            return KeyEventResult.handled;
          }
          if (_isTimelineFocusActive()) {
            final movedToSide = _focusPreferredSideChannelControl();
            if (!movedToSide) {
              _tvControlsMode = false;
              _tvFocusNode?.requestFocus();
            }
            return KeyEventResult.handled;
          }
          _focusTimelineControl();
          return KeyEventResult.handled;
        }
        if (_tvControlsMode || controlFocused) {
          _showControls();
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            if (_isSideChannelFocusActive()) {
              _moveSideChannelFocus(forward: false);
              return KeyEventResult.handled;
            }
            if (_isTimelineFocusActive()) {
              _seekBy(const Duration(seconds: -10));
              return KeyEventResult.handled;
            }
            _moveBottomControlFocus(forward: false);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            if (_isSideChannelFocusActive()) {
              _moveSideChannelFocus(forward: true);
              return KeyEventResult.handled;
            }
            if (_isTimelineFocusActive()) {
              _seekBy(const Duration(seconds: 10));
              return KeyEventResult.handled;
            }
            _moveBottomControlFocus(forward: true);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _seekBy(const Duration(seconds: -10));
          _showControls();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          _seekBy(const Duration(seconds: 10));
          _showControls();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter) {
          _togglePlayPause();
          _showControls();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
            event.logicalKey == LogicalKeyboardKey.arrowDown) {
          _showControls();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: scaffold,
    );
  }

  Widget _buildFullscreenControlBar({bool isTv = false}) {
    return StreamBuilder<Duration>(
      stream: widget.player.stream.position,
      initialData: widget.player.state.position,
      builder: (context, positionSnapshot) {
        final position = positionSnapshot.data ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: widget.player.stream.duration,
          initialData: widget.player.state.duration,
          builder: (context, durationSnapshot) {
            final duration = durationSnapshot.data ?? Duration.zero;
            final hasFiniteDuration = duration > Duration.zero;
            final maxMs = hasFiniteDuration
                ? duration.inMilliseconds.toDouble()
                : 1.0;
            final currentMs = hasFiniteDuration
                ? position.inMilliseconds
                      .clamp(0, duration.inMilliseconds)
                      .toDouble()
                : 0.0;

            return Material(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildTvFocusFrame(
                      focusNode: isTv ? _tvTimelineFocusNode : null,
                      child: Row(
                        children: [
                          Text(
                            _formatDuration(position),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Focus(
                              focusNode: isTv ? _tvTimelineFocusNode : null,
                              canRequestFocus: isTv,
                              skipTraversal: true,
                              descendantsAreFocusable: false,
                              child: ExcludeFocus(
                                excluding: isTv,
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 3,
                                    thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 6,
                                    ),
                                  ),
                                  child: Slider(
                                    value: currentMs,
                                    min: 0,
                                    max: maxMs,
                                    onChanged: !hasFiniteDuration
                                        ? null
                                        : (value) {
                                            widget.player.seek(
                                              Duration(
                                                milliseconds: value.round(),
                                              ),
                                            );
                                          },
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            hasFiniteDuration
                                ? _formatDuration(duration)
                                : 'LIVE',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _buildTvFocusFrame(
                                focusNode: isTv ? _tvBack10FocusNode : null,
                                child: IconButton(
                                  tooltip: 'Back 10s',
                                  focusNode: isTv ? _tvBack10FocusNode : null,
                                  icon: const Icon(
                                    Icons.replay_10,
                                    color: Colors.white,
                                  ),
                                  onPressed: () =>
                                      _seekBy(const Duration(seconds: -10)),
                                ),
                              ),
                              const SizedBox(width: 4),
                              StreamBuilder<bool>(
                                stream: widget.player.stream.playing,
                                initialData: widget.player.state.playing,
                                builder: (context, playingSnapshot) {
                                  final playing =
                                      playingSnapshot.data ??
                                      widget.player.state.playing;
                                  return _buildTvFocusFrame(
                                    focusNode: isTv
                                        ? _tvPlayPauseFocusNode
                                        : null,
                                    child: IconButton(
                                      tooltip: playing ? 'Pause' : 'Play',
                                      focusNode: isTv
                                          ? _tvPlayPauseFocusNode
                                          : null,
                                      icon: Icon(
                                        playing
                                            ? Icons.pause_circle_filled
                                            : Icons.play_circle_fill,
                                        color: Colors.white,
                                        size: 34,
                                      ),
                                      onPressed: _togglePlayPause,
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(width: 4),
                              _buildTvFocusFrame(
                                focusNode: isTv ? _tvForward10FocusNode : null,
                                child: IconButton(
                                  tooltip: 'Forward 10s',
                                  focusNode: isTv
                                      ? _tvForward10FocusNode
                                      : null,
                                  icon: const Icon(
                                    Icons.forward_10,
                                    color: Colors.white,
                                  ),
                                  onPressed: () =>
                                      _seekBy(const Duration(seconds: 10)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              StreamBuilder<double>(
                                stream: widget.player.stream.volume,
                                initialData: widget.player.state.volume,
                                builder: (context, volumeSnapshot) {
                                  final volume =
                                      volumeSnapshot.data ??
                                      widget.player.state.volume;
                                  final muted = volume <= 0.0;
                                  return _buildTvFocusFrame(
                                    focusNode: isTv ? _tvMuteFocusNode : null,
                                    child: IconButton(
                                      tooltip: muted ? 'Unmute' : 'Mute',
                                      focusNode: isTv ? _tvMuteFocusNode : null,
                                      icon: Icon(
                                        muted
                                            ? Icons.volume_off
                                            : Icons.volume_up,
                                        color: Colors.white,
                                      ),
                                      onPressed: _toggleMute,
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                        _buildTvFocusFrame(
                          focusNode: isTv ? _tvExitFullscreenFocusNode : null,
                          child: IconButton(
                            tooltip: 'Exit Fullscreen',
                            focusNode: isTv ? _tvExitFullscreenFocusNode : null,
                            icon: const Icon(
                              Icons.fullscreen_exit,
                              color: Colors.white,
                            ),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
