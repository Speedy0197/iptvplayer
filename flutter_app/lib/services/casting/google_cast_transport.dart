import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart' as cast;

import 'cast_transport.dart';

const String _mediaIdCustomDataKey = 'streamPilotMediaId';

/// Converts StreamPilot values at the Google Cast SDK boundary.
///
/// This stays free of SDK types so its wire-level behavior can be tested on
/// hosts that cannot load the native Cast frameworks.
@visibleForTesting
class GoogleCastMessageCodec {
  const GoogleCastMessageCodec();

  Map<String, Object?> encodeLoadRequest(CastMedia media) {
    final customData = <String, Object?>{_mediaIdCustomDataKey: media.id};
    return <String, Object?>{
      'contentId': media.id,
      'contentUrl': media.url,
      'contentType': media.contentType,
      'streamType': media.isLive ? 'live' : 'buffered',
      'title': media.title,
      'imageUrl': media.imageUrl,
      'positionMilliseconds': media.position.inMilliseconds,
      'mediaCustomData': customData,
      'requestCustomData': Map<String, Object?>.of(customData),
    };
  }

  CastStatus decodeRemoteStatus(
    Map<String, Object?> remote, {
    CastDevice? device,
  }) {
    final playerState = remote['playerState']?.toString().toLowerCase();
    final idleReason = remote['idleReason']?.toString().toLowerCase();
    final state = switch (playerState) {
      'playing' => CastPlaybackState.playing,
      'paused' => CastPlaybackState.paused,
      'loading' || 'buffering' => CastPlaybackState.loading,
      'idle' when idleReason == 'error' => CastPlaybackState.failed,
      _ => CastPlaybackState.connected,
    };
    final customData = remote['mediaCustomData'];
    final mediaId = customData is Map
        ? customData[_mediaIdCustomDataKey]?.toString()
        : null;
    final positionMilliseconds =
        (remote['positionMilliseconds'] as num?)?.round() ?? 0;

    return CastStatus(
      state: state,
      device: device,
      mediaId: mediaId,
      position: Duration(milliseconds: positionMilliseconds),
      canSeek: remote['streamType']?.toString().toLowerCase() == 'buffered',
      error: state == CastPlaybackState.failed
          ? 'The Cast receiver could not play this stream.'
          : null,
    );
  }
}

class GoogleCastTransport implements CastTransport {
  GoogleCastTransport()
    : _supportedPlatformOverride = null,
      operationTimeout = const Duration(seconds: 10);

  @visibleForTesting
  GoogleCastTransport.forTesting({
    required bool supportedPlatform,
    this.operationTimeout = const Duration(seconds: 10),
  }) : _supportedPlatformOverride = supportedPlatform;

  static const _codec = GoogleCastMessageCodec();
  static const _platformChannel = MethodChannel('streampilot/platform');
  static const _iosRemoteMediaChannel = MethodChannel(
    'google_cast.remote_media_client',
  );
  final Duration operationTimeout;

  final bool? _supportedPlatformOverride;
  final _devicesController = StreamController<List<CastDevice>>.broadcast();
  final _statusesController = StreamController<CastStatus>.broadcast();
  final Map<String, cast.GoogleCastDevice> _nativeDevices = {};
  final List<StreamSubscription<Object?>> _subscriptions = [];

  cast.GoogleCastDiscoveryManagerPlatformInterface? _discoveryManager;
  cast.GoogleCastSessionManagerPlatformInterface? _sessionManager;
  cast.GoogleCastRemoteMediaClientPlatformInterface? _remoteMediaClient;
  CastStatus _status = const CastStatus(state: CastPlaybackState.disconnected);
  CastDevice? _selectedDevice;
  String? _lastMediaId;
  bool _lastCanSeek = false;
  bool _initialized = false;
  bool _discovering = false;
  bool _wasConnected = false;
  bool _disposed = false;
  Completer<void>? _connectionCompleter;
  Timer? _connectionTimer;
  String? _connectingDeviceId;
  bool _acceptSessions = false;
  final Set<String> _cancelledDeviceIds = {};
  Completer<void>? _disconnectionCompleter;
  Timer? _reconnectTimer;

  @override
  CastRouteKind get kind => CastRouteKind.googleCast;

  @override
  Stream<List<CastDevice>> get devices => _devicesController.stream;

  @override
  Stream<CastStatus> get statuses => _statusesController.stream;

