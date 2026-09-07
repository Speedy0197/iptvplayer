import 'dart:async';

import 'package:flutter/foundation.dart';

import 'cast_transport.dart';

typedef _LocalRecoveryIntent = ({
  String mediaId,
  int routeGeneration,
  int mediaGeneration,
  bool play,
  Duration position,
});

typedef _LocalRecoveryPosition = ({
  String mediaId,
  int routeGeneration,
  int mediaGeneration,
  Duration position,
});

abstract class LocalCastingPlayback {
  String? get mediaId;
  bool get isPlaying;
  bool get isSeekable;
  Duration get position;
  Future<CastMedia?> resolveMedia();

  /// Invalidate pending URL, probe and restore work synchronously.
  void cancelPendingOperations() {}
  void setRemotePlayback(bool value);
  Future<void> pause();
  Future<void> restore({required bool play, required Duration position});
}

/// Coordinates media ownership. Native request completion is not a playback
/// acknowledgement; only a matching media-status event completes a handoff.
class CastingController extends ChangeNotifier {
  CastingController({
    required LocalCastingPlayback local,
    required List<CastTransport> transports,
    this.operationTimeout = const Duration(seconds: 15),
  }) : _local = local,
       _transports = {
         for (final transport in transports) transport.kind: transport,
       } {
    _observedMediaId = _local.mediaId;
    for (final transport in transports) {
      _subscriptions.add(
        transport.devices.listen((devices) {
          if (_closed) return;
          _devices[transport.kind] = devices;
          notifyListeners();
        }, onError: (_) => _discoveryFailed()),
      );
      _subscriptions.add(
        transport.statuses.listen(
          (status) => _onStatus(transport, status),
          onError: (_) => _onStatus(
            transport,
            const CastStatus(
              state: CastPlaybackState.failed,
              error: 'Connection to the TV was interrupted.',
            ),
          ),
        ),
      );
    }
  }

  final LocalCastingPlayback _local;
  final Map<CastRouteKind, CastTransport> _transports;
  final Duration operationTimeout;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _devices = <CastRouteKind, List<CastDevice>>{};
  final _initializing = <CastRouteKind, Future<void>>{};
  Future<void> _serial = Future<void>.value();
  CastTransport? _active;
  CastDevice? _target;
  CastDevice? _connectingTarget;
  CastRouteKind? _pendingKind;
  String? _observedMediaId;
  String? _expectedMediaId;
  int _routeGeneration = 0;
  int _mediaGeneration = 0;
  int _discoveryGeneration = 0;
  Completer<bool>? _confirmation;
  _LocalRecoveryIntent? _pendingRecovery;
  _LocalRecoveryPosition? _recoveryPosition;
  bool _ownsPlayback = false;
  bool _closed = false;
  bool _notifierDisposed = false;
  Future<void>? _shutdown;
  Timer? _discoveryTimer;
  Timer? _reconnectTimer;
  CastStatus _status = const CastStatus(state: CastPlaybackState.disconnected);

  CastStatus get status => _status;
  bool get ownsPlayback => _ownsPlayback;
  bool get hasTarget => _target != null;
  CastDevice? get target => _target;
  bool get supportsAirPlay => _transports.containsKey(CastRouteKind.airPlay);
  bool discovering = false;
  bool awaitingPhoneOutput = false;
  String? discoveryError;
  List<CastDevice> get devices =>
      List.unmodifiable(_devices.values.expand((v) => v));

  void _publish(CastStatus next) {
    if (_closed) return;
    _status = next;
    notifyListeners();
  }

  void _setOwnership(bool value) {
    _ownsPlayback = value;
    _local.setRemotePlayback(value);
  }

  Future<void> _initialize(CastTransport transport) {
    return _initializing.putIfAbsent(transport.kind, () async {
      try {
        await transport.initialize().timeout(operationTimeout);
      } catch (_) {
        _initializing.remove(transport.kind);
        rethrow;
      }
    });
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _serial.then((_) => operation());
    _serial = next.catchError((Object _) {});
    return next;
  }

  void _cancelMedia() {
    _pendingRecovery = null;
    _recoveryPosition = null;
    awaitingPhoneOutput = false;
    _local.cancelPendingOperations();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _mediaGeneration++;
    _expectedMediaId = null;
    final pending = _confirmation;
    _confirmation = null;
    if (pending != null && !pending.isCompleted) pending.complete(false);
  }

  bool _current(int route, int media, String? id) =>
      !_closed &&
      route == _routeGeneration &&
      media == _mediaGeneration &&
      _local.mediaId == id;

