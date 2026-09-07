import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cast_transport.dart';

class AirPlayTransport implements CastTransport, PhoneOutputConfirmation {
  AirPlayTransport()
    : _methodChannel = const MethodChannel('streampilot/airplay'),
      _eventChannel = const EventChannel('streampilot/airplay/events'),
      _supportedPlatformOverride = null;

  @visibleForTesting
  AirPlayTransport.forTesting({
    required bool supportedPlatform,
    MethodChannel methodChannel = const MethodChannel('streampilot/airplay'),
    EventChannel eventChannel = const EventChannel(
      'streampilot/airplay/events',
    ),
  }) : _methodChannel = methodChannel,
       _eventChannel = eventChannel,
       _supportedPlatformOverride = supportedPlatform;

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final bool? _supportedPlatformOverride;
  final _devicesController = StreamController<List<CastDevice>>.broadcast();
  final _statusesController = StreamController<CastStatus>.broadcast();

  StreamSubscription<Object?>? _eventsSubscription;
  CastDevice? _selectedDevice;
  CastStatus _status = const CastStatus(state: CastPlaybackState.disconnected);
  String? _mediaId;
  bool _canSeek = false;
  bool _initialized = false;
  bool _supported = false;
  bool _disposed = false;

  @override
  CastRouteKind get kind => CastRouteKind.airPlay;

  @override
  Stream<List<CastDevice>> get devices => _devicesController.stream;

  @override
  Stream<CastStatus> get statuses => _statusesController.stream;

  @override
  Future<void> initialize() async {
    _ensureNotDisposed();
    if (_initialized) return;
    _supported = _supportedPlatformOverride ?? (!kIsWeb && Platform.isIOS);
    _initialized = true;
    if (!_supported) return;

    _eventsSubscription = _eventChannel.receiveBroadcastStream().listen(
      _onNativeEvent,
      onError: (_) => _emitFailure('The AirPlay connection was interrupted.'),
    );
    try {
      await _invoke('initialize');
    } catch (_) {
      await _eventsSubscription?.cancel();
      _eventsSubscription = null;
      _initialized = false;
      _emitFailure('AirPlay could not be initialized.');
      rethrow;
    }
  }

  @override
  Future<void> startDiscovery() async {
    if (!_requireSupported()) return;
    await _invokeWithFailure(
      'startDiscovery',
      'AirPlay route discovery could not start.',
    );
  }

  @override
  Future<void> stopDiscovery() async {
    if (!_requireSupported()) return;
    await _invokeWithFailure(
      'stopDiscovery',
      'AirPlay route discovery could not stop.',
    );
  }

  @override
  Future<void> connect(CastDevice device) async {
    if (device.kind != CastRouteKind.airPlay) {
      throw ArgumentError.value(device.kind, 'device.kind');
    }
    if (!_requireSupported()) return;
    _selectedDevice = device;
    _emitStatus(
      CastStatus(state: CastPlaybackState.connecting, device: device),
    );
    try {
      await _invoke('connect', <String, Object?>{'deviceId': device.id});
      _emitStatus(
        CastStatus(state: CastPlaybackState.connected, device: device),
      );
    } catch (_) {
      _emitFailure('StreamPilot could not connect to the AirPlay device.');
      rethrow;
    }
  }

  @override
  Future<void> load(CastMedia media) async {
    if (!_requireSupported()) return;
    _mediaId = media.id;
    _canSeek = !media.isLive;
    _emitStatus(
      CastStatus(
        state: CastPlaybackState.loading,
        device: _selectedDevice,
        mediaId: media.id,
        position: media.position,
        canSeek: _canSeek,
      ),
    );
    try {
      await _invoke('load', <String, Object?>{
        'id': media.id,
        'url': media.url,
        'title': media.title,
        'contentType': media.contentType,
        'imageUrl': media.imageUrl,
        'isLive': media.isLive,
        'positionMilliseconds': media.position.inMilliseconds,
      });
      // Native request completion only acknowledges the load request. The
      // event channel confirms external playback asynchronously.
    } catch (_) {
      _emitFailure('AirPlay could not load this stream.');
      rethrow;
    }
  }

  @override
  Future<void> play() =>
      _control('play', failureMessage: 'AirPlay could not resume playback.');

  @override
  Future<void> pause() =>
      _control('pause', failureMessage: 'AirPlay could not pause playback.');

  @override
  Future<void> seek(Duration position) => _control(
    'seek',
    arguments: <String, Object?>{
      'positionMilliseconds': position.inMilliseconds,
    },
    failureMessage: 'AirPlay could not seek.',
  );

  @override
  Future<void> stop() =>
      _control('stop', failureMessage: 'AirPlay could not stop playback.');

  @override
  Future<void> disconnect() async {
    if (!_requireSupported()) return;
    try {
      await _invoke('disconnect');
      _clearRoute();
    } catch (_) {
      _emitFailure('StreamPilot could not disconnect from AirPlay.');
      rethrow;
    }
  }