  @override
  Future<void> initialize() async {
    _ensureNotDisposed();
    if (_initialized || !await _isSupportedMobileSender()) {
      return;
    }

    try {
      final initialized = await cast.GoogleCastContext.instance
          .setSharedInstanceWithOptions(_castOptions())
          .timeout(operationTimeout);
      _ensureNotDisposed();
      if (!initialized) {
        throw StateError('The native Google Cast SDK did not initialize.');
      }

      _discoveryManager = cast.GoogleCastDiscoveryManager.instance;
      _sessionManager = cast.GoogleCastSessionManager.instance;
      _remoteMediaClient = cast.GoogleCastRemoteMediaClient.instance;
      _initialized = true;
      _listenToNativeState();
      _emitStatus(_status);
    } catch (_) {
      _emitFailure('Google Cast could not be initialized.');
      rethrow;
    }
  }

  @override
  Future<void> startDiscovery() async {
    final discovery = _requireInitialized(_discoveryManager);
    try {
      await discovery.startDiscovery().timeout(operationTimeout);
      if (_disposed) {
        await discovery.stopDiscovery().timeout(operationTimeout);
        return;
      }
      _discovering = true;
    } catch (_) {
      _emitFailure('Google Cast device discovery could not start.');
      rethrow;
    }
  }

  @override
  Future<void> stopDiscovery() async {
    final discovery = _requireInitialized(_discoveryManager);
    try {
      await discovery.stopDiscovery().timeout(operationTimeout);
      _discovering = false;
    } catch (_) {
      _emitFailure('Google Cast device discovery could not stop.');
      rethrow;
    }
  }

  @override
  Future<void> connect(CastDevice device) async {
    if (device.kind != CastRouteKind.googleCast) {
      throw ArgumentError.value(device.kind, 'device.kind');
    }
    final sessions = _requireInitialized(_sessionManager);
    final nativeDevice = _nativeDevices[device.id];
    if (nativeDevice == null) {
      throw StateError('The selected Cast device is no longer available.');
    }
    if (_connectionCompleter != null) {
      throw StateError('A Google Cast connection is already in progress.');
    }

    _selectedDevice = device;
    _acceptSessions = true;
    _cancelledDeviceIds.remove(device.id);
    _emitStatus(
      CastStatus(state: CastPlaybackState.connecting, device: device),
    );
    final connection = Completer<void>();
    _connectionCompleter = connection;
    _connectingDeviceId = device.id;
    _connectionTimer = Timer(operationTimeout, () {
      if (!connection.isCompleted) {
        connection.completeError(
          TimeoutException(
            'The Google Cast session did not connect in time.',
            operationTimeout,
          ),
        );
      }
    });
    try {
      await Future.wait<void>([
        sessions
            .startSessionWithDevice(nativeDevice)
            .timeout(operationTimeout)
            .then((started) {
              if (!started) {
                throw StateError(
                  'The native Cast session request was rejected.',
                );
              }
            }),
        connection.future,
      ], eagerError: true);
    } catch (_) {
      _acceptSessions = false;
      _cancelledDeviceIds.add(device.id);
      _wasConnected = false;
      try {
        await sessions.endSessionAndStopCasting().timeout(
          const Duration(seconds: 2),
        );
      } catch (_) {}
      _emitFailure('StreamPilot could not connect to the Cast device.');
      rethrow;
    } finally {
      if (identical(_connectionCompleter, connection)) {
        _connectionTimer?.cancel();
        _connectionTimer = null;
        _connectionCompleter = null;
        _connectingDeviceId = null;
      }
    }
  }

  @override
  Future<void> load(CastMedia media) async {
    final remote = _requireInitialized(_remoteMediaClient);
    final request = _codec.encodeLoadRequest(media);
    final imageUrl = request['imageUrl'] as String?;
    final metadata = cast.GoogleCastGenericMediaMetadata(
      title: request['title'] as String,
      images: imageUrl == null || imageUrl.isEmpty
          ? null
          : <cast.GoogleCastImage>[
              cast.GoogleCastImage(url: Uri.parse(imageUrl)),
            ],
    );
    final mediaInfo = cast.GoogleCastMediaInformation(
      contentId: request['contentId'] as String,
      contentUrl: Uri.parse(request['contentUrl'] as String),
      contentType: request['contentType'] as String,
      streamType: media.isLive
          ? cast.CastMediaStreamType.live
          : cast.CastMediaStreamType.buffered,
      metadata: metadata,
      customData: Map<String, dynamic>.from(request['mediaCustomData']! as Map),
    );

    _lastMediaId = media.id;
    _lastCanSeek = !media.isLive;
    _emitStatus(
      CastStatus(
        state: CastPlaybackState.loading,
        device: _selectedDevice,
        mediaId: media.id,
        position: media.position,
        canSeek: !media.isLive,
      ),
    );
    try {
      final requestCustomData = Map<String, dynamic>.from(
        request['requestCustomData']! as Map,
      );
      if (_usesIosMethodChannel) {
        await _invokeIosRemoteRequest(
          'loadMedia',
          mediaInfo.toMap()..addAll(<String, dynamic>{
            'autoPlay': true,
            'playPosition': media.position.inSeconds,
            'playbackRate': 1.0,
            'customData': requestCustomData,
          }),
        );
      } else {
        await remote
            .loadMedia(
              mediaInfo,
              autoPlay: true,
              playPosition: media.position,
              customData: requestCustomData,
            )
            .timeout(operationTimeout);
      }
      // A successful return acknowledges the SDK request. Media status is the
      // sole source of playing/paused confirmation.
    } catch (_) {
      _emitFailure(
        'The Cast receiver rejected the media request.',
        mediaId: media.id,
      );
      rethrow;
    }
  }