  Future<void> startDiscovery() async {
    if (_closed) return;
    final generation = ++_discoveryGeneration;
    discovering = true;
    _discoveryTimer?.cancel();
    discoveryError = null;
    notifyListeners();
    await Future.wait(
      _transports.values.map((transport) async {
        try {
          await _initialize(transport);
          if (_closed || generation != _discoveryGeneration) return;
          await transport.startDiscovery().timeout(operationTimeout);
          if (_closed || generation != _discoveryGeneration) {
            await transport.stopDiscovery().timeout(operationTimeout);
            return;
          }
        } catch (_) {
          if (!_closed && generation == _discoveryGeneration) {
            _discoveryFailed();
          }
        }
      }),
    );
    if (!_closed && generation == _discoveryGeneration) {
      _discoveryTimer = Timer(const Duration(seconds: 8), () {
        if (_closed || generation != _discoveryGeneration) return;
        discovering = false;
        notifyListeners();
      });
      notifyListeners();
    }
  }

  void _discoveryFailed() {
    if (_closed) return;
    discovering = false;
    discoveryError =
        'Could not find TVs. Check local-network permission and try again.';
    notifyListeners();
  }

  Future<void> stopDiscovery() async {
    _discoveryGeneration++;
    _discoveryTimer?.cancel();
    discovering = false;
    for (final transport in _transports.values) {
      if (!_initializing.containsKey(transport.kind)) continue;
      try {
        await transport.stopDiscovery().timeout(operationTimeout);
      } catch (_) {}
    }
  }

  Future<void> connect(CastDevice device) async {
    if (_closed) return;
    final transport = _transports[device.kind];
    if (transport == null) return;
    final generation = ++_routeGeneration;
    awaitingPhoneOutput = false;
    _cancelMedia();
    final previous = _active;
    final previousTarget = _target;
    final previousStatus = _status;
    var startedNewConnection = false;
    _connectingTarget = device;
    _pendingKind = device.kind;
    _publish(CastStatus(state: CastPlaybackState.connecting, device: device));
    try {
      await _initialize(transport);
      await _enqueue(() async {
        if (_closed || generation != _routeGeneration) return;
        if (previous != null &&
            (previous != transport || previousTarget?.id != device.id)) {
          await previous.disconnect().timeout(operationTimeout);
          if (_closed || generation != _routeGeneration) return;
        }
        _active = transport;
        _target = device;
        startedNewConnection = true;
        await transport.connect(device).timeout(operationTimeout);
      });
      if (_closed || generation != _routeGeneration) return;
      _publish(CastStatus(state: CastPlaybackState.connected, device: device));
      await _loadCurrent();
    } catch (_) {
      if (!_closed && generation == _routeGeneration) {
        _local.cancelPendingOperations();
        if (startedNewConnection) {
          try {
            await transport.disconnect().timeout(operationTimeout);
          } catch (_) {}
        } else if (previous != null) {
          // The old receiver remains the controllable owner until its native
          // disconnect is confirmed. Never replace it with an unstarted route.
          _expectedMediaId = previousStatus.mediaId;
        }
        if (_closed || generation != _routeGeneration) return;
        _pendingKind = _active?.kind;
        _publish(
          CastStatus(
            state: CastPlaybackState.failed,
            device: _target ?? device,
            mediaId: startedNewConnection ? null : previousStatus.mediaId,
            position: previousStatus.position,
            canSeek: previousStatus.canSeek,
            error:
                'Could not connect to this TV. Check the network and try again.',
          ),
        );
      }
    } finally {
      if (generation == _routeGeneration) _connectingTarget = null;
    }
  }

  /// Called by the native picker's public opening delegate. Its route-change
  /// event supplies the actual device; opening/cancelling alone transfers none.
  void beginAirPlaySelection() {
    if (!_closed) _pendingKind = CastRouteKind.airPlay;
  }