  @override
  Future<bool> preparePhoneOutput() async {
    if (!_requireSupported()) return false;
    return await _methodChannel
            .invokeMethod<bool>('preparePhoneOutput')
            .timeout(const Duration(seconds: 10)) ==
        true;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_initialized && _supported) {
      try {
        await _methodChannel
            .invokeMethod<Object?>('dispose')
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        // Local resources must still be released if the engine is shutting down.
      }
    }
    await _eventsSubscription?.cancel();
    _eventsSubscription = null;
    await _devicesController.close();
    await _statusesController.close();
  }

  Future<void> _control(
    String method, {
    Object? arguments,
    required String failureMessage,
  }) async {
    if (!_requireSupported()) return;
    await _invokeWithFailure(method, failureMessage, arguments);
  }

  Future<void> _invokeWithFailure(
    String method,
    String failureMessage, [
    Object? arguments,
  ]) async {
    try {
      await _invoke(method, arguments);
    } catch (_) {
      _emitFailure(failureMessage);
      rethrow;
    }
  }

  Future<void> _invoke(String method, [Object? arguments]) async {
    final accepted = await _methodChannel
        .invokeMethod<bool>(method, arguments)
        .timeout(const Duration(seconds: 10));
    if (accepted != true) {
      throw PlatformException(
        code: 'AIRPLAY_REQUEST_REJECTED',
        message: 'The native AirPlay request was rejected.',
      );
    }
  }

  void _onNativeEvent(Object? rawEvent) {
    if (_disposed || rawEvent is! Map) return;
    final event = Map<Object?, Object?>.from(rawEvent);
    switch (event['event']) {
      case 'route':
        _onRouteEvent(event);
      case 'playback':
        _onPlaybackEvent(event);
      case 'position':
        _onPositionEvent(event);
      case 'error':
        _emitFailure('AirPlay could not play this stream.');
      case 'selectionCancelled':
        _emitStatus(
          CastStatus(
            state: _status.state,
            device: _selectedDevice,
            mediaId: _mediaId,
            selectionCancelled: true,
          ),
        );
    }
  }

  void _onRouteEvent(Map<Object?, Object?> event) {
    if (event['connected'] != true) {
      _clearRoute(phoneOutputConfirmed: event['phoneOutputConfirmed'] == true);
      return;
    }
    final id = event['deviceId']?.toString();
    final name = event['deviceName']?.toString();
    if (id == null || id.isEmpty || name == null || name.isEmpty) return;
    final device = CastDevice(id: id, name: name, kind: CastRouteKind.airPlay);
    _selectedDevice = device;
    if (!_devicesController.isClosed) {
      _devicesController.add(<CastDevice>[device]);
    }
    _emitStatus(
      CastStatus(
        state: CastPlaybackState.connected,
        device: device,
        mediaId: _mediaId,
        position: _status.position,
        canSeek: _canSeek,
      ),
    );
  }

  void _onPlaybackEvent(Map<Object?, Object?> event) {
    final state = switch (event['state']?.toString()) {
      'loading' => CastPlaybackState.loading,
      'playing' => CastPlaybackState.playing,
      'paused' => CastPlaybackState.paused,
      _ => null,
    };
    if (state == null) return;
    _mediaId = event['mediaId']?.toString() ?? _mediaId;
    _canSeek = event['canSeek'] as bool? ?? _canSeek;
    _emitStatus(
      CastStatus(
        state: state,
        device: _selectedDevice,
        mediaId: _mediaId,
        position: _duration(event['positionMilliseconds']),
        canSeek: _canSeek,
      ),
    );
  }

  void _onPositionEvent(Map<Object?, Object?> event) {
    if (_status.state != CastPlaybackState.loading &&
        _status.state != CastPlaybackState.playing &&
        _status.state != CastPlaybackState.paused) {
      return;
    }
    _emitStatus(
      CastStatus(
        state: _status.state,
        device: _selectedDevice,
        mediaId: _mediaId,
        position: _duration(event['positionMilliseconds']),
        canSeek: _canSeek,
      ),
    );
  }

  Duration _duration(Object? milliseconds) =>
      Duration(milliseconds: milliseconds is num ? milliseconds.round() : 0);

  void _clearRoute({bool phoneOutputConfirmed = false}) {
    _selectedDevice = null;
    _mediaId = null;
    _canSeek = false;
    if (!_devicesController.isClosed) {
      _devicesController.add(const <CastDevice>[]);
    }
    _emitStatus(
      CastStatus(
        state: CastPlaybackState.disconnected,
        phoneOutputConfirmed: phoneOutputConfirmed,
      ),
    );
  }

  bool _requireSupported() {
    _ensureNotDisposed();
    if (!_initialized) {
      throw StateError('AirPlay is not initialized on this device.');
    }
    return _supported;
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('AirPlayTransport has been disposed.');
    }
  }

  void _emitFailure(String message) {
    _emitStatus(
      CastStatus(
        state: CastPlaybackState.failed,
        device: _selectedDevice,
        mediaId: _mediaId,
        position: _status.position,
        canSeek: _canSeek,
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
