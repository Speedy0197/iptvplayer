import 'dart:async';

import 'package:media_kit/media_kit.dart';

import '../playlist_store.dart';
import 'cast_media_resolver.dart';
import 'cast_transport.dart';
import 'casting_controller.dart';

/// Keeps playback ownership separate from navigation and EPG notifications.
class PlaylistCastingBinding extends LocalCastingPlayback {
  PlaylistCastingBinding(this.store, {CastMediaResolver? resolver})
    : _resolver = resolver ?? CastMediaResolver();

  final PlaylistStore store;
  final CastMediaResolver _resolver;
  CastingController? _controller;
  bool _disposed = false;
  int _generation = 0;
  Completer<void> _cancellation = Completer<void>();

  @override
  void cancelPendingOperations() {
    _generation++;
    if (!_cancellation.isCompleted) _cancellation.complete();
    _cancellation = Completer<void>();
  }

  void attach(CastingController controller) {
    _controller = controller;
    store.addListener(_channelChanged);
  }

  void _channelChanged() => _controller?.synchronizeChannel();

  @override
  String? get mediaId {
    final channel = store.nowPlaying;
    return channel == null
        ? null
        : '${channel.playlistId}:${channel.id}:${channel.streamId}';
  }

  @override
  bool get isPlaying => store.hasPlayer && store.player.state.playing;
  @override
  bool get isSeekable =>
      store.nowPlaying?.groupName.toLowerCase() == 'aufnahmen';
  @override
  Duration get position =>
      store.hasPlayer ? store.player.state.position : Duration.zero;

  @override
  Future<CastMedia?> resolveMedia() async {
    final channel = store.nowPlaying;
    final id = mediaId;
    cancelPendingOperations();
    final generation = _generation;
    final cancellation = _cancellation.future;
    if (_disposed || channel == null || id == null) return null;
    bool isCurrent() =>
        !_disposed && generation == _generation && mediaId == id;
    final url = await store.resolveChannelStreamUrl(channel);
    if (!isCurrent()) return null;
    return _resolver.resolve(
      id: id,
      url: url,
      title: channel.name,
      imageUrl: channel.logoUrl.isEmpty ? null : channel.logoUrl,
      isLive: !isSeekable,
      position: position,
      isCurrent: isCurrent,
      cancelled: cancellation,
    );
  }

  @override
  void setRemotePlayback(bool value) {
    if (!_disposed) store.setLocalPlaybackSuppressed(value);
  }

  @override
  Future<void> pause() async {
    if (store.hasPlayer) await store.player.pause();
  }

  @override
  Future<void> restore({required bool play, required Duration position}) async {
    final channel = store.nowPlaying;
    cancelPendingOperations();
    final generation = _generation;
    if (_disposed || channel == null) return;
    bool current() =>
        !_disposed &&
        generation == _generation &&
        identical(store.nowPlaying, channel);
    final url = await store.resolveChannelStreamUrl(channel);
    if (!current()) return;
    final player = store.ensurePlayer();
    await player.open(
      Media(
        url,
        httpHeaders: const {
          'User-Agent': 'IPTVPlayer/1.0 media_kit',
          'Connection': 'keep-alive',
        },
      ),
      play: false,
    );
    if (!current()) return;
    if (isSeekable && position > Duration.zero) await player.seek(position);
    if (!current()) return;
    // A recreated ChannelPlayer must retain a deliberately paused recording.
    store.restoredPlaybackStreamUrl = channel.streamUrl;
    if (play) await player.play();
  }

  void dispose() {
    _disposed = true;
    cancelPendingOperations();
    store.removeListener(_channelChanged);
    _controller = null;
    store.setLocalPlaybackSuppressed(false, notify: false);
  }
}
