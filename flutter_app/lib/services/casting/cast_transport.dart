enum CastRouteKind { googleCast, airPlay }

enum CastPlaybackState {
  disconnected,
  connecting,
  connected,
  loading,
  playing,
  paused,
  reconnecting,
  failed,
}

class CastDevice {
  const CastDevice({required this.id, required this.name, required this.kind});
  final String id;
  final String name;
  final CastRouteKind kind;
}

class CastMedia {
  const CastMedia({
    required this.id,
    required this.url,
    required this.title,
    required this.contentType,
    this.imageUrl,
    this.isLive = true,
    this.position = Duration.zero,
  });
  final String id;
  final String url;
  final String title;
  final String contentType;
  final String? imageUrl;
  final bool isLive;
  final Duration position;
}

class CastStatus {
  const CastStatus({
    required this.state,
    this.device,
    this.mediaId,
    this.position = Duration.zero,
    this.canSeek = false,
    this.error,
    this.phoneOutputConfirmed = false,
    this.selectionCancelled = false,
  });
  final CastPlaybackState state;
  final CastDevice? device;
  final String? mediaId;
  final Duration position;
  final bool canSeek;
  final String? error;
  final bool phoneOutputConfirmed;
  final bool selectionCancelled;
}

/// Public system picker is required to change an AirPlay audio output.
abstract interface class PhoneOutputConfirmation {
  Future<bool> preparePhoneOutput();
}

abstract class CastTransport {
  CastRouteKind get kind;
  Stream<List<CastDevice>> get devices;
  Stream<CastStatus> get statuses;
  Future<void> initialize();
  Future<void> startDiscovery();
  Future<void> stopDiscovery();
  Future<void> connect(CastDevice device);
  Future<void> load(CastMedia media);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> stop();
  Future<void> disconnect();
  Future<void> dispose();
}