  @override
  Future<void> play() => _runRemoteControl(
    'The Cast receiver could not resume playback.',
    (remote) => remote.play(),
    iosMethod: 'play',
  );

  @override
  Future<void> pause() => _runRemoteControl(
    'The Cast receiver could not pause playback.',
    (remote) => remote.pause(),
    iosMethod: 'pause',
  );

  @override
  Future<void> seek(Duration position) => _runRemoteControl(
    'The Cast receiver could not seek.',
    (remote) => remote.seek(cast.GoogleCastMediaSeekOption(position: position)),
    iosMethod: 'seek',
    iosArguments: cast.GoogleCastMediaSeekOption(position: position).toMap(),
  );

  @override
  Future<void> stop() => _runRemoteControl(
    'The Cast receiver could not stop playback.',
    (remote) => remote.stop(),
    iosMethod: 'stop',
  );

  @override
  Future<void> disconnect() async {
    final sessions = _requireInitialized(_sessionManager);
    _acceptSessions = false;
    if (_selectedDevice != null) _cancelledDeviceIds.add(_selectedDevice!.id);
    _reconnectTimer?.cancel();
    if (!_wasConnected &&
        _connectionCompleter == null &&
        _selectedDevice == null) {
      return;
    }
    final endedEvent = _disconnectionCompleter ??= Completer<void>();
    final confirmed = endedEvent.future.timeout(operationTimeout);
    try {
      await Future.wait<void>([
        sessions.endSessionAndStopCasting().timeout(operationTimeout).then((
          ended,
        ) {
          if (!ended) {
            throw StateError(
              'The native Cast disconnect request was rejected.',
            );
          }
        }),
        confirmed,
      ], eagerError: true);
    } catch (_) {
      // Rejection is not an ended event. Keep observing the receiver whose
      // playback may still be running so the coordinator can control/retry it.
      if (_wasConnected && !_disposed) {
        _acceptSessions = true;
        _cancelledDeviceIds.remove(_selectedDevice?.id);
      }
      _emitFailure('StreamPilot could not disconnect from the Cast device.');
      rethrow;
    } finally {
      if (identical(_disconnectionCompleter, endedEvent)) {
        _disconnectionCompleter = null;
      }
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _acceptSessions = false;
    _reconnectTimer?.cancel();
    final connection = _connectionCompleter;
    if (connection != null && !connection.isCompleted) {
      connection.completeError(
        StateError('GoogleCastTransport was disposed while connecting.'),
      );
    }
    _connectionTimer?.cancel();
    if (_discovering) {
      try {
        await _discoveryManager?.stopDiscovery().timeout(operationTimeout);
      } catch (_) {
        // Disposal must still release local stream listeners.
      }
    }
    for (final subscription in _subscriptions) {
      try {
        await subscription.cancel().timeout(operationTimeout);
      } catch (_) {}
    }
    _subscriptions.clear();
    try {
      await _devicesController.close().timeout(operationTimeout);
    } catch (_) {}
    try {
      await _statusesController.close().timeout(operationTimeout);
    } catch (_) {}
  }

  cast.GoogleCastOptions _castOptions() {
    const appId = cast.GoogleCastDiscoveryCriteria.kDefaultApplicationId;
    if (Platform.isAndroid) {
      return _AndroidCastOptions(appId: appId);
    }
    return cast.IOSGoogleCastOptions(
      cast.GoogleCastDiscoveryCriteriaInitialize.initWithApplicationID(appId),
      disableDiscoveryAutostart: true,
      startDiscoveryAfterFirstTapOnCastButton: false,
      stopCastingOnAppTerminated: false,
    );
  }

  Future<bool> _isSupportedMobileSender() async {
    final supportedPlatformOverride = _supportedPlatformOverride;
    if (supportedPlatformOverride != null) {
      return supportedPlatformOverride;
    }
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
      return false;
    }
    if (!Platform.isAndroid) {
      return true;
    }
    return !(await _platformChannel.invokeMethod<bool>('isAndroidTv') ?? true);
  }