  void _onStatus(CastTransport transport, CastStatus next) {
    if (_closed) return;
    if (next.selectionCancelled && transport.kind == CastRouteKind.airPlay) {
      _pendingKind = null;
      _pendingRecovery = null;
      awaitingPhoneOutput = false;
      notifyListeners();
      return;
    }
    if (awaitingPhoneOutput &&
        _transports[CastRouteKind.airPlay] == transport &&
        next.phoneOutputConfirmed) {
      unawaited(_leaveRoute(resumePlayback: true, recovery: _pendingRecovery));
      return;
    }
    if ((_pendingKind == CastRouteKind.airPlay || _active == transport) &&
        transport.kind == CastRouteKind.airPlay &&
        next.state == CastPlaybackState.connected &&
        next.device != null &&
        (_active != transport || _target?.id != next.device!.id)) {
      if (_connectingTarget?.kind == next.device!.kind &&
          _connectingTarget?.id == next.device!.id) {
        return;
      }
      unawaited(connect(next.device!));
      return;
    }
    if (_active != transport) return;
    if (next.device != null &&
        _target != null &&
        next.device!.id != _target!.id) {
      return;
    }
    if (next.state == CastPlaybackState.playing ||
        next.state == CastPlaybackState.paused) {
      if (_expectedMediaId == null ||
          next.mediaId != _expectedMediaId ||
          next.mediaId != _local.mediaId) {
        return;
      }
      _publish(next);
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      if (_confirmation?.isCompleted == false) _confirmation!.complete(true);
    } else if ((next.state == CastPlaybackState.loading ||
            next.state == CastPlaybackState.connected) &&
        next.mediaId != null &&
        next.mediaId == _expectedMediaId &&
        next.mediaId == _local.mediaId) {
      // Buffering and completion describe receiver state, not load success.
      // Only playing/paused above may complete a pending handoff.
      _publish(next);
    } else if (next.state == CastPlaybackState.failed ||
        next.state == CastPlaybackState.disconnected) {
      if (next.state == CastPlaybackState.failed &&
          next.mediaId != null &&
          next.mediaId != _expectedMediaId) {
        return;
      }
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      if (_confirmation?.isCompleted == false) {
        _confirmation!.complete(false);
      } else if (_ownsPlayback) {
        _publish(
          CastStatus(
            state: CastPlaybackState.failed,
            device: _target,
            mediaId: _expectedMediaId,
            position: _status.position,
            canSeek: _status.canSeek,
            error:
                'Playback on the TV was interrupted. Retry or watch on your phone.',
          ),
        );
      }
    } else if (next.state == CastPlaybackState.connected &&
        _status.state == CastPlaybackState.reconnecting) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _publish(
        CastStatus(
          state: CastPlaybackState.connected,
          device: _target,
          mediaId: _expectedMediaId,
          position: _status.position,
          canSeek: _status.canSeek,
        ),
      );
    } else if (next.state == CastPlaybackState.reconnecting && _ownsPlayback) {
      final route = _routeGeneration;
      _reconnectTimer ??= Timer(operationTimeout, () {
        _reconnectTimer = null;
        if (_closed ||
            route != _routeGeneration ||
            _status.state != CastPlaybackState.reconnecting) {
          return;
        }
        _publish(
          CastStatus(
            state: CastPlaybackState.failed,
            device: _target,
            mediaId: _expectedMediaId,
            position: _status.position,
            canSeek: _status.canSeek,
            error:
                'Connection to the TV could not be restored. Retry or watch on your phone.',
          ),
        );
      });
      _publish(
        CastStatus(
          state: CastPlaybackState.reconnecting,
          device: _target,
          mediaId: _expectedMediaId,
          position: _status.position,
          canSeek: _status.canSeek,
        ),
      );
    }
  }

  void synchronizeChannel() {
    if (_closed || _observedMediaId == _local.mediaId) return;
    _observedMediaId = _local.mediaId;
    _cancelMedia();
    if (_local.mediaId == null) {
      unawaited(stopPlayback());
    } else if (_active != null &&
        _status.state != CastPlaybackState.connecting) {
      unawaited(_loadCurrent());
    }
  }

  Future<void> _loadCurrent() async {
    final transport = _active;
    final id = _local.mediaId;
    if (_closed || transport == null || id == null) return;
    _cancelMedia();
    final generation = _mediaGeneration;
    final route = _routeGeneration;
    final wasRemote = _ownsPlayback;
    final wasPlaying = _local.isPlaying;
    final position = _local.isSeekable ? _local.position : Duration.zero;
    bool suspendedLocal = false;
    _publish(
      CastStatus(
        state: CastPlaybackState.loading,
        device: _target,
        mediaId: id,
      ),
    );
    try {
      final media = await _local.resolveMedia().timeout(operationTimeout);
      if (!_current(route, generation, id)) return;
      if (media == null || media.id != id) throw StateError('No current media');
      final confirmed = Completer<bool>();
      _confirmation = confirmed;
      // Attach a bounded waiter before calling native code, which may emit a
      // status synchronously while load() itself is still awaiting a request.
      final acknowledgement = confirmed.future.timeout(
        operationTimeout,
        onTimeout: () => false,
      );
      _expectedMediaId = id;
      await _enqueue(() async {
        if (!_current(route, generation, id)) return;
        _setOwnership(true);
        suspendedLocal = true;
        await _local.pause().timeout(operationTimeout);
        if (!_current(route, generation, id)) return;
        await transport.load(media).timeout(operationTimeout);
      });
      if (!_current(route, generation, id)) return;
      if (!await acknowledgement) {
        throw StateError('Receiver did not confirm media');
      }
    } catch (_) {
      if (!_current(route, generation, id)) return;
      _local.cancelPendingOperations();
      if (_confirmation?.isCompleted == false) _confirmation!.complete(false);
      _expectedMediaId = null;
      // Stop the failed load before restoring local playback. If the receiver
      // cannot be stopped, keep ownership remote to avoid surprise duplicate audio.
      var stopped = !suspendedLocal;
      if (suspendedLocal) {
        try {
          await _enqueue(() => transport.stop().timeout(operationTimeout));
          stopped = true;
        } catch (_) {}
      }
      if (!_current(route, generation, id)) return;
      var canRestoreLocally = true;
      if (!wasRemote && stopped && suspendedLocal && supportsAirPlay) {
        final recovery = (
          mediaId: id,
          routeGeneration: route,
          mediaGeneration: generation,
          play: wasPlaying,
          position: position,
        );
        _pendingRecovery = recovery;
        _recoveryPosition = (
          mediaId: id,
          routeGeneration: route,
          mediaGeneration: generation,
          position: position,
        );
        awaitingPhoneOutput = true;
        canRestoreLocally = false;
        try {
          canRestoreLocally = await _confirmPhoneOutput();
        } catch (_) {}
        if (!_current(route, generation, id)) return;
        if (_pendingRecovery == recovery) {
          awaitingPhoneOutput = !canRestoreLocally;
          if (canRestoreLocally) _pendingRecovery = null;
        } else {
          // Picker cancellation or an explicit handback superseded this check.
          // Its late result must neither restore nor rearm automatic recovery.
          canRestoreLocally = false;
        }
      }
      if (!wasRemote && stopped && canRestoreLocally) {
        if (suspendedLocal) {
          try {
            await _enqueue(() async {
              if (!_current(route, generation, id)) return;
              await _restoreLocal(play: wasPlaying, position: position);
            });
          } catch (_) {}
        }
        if (!_current(route, generation, id)) return;
        _recoveryPosition = null;
        _setOwnership(false);
      }
      _publish(
        CastStatus(
          state: CastPlaybackState.failed,
          device: _target,
          mediaId: id,
          error:
              'This stream could not play on the TV. Check its format and network access, then retry.',
        ),
      );
    }
  }

  Future<void> retry() async {
    if (_target == null) return;
    if (_ownsPlayback) {
      await _loadCurrent();
    } else {
      await connect(_target!);
    }
  }

  Future<void> _restoreLocal({
    required bool play,
    required Duration position,
  }) async {
    try {
      await _local
          .restore(play: play, position: position)
          .timeout(operationTimeout);
    } catch (_) {
      _local.cancelPendingOperations();
      rethrow;
    }
  }

  Future<void> _control(Future<void> Function(CastTransport) operation) async {
    final transport = _active;
    final route = _routeGeneration;
    if (_closed || transport == null || !_ownsPlayback) return;
    try {
      await _enqueue(() async {
        if (!_closed && route == _routeGeneration) {
          await operation(transport).timeout(operationTimeout);
        }
      });
    } catch (_) {
      if (!_closed && route == _routeGeneration) {
        _publish(
          CastStatus(
            state: CastPlaybackState.failed,
            device: _target,
            mediaId: _expectedMediaId,
            error: 'The TV did not respond. Retry or watch on your phone.',
          ),
        );
      }
    }
  }

  Future<void> pause() => _control((transport) => transport.pause());
  Future<void> play() => _control((transport) => transport.play());
  Future<void> seek(Duration position) async {
    if (_status.canSeek && position >= Duration.zero) {
      await _control((transport) => transport.seek(position));
    }
  }

  Future<void> returnToPhone() async {
    final transport = _active;
    if (_closed || transport == null) return;
    // An explicit user handback supersedes automatic initial-load recovery.
    _pendingRecovery = null;
    if (supportsAirPlay) {
      final route = _routeGeneration;
      awaitingPhoneOutput = true;
      notifyListeners();
      try {
        final confirmed = await _confirmPhoneOutput();
        if (_closed || route != _routeGeneration || !awaitingPhoneOutput) {
          return;
        }
        if (confirmed) {
          awaitingPhoneOutput = false;
          await _leaveRoute(resumePlayback: true);
        }
      } catch (_) {
        if (!_closed && route == _routeGeneration) {
          awaitingPhoneOutput = false;
          notifyListeners();
        }
      }
      return;
    }
    await _leaveRoute(resumePlayback: true);
  }

  Future<bool> _confirmPhoneOutput() async {
    final output = _transports[CastRouteKind.airPlay];
    if (output is! PhoneOutputConfirmation) return false;
    await _initialize(output!);
    return (output as PhoneOutputConfirmation).preparePhoneOutput().timeout(
      operationTimeout,
    );
  }

  Future<void> disconnect() => _leaveRoute(resumePlayback: false);

  Future<void> _leaveRoute({
    required bool resumePlayback,
    _LocalRecoveryIntent? recovery,
  }) async {
    final transport = _active;
    if (_closed || transport == null) return;
    if (recovery != null &&
        !_current(
          recovery.routeGeneration,
          recovery.mediaGeneration,
          recovery.mediaId,
        )) {
      _pendingRecovery = null;
      awaitingPhoneOutput = false;
      return;
    }
    final savedPosition = _recoveryPosition;
    final validSavedPosition =
        savedPosition != null &&
        _current(
          savedPosition.routeGeneration,
          savedPosition.mediaGeneration,
          savedPosition.mediaId,
        );
    final route = ++_routeGeneration;
    _connectingTarget = null;
    awaitingPhoneOutput = false;
    final id = _local.mediaId;
    final resumeAt =
        recovery?.position ??
        (_status.canSeek && _status.mediaId == id
            ? _status.position
            : validSavedPosition
            ? savedPosition.position
            : Duration.zero);
    final resumePlaying =
        recovery?.play ??
        (resumePlayback && _status.state != CastPlaybackState.paused);
    _cancelMedia();
    final mediaGeneration = _mediaGeneration;
    try {
      await _enqueue(() async {
        if (!_current(route, mediaGeneration, id)) return;
        await transport.disconnect().timeout(operationTimeout);
        if (!_current(route, mediaGeneration, id)) return;
        if (id != null && _local.mediaId == id) {
          await _restoreLocal(play: resumePlaying, position: resumeAt);
        }
      });
      if (!_current(route, mediaGeneration, id)) return;
      _active = null;
      _target = null;
      _pendingKind = null;
      _setOwnership(false);
      _publish(const CastStatus(state: CastPlaybackState.disconnected));
    } catch (_) {
      if (_current(route, mediaGeneration, id)) {
        // A failed disconnect has not consumed this recording's position.
        // Retain only position; another handback still requires user intent.
        if (validSavedPosition) {
          _recoveryPosition = (
            mediaId: savedPosition.mediaId,
            routeGeneration: route,
            mediaGeneration: mediaGeneration,
            position: savedPosition.position,
          );
        }
        _publish(
          CastStatus(
            state: CastPlaybackState.failed,
            device: _target,
            error:
                'Could not stop playback on the TV. Try returning to the phone again.',
          ),
        );
      }
    }
  }

  Future<void> stopPlayback() async {
    _connectingTarget = null;
    awaitingPhoneOutput = false;
    final route = ++_routeGeneration;
    _cancelMedia();
    final transport = _active;
    try {
      if (transport != null) {
        await _enqueue(() => transport.stop().timeout(operationTimeout));
      }
      if (_closed || route != _routeGeneration) return;
      _setOwnership(false);
      _publish(
        CastStatus(
          state: transport == null
              ? CastPlaybackState.disconnected
              : CastPlaybackState.connected,
          device: _target,
        ),
      );
    } catch (_) {
      if (!_closed && route == _routeGeneration) {
        _publish(
          CastStatus(
            state: CastPlaybackState.failed,
            device: _target,
            error: 'The TV did not confirm stopping. Check the receiver.',
          ),
        );
      }
    }
  }

  Future<void> shutdown() => _shutdown ??= _close();
  Future<void> _close() async {
    _connectingTarget = null;
    _closed = true;
    _discoveryTimer?.cancel();
    _routeGeneration++;
    _discoveryGeneration++;
    _cancelMedia();
    for (final subscription in _subscriptions) {
      try {
        await subscription.cancel().timeout(operationTimeout);
      } catch (_) {}
    }
    try {
      await _enqueue(() async {
        if (_active != null) {
          await _active!.disconnect().timeout(operationTimeout);
        }
      });
    } catch (_) {}
    for (final transport in _transports.values) {
      try {
        await transport.dispose().timeout(operationTimeout);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    if (_notifierDisposed) return;
    _notifierDisposed = true;
    unawaited(shutdown());
    super.dispose();
  }
}