  void _listenToNativeState() {
    final discovery = _discoveryManager!;
    final sessions = _sessionManager!;
    final remote = _remoteMediaClient!;

    _subscriptions.add(
      discovery.devicesStream.listen(
        _onDevicesChanged,
        onError: (_) => _emitFailure('Google Cast device discovery failed.'),
      ),
    );
    _subscriptions.add(
      sessions.currentSessionStream.listen(
        _onSessionChanged,
        onError: (Object error) {
          final connection = _connectionCompleter;
          if (connection != null && !connection.isCompleted) {
            connection.completeError(error);
          }
          _emitFailure('The Google Cast session was interrupted.');
        },
      ),
    );
    _subscriptions.add(
      remote.mediaStatusStream.listen(
        _onMediaStatusChanged,
        onError: (_) => _emitFailure(
          'The Cast receiver stopped reporting playback status.',
        ),
      ),
    );
    _subscriptions.add(
      remote.playerPositionStream.listen(
        _onPositionChanged,
        onError: (_) => _emitFailure(
          'The Cast receiver stopped reporting playback position.',
        ),
      ),
    );
  }

  void _onDevicesChanged(List<cast.GoogleCastDevice> nativeDevices) {
    _nativeDevices
      ..clear()
      ..addEntries(
        nativeDevices.map((device) => MapEntry(device.deviceID, device)),
      );
    _devicesController.add(
      nativeDevices
          .map(
            (device) => CastDevice(
              id: device.deviceID,
              name: device.friendlyName,
              kind: CastRouteKind.googleCast,
            ),
          )
          .toList(growable: false),
    );
  }

  void _onSessionChanged(cast.GoogleCastSession? session) {
    if (_disposed) return;
    if (session == null ||
        session.connectionState == cast.GoogleCastConnectState.disconnected) {
      if (session?.device != null &&
          _selectedDevice != null &&
          session!.device!.deviceID != _selectedDevice!.id) {
        return;
      }
      if (_disconnectionCompleter?.isCompleted == false) {
        _disconnectionCompleter!.complete();
      }
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      final connection = _connectionCompleter;
      if (connection != null && !connection.isCompleted) {
        connection.completeError(
          StateError('The Google Cast session ended before it connected.'),
        );
      }
      _wasConnected = false;
      _selectedDevice = null;
      _lastMediaId = null;
      _lastCanSeek = false;
      _emitStatus(const CastStatus(state: CastPlaybackState.disconnected));
      return;
    }

    if (session.connectionState == cast.GoogleCastConnectState.disconnecting) {
      return;
    }
    if (!_acceptSessions ||
        (session.device != null &&
            session.device!.deviceID != _selectedDevice?.id)) {
      if (session.connectionState == cast.GoogleCastConnectState.connected &&
          !_acceptSessions &&
          _cancelledDeviceIds.contains(session.device?.deviceID)) {
        unawaited(
          _sessionManager!
              .endSessionAndStopCasting()
              .timeout(operationTimeout)
              .then<void>((_) {}, onError: (_) {}),
        );
      }
      return;
    }

    final nativeDevice = session.device;
    final device = nativeDevice == null
        ? _selectedDevice
        : CastDevice(
            id: nativeDevice.deviceID,
            name: nativeDevice.friendlyName,
            kind: CastRouteKind.googleCast,
          );
    _selectedDevice = device;
    final state = switch (session.connectionState) {
      cast.GoogleCastConnectState.connecting =>
        _wasConnected
            ? CastPlaybackState.reconnecting
            : CastPlaybackState.connecting,
      cast.GoogleCastConnectState.connected => CastPlaybackState.connected,
      cast.GoogleCastConnectState.disconnecting ||
      cast.GoogleCastConnectState.disconnected =>
        CastPlaybackState.disconnected,
    };
    if (session.connectionState == cast.GoogleCastConnectState.connected) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _wasConnected = true;
      final connection = _connectionCompleter;
      if (connection != null &&
          !connection.isCompleted &&
          device?.id == _connectingDeviceId) {
        connection.complete();
      }
    } else if (session.connectionState ==
            cast.GoogleCastConnectState.disconnected ||
        session.connectionState == cast.GoogleCastConnectState.disconnecting) {
      final connection = _connectionCompleter;
      if (connection != null && !connection.isCompleted) {
        connection.completeError(
          StateError('The Google Cast session failed to connect.'),
        );
      }
    }
    if (state == CastPlaybackState.reconnecting && _reconnectTimer == null) {
      _reconnectTimer = Timer(operationTimeout, () {
        _reconnectTimer = null;
        _emitFailure('The Google Cast connection could not be restored.');
      });
    }
    _emitStatus(
      CastStatus(
        state: state,
        device: device,
        mediaId: _lastMediaId,
        position: _status.position,
        canSeek: _lastCanSeek,
      ),
    );
  }

  void _onMediaStatusChanged(cast.GoggleCastMediaStatus? remoteStatus) {
    if (remoteStatus == null || !_acceptSessions || _disposed) return;
    final media = remoteStatus.mediaInformation;
    final status = _codec.decodeRemoteStatus(<String, Object?>{
      'playerState': remoteStatus.playerState.name,
      'idleReason': remoteStatus.idleReason?.name,
      'positionMilliseconds': _remoteMediaClient!.playerPosition.inMilliseconds,
      'streamType':
          media?.streamType.name ?? (_lastCanSeek ? 'buffered' : 'live'),
      'mediaCustomData': media?.customData,
    }, device: _selectedDevice);
    final mediaId =
        status.mediaId ??
        (media?.contentId.isNotEmpty == true ? media!.contentId : null);
    _lastMediaId = mediaId;
    _lastCanSeek = status.canSeek;
    _emitStatus(
      CastStatus(
        state: status.state,
        device: status.device,
        mediaId: mediaId,
        position: status.position,
        canSeek: status.canSeek,
        error: status.error,
      ),
    );
  }

  void _onPositionChanged(Duration position) {
    if (_status.state != CastPlaybackState.playing &&
        _status.state != CastPlaybackState.paused &&
        _status.state != CastPlaybackState.loading) {
      return;
    }
    _emitStatus(
      CastStatus(
        state: _status.state,
        device: _status.device,
        mediaId: _status.mediaId,
        position: position,
        canSeek: _status.canSeek,
        error: _status.error,
      ),
    );
  }

  Future<void> _runRemoteControl(
    String failureMessage,
    Future<void> Function(cast.GoogleCastRemoteMediaClientPlatformInterface)
    operation, {
    required String iosMethod,
    Object? iosArguments,
  }) async {
    final remote = _requireInitialized(_remoteMediaClient);
    try {
      if (_usesIosMethodChannel) {
        await _invokeIosRemoteRequest(iosMethod, iosArguments);
      } else {
        await operation(remote).timeout(operationTimeout);
      }
    } catch (_) {
      _emitFailure(failureMessage, mediaId: _lastMediaId);
      rethrow;
    }
  }

  bool get _usesIosMethodChannel =>
      Platform.isIOS ||
      (_supportedPlatformOverride == true && !Platform.isAndroid);

  Future<void> _invokeIosRemoteRequest(
    String method, [
    Object? arguments,
  ]) async {
    final response = await _iosRemoteMediaChannel
        .invokeMethod<Object?>(method, arguments)
        .timeout(operationTimeout);
    if (response == null) {
      throw StateError('The native Google Cast request was not created.');
    }
    if (response case final Map<Object?, Object?> responseMap
        when responseMap['error'] != null) {
      throw PlatformException(
        code: 'CAST_REQUEST_ERROR',
        message: 'The native Google Cast request failed.',
      );
    }
  }

  T _requireInitialized<T>(T? dependency) {
    _ensureNotDisposed();
    if (!_initialized || dependency == null) {
      throw StateError('Google Cast is not initialized on this device.');
    }
    return dependency;
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('GoogleCastTransport has been disposed.');
    }
  }

  void _emitFailure(String message, {String? mediaId}) {
    _emitStatus(
      CastStatus(
        state: CastPlaybackState.failed,
        device: _selectedDevice,
        mediaId: mediaId ?? _lastMediaId,
        position: _status.position,
        canSeek: _lastCanSeek,
        error: message,
      ),
    );
  }

  void _emitStatus(CastStatus status) {
    _status = status;
    if (!_statusesController.isClosed) {
      _statusesController.add(status);
    }
  }
}

class _AndroidCastOptions extends cast.GoogleCastOptions {
  _AndroidCastOptions({required this.appId})
    : super(
        disableDiscoveryAutostart: true,
        startDiscoveryAfterFirstTapOnCastButton: false,
        stopCastingOnAppTerminated: false,
      );

  final String appId;

  @override
  Map<String, dynamic> toMap() => super.toMap()..['appId'] = appId;
}
