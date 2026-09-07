import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/casting/cast_transport.dart';
import 'package:flutter_app/services/casting/casting_controller.dart';

const shield = CastDevice(
  id: 'shield',
  name: 'Living Room',
  kind: CastRouteKind.googleCast,
);
CastMedia media(String id, {bool live = true}) => CastMedia(
  id: id,
  url: 'https://provider.test/$id.m3u8',
  title: id,
  contentType: 'application/x-mpegURL',
  isLive: live,
);

class LocalPlayback extends LocalCastingPlayback {
  String? id = 'one';
  bool playing = true;
  bool suppressed = false;
  bool seekable = false;
  Duration currentPosition = const Duration(seconds: 12);
  Completer<CastMedia?>? pendingResolution;
  Completer<void>? pendingPause;
  Completer<void>? pendingRestore;
  int cancellations = 0;
  final restores = <({bool play, Duration position})>[];
  @override
  String? get mediaId => id;
  @override
  bool get isPlaying => playing;
  @override
  Duration get position => currentPosition;
  @override
  bool get isSeekable => seekable;
  @override
  Future<CastMedia?> resolveMedia() async => pendingResolution == null
      ? (id == null ? null : media(id!, live: !seekable))
      : pendingResolution!.future;
  @override
  void setRemotePlayback(bool value) => suppressed = value;
  @override
  void cancelPendingOperations() {
    cancellations++;
  }

  @override
  Future<void> pause() async {
    await pendingPause?.future;
    playing = false;
  }

  @override
  Future<void> restore({required bool play, required Duration position}) async {
    final generation = cancellations;
    await pendingRestore?.future;
    if (generation != cancellations) return;
    playing = play;
    currentPosition = position;
    restores.add((play: play, position: position));
  }
}

class Receiver extends CastTransport {
  Receiver({this.routeKind = CastRouteKind.googleCast});
  final CastRouteKind routeKind;
  final deviceEvents = StreamController<List<CastDevice>>.broadcast(sync: true);
  final statusEvents = StreamController<CastStatus>.broadcast(sync: true);
  final loaded = <String>[];
  Completer<void>? pendingConnection;
  Completer<void>? pendingStop;
  Completer<void>? pendingDisconnect;
  Completer<void>? pendingDispose;
  Completer<void>? pendingInitialize;
  int connects = 0;
  int disconnects = 0;
  bool rejectDisconnect = false;
  bool initialized = false;
  bool rejectLoad = false;
  bool autoConfirm = true;
  int stops = 0;
  @override
  CastRouteKind get kind => routeKind;
  @override
  Stream<List<CastDevice>> get devices => deviceEvents.stream;
  @override
  Stream<CastStatus> get statuses => statusEvents.stream;
  @override
  Future<void> initialize() async {
    await pendingInitialize?.future;
    initialized = true;
  }

  @override
  Future<void> startDiscovery() async {
    deviceEvents.add([shield]);
  }

  @override
  Future<void> stopDiscovery() async {}
  @override
  Future<void> connect(CastDevice device) async {
    connects++;
    await pendingConnection?.future;
    statusEvents.add(
      CastStatus(state: CastPlaybackState.connected, device: device),
    );
  }

  @override
  Future<void> load(CastMedia media) async {
    loaded.add(media.id);
    if (rejectLoad) throw StateError('secret-provider-url');
    if (autoConfirm) {
      statusEvents.add(
        CastStatus(
          state: CastPlaybackState.playing,
          device: shield,
          mediaId: media.id,
        ),
      );
    }
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> stop() async {
    stops++;
    await pendingStop?.future;
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    if (rejectDisconnect) throw StateError('Receiver is still playing');
    await pendingDisconnect?.future;
  }

  @override
  Future<void> dispose() async {
    await pendingDispose?.future;
    await deviceEvents.close();
    await statusEvents.close();
  }
}

class AirReceiver extends Receiver implements PhoneOutputConfirmation {
  AirReceiver() : super(routeKind: CastRouteKind.airPlay);
  bool phoneOutput = false;
  Completer<bool>? pendingPhoneOutput;
  @override
  Future<bool> preparePhoneOutput() async =>
      pendingPhoneOutput == null ? phoneOutput : pendingPhoneOutput!.future;
}

Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  late LocalPlayback local;
  late Receiver receiver;
  late CastingController controller;
  setUp(() {
    local = LocalPlayback();
    receiver = Receiver();
    controller = CastingController(
      local: local,
      transports: [receiver],
      operationTimeout: const Duration(milliseconds: 100),
    );
  });
  tearDown(() async {
    await controller.shutdown();
    controller.dispose();
  });

  for (final changeChannel in [false, true]) {
    test(
      'explicit phone return after recovery cancellation preserves only current recording position changed=$changeChannel',
      () async {
        await controller.shutdown();
        receiver = Receiver()..rejectLoad = true;
        final air = AirReceiver();
        local.seekable = true;
        local.playing = false;
        local.currentPosition = const Duration(seconds: 75);
        controller = CastingController(
          local: local,
          transports: [receiver, air],
        );
        await controller.connect(shield);
        air.statusEvents.add(
          const CastStatus(
            state: CastPlaybackState.connected,
            selectionCancelled: true,
          ),
        );
        if (changeChannel) {
          receiver.rejectLoad = false;
          local.id = 'two';
          controller.synchronizeChannel();
          await flush();
        }
        air.phoneOutput = true;
        receiver.rejectDisconnect = true;
        await controller.returnToPhone();
        expect(local.restores, isEmpty);
        expect(controller.ownsPlayback, isTrue);
        receiver.rejectDisconnect = false;
        await controller.returnToPhone();
        expect(local.restores, [
          (
            play: true,
            position: changeChannel
                ? Duration.zero
                : const Duration(seconds: 75),
          ),
        ]);
      },
    );
  }

  test(
    'cancelled recovery check cannot rearm pending phone restoration',
    () async {
      await controller.shutdown();
      receiver = Receiver()..rejectLoad = true;
      final air = AirReceiver()..pendingPhoneOutput = Completer<bool>();
      controller = CastingController(local: local, transports: [receiver, air]);
      final connecting = controller.connect(shield);
      await flush();
      air.statusEvents.add(
        const CastStatus(
          state: CastPlaybackState.connected,
          selectionCancelled: true,
        ),
      );
      air.pendingPhoneOutput!.complete(false);
      await connecting;
      air.statusEvents.add(
        const CastStatus(
          state: CastPlaybackState.disconnected,
          phoneOutputConfirmed: true,
        ),
      );
      await flush();
      expect(local.restores, isEmpty);
      expect(controller.awaitingPhoneOutput, isFalse);
    },
  );

  test(
    'deferred restoration checks media generation after receiver termination',
    () async {
      await controller.shutdown();
      receiver = Receiver()..rejectLoad = true;
      final air = AirReceiver();
      controller = CastingController(local: local, transports: [receiver, air]);
      await controller.connect(shield);
      receiver.pendingDisconnect = Completer<void>();
      air.statusEvents.add(
        const CastStatus(
          state: CastPlaybackState.disconnected,
          phoneOutputConfirmed: true,
        ),
      );
      await flush();
      expect(local.restores, isEmpty);
      receiver.rejectLoad = false;
      local.id = 'two';
      controller.synchronizeChannel();
      local.id = 'one';
      controller.synchronizeChannel();
      receiver.pendingDisconnect!.complete();
      await flush();
      await flush();
      expect(local.restores, isEmpty);
      expect(controller.ownsPlayback, isTrue);
    },
  );

  for (final wasPlaying in [false, true]) {
    test(
      'deferred failure recovery preserves recording play=$wasPlaying and position',
      () async {
        await controller.shutdown();
        receiver = Receiver()..rejectLoad = true;
        final air = AirReceiver();
        local.seekable = true;
        local.playing = wasPlaying;
        local.currentPosition = const Duration(seconds: 75);
        controller = CastingController(
          local: local,
          transports: [receiver, air],
          operationTimeout: const Duration(milliseconds: 100),
        );
        await controller.connect(shield);
        expect(controller.awaitingPhoneOutput, isTrue);
        expect(receiver.stops, 1);
        expect(local.restores, isEmpty);
        air.statusEvents.add(
          const CastStatus(
            state: CastPlaybackState.disconnected,
            phoneOutputConfirmed: true,
          ),
        );
        await flush();
        expect(local.restores, [
          (play: wasPlaying, position: const Duration(seconds: 75)),
        ]);
        expect(controller.ownsPlayback, isFalse);
      },
    );
  }

  for (final cancellation in [
    'picker',
    'stop',
    'channel',
    'route',
    'retry',
    'shutdown',
  ]) {
    test(
      'deferred recovery ignores late phone confirmation after $cancellation',
      () async {
        await controller.shutdown();
        receiver = Receiver()..rejectLoad = true;
        final air = AirReceiver();
        local.seekable = true;
        local.playing = false;
        local.currentPosition = const Duration(seconds: 75);
        controller = CastingController(
          local: local,
          transports: [receiver, air],
          operationTimeout: const Duration(milliseconds: 100),
        );
        await controller.connect(shield);
        receiver.rejectLoad = false;
        switch (cancellation) {
          case 'picker':
            air.statusEvents.add(
              const CastStatus(
                state: CastPlaybackState.connected,
                selectionCancelled: true,
              ),
            );
          case 'stop':
            await controller.stopPlayback();
          case 'channel':
            local.id = 'two';
            controller.synchronizeChannel();
            await flush();
          case 'route':
            await controller.connect(shield);
          case 'retry':
            await controller.retry();
          case 'shutdown':
            await controller.shutdown();
        }
        if (cancellation != 'shutdown') {
          air.statusEvents.add(
            const CastStatus(
              state: CastPlaybackState.disconnected,
              phoneOutputConfirmed: true,
            ),
          );
          await flush();
        }
        expect(local.restores, isEmpty);
        expect(controller.awaitingPhoneOutput, isFalse);
      },
    );
  }

  for (final failure in ['rejected', 'timeout']) {
    test(
      'direct phone handback never restores after $failure disconnect',
      () async {
        await controller.connect(shield);
        receiver.rejectDisconnect = failure == 'rejected';
        if (failure == 'timeout') {
          receiver.pendingDisconnect = Completer<void>();
        }
        await controller.returnToPhone().timeout(
          const Duration(milliseconds: 500),
        );
        expect(local.restores, isEmpty);
        expect(controller.ownsPlayback, isTrue);
        expect(controller.target?.id, shield.id);
        await controller.shutdown().timeout(const Duration(milliseconds: 500));
        expect(receiver.disconnects, 2);
        expect(local.restores, isEmpty);
      },
    );
  }

  test(
    'failed old disconnect preserves receiver for handback and shutdown',
    () async {
      await controller.shutdown();
      receiver = Receiver();
      final air = AirReceiver()..phoneOutput = true;
      controller = CastingController(
        local: local,
        transports: [receiver, air],
        operationTimeout: const Duration(milliseconds: 50),
      );
      await controller.connect(shield);
      receiver.rejectDisconnect = true;
      await controller.connect(
        const CastDevice(
          id: 'air',
          name: 'Air TV',
          kind: CastRouteKind.airPlay,
        ),
      );
      expect(controller.target?.id, shield.id);
      expect(air.connects, 0);
      expect(controller.ownsPlayback, isTrue);
      await controller.retry();
      expect(receiver.loaded, ['one', 'one']);
      expect(controller.status.state, CastPlaybackState.playing);
      await controller.returnToPhone();
      expect(local.restores, isEmpty);
      expect(controller.target?.id, shield.id);
      await controller.shutdown();
      expect(receiver.disconnects, 3);
      expect(local.restores, isEmpty);
    },
  );

  test(
    'Cast phone return checks lingering AirPlay output across route switch',
    () async {
      await controller.shutdown();
      receiver = Receiver();
      final air = AirReceiver()..autoConfirm = false;
      controller = CastingController(
        local: local,
        transports: [air, receiver],
        operationTimeout: const Duration(milliseconds: 100),
      );
      const tv = CastDevice(
        id: 'air',
        name: 'Air TV',
        kind: CastRouteKind.airPlay,
      );
      final first = controller.connect(tv);
      await flush();
      air.statusEvents.add(
        const CastStatus(
          state: CastPlaybackState.playing,
          device: tv,
          mediaId: 'one',
        ),
      );
      await first;
      await controller.connect(shield);
      await controller.returnToPhone();
      expect(controller.awaitingPhoneOutput, isTrue);
      expect(local.restores, isEmpty);
      expect(receiver.disconnects, 0);
      air.statusEvents.add(
        const CastStatus(
          state: CastPlaybackState.disconnected,
          phoneOutputConfirmed: true,
        ),
      );
      await flush();
      expect(receiver.disconnects, 1);
      expect(local.restores.single.play, isTrue);
    },
  );

  test(
    'matching receiver buffering and completion replace playing status',
    () async {
      await controller.connect(shield);
      for (final state in [
        CastPlaybackState.loading,
        CastPlaybackState.playing,
        CastPlaybackState.connected,
      ]) {
        receiver.statusEvents.add(
          CastStatus(state: state, device: shield, mediaId: 'one'),
        );
        expect(controller.status.state, state);
        expect(controller.ownsPlayback, isTrue);
      }
      expect(local.restores, isEmpty);
    },
  );

  test(
    'buffering and idle with another identity cannot change playback or confirm a load',
    () async {
      receiver.autoConfirm = false;
      final connecting = controller.connect(shield);
      await flush();
      for (final state in [
        CastPlaybackState.loading,
        CastPlaybackState.connected,
      ]) {
        receiver.statusEvents.add(
          CastStatus(state: state, device: shield, mediaId: 'one'),
        );
      }
      await connecting;
      expect(controller.status.state, CastPlaybackState.failed);
      receiver.autoConfirm = true;
      await controller.connect(shield);
      for (final state in [
        CastPlaybackState.loading,
        CastPlaybackState.connected,
      ]) {
        receiver.statusEvents.add(
          CastStatus(state: state, device: shield, mediaId: 'old'),
        );
        expect(controller.status.state, CastPlaybackState.playing);
      }
    },
  );

  test(
    'AirPlay phone return waits for builtin output and cancellation keeps ownership',
    () async {
      await controller.shutdown();
      final air = AirReceiver()..autoConfirm = false;
      controller = CastingController(
        local: local,
        transports: [air],
        operationTimeout: const Duration(milliseconds: 100),
      );
      const tv = CastDevice(
        id: 'air',
        name: 'Air',
        kind: CastRouteKind.airPlay,
      );
      final connecting = controller.connect(tv);
      await flush();
      air.statusEvents.add(
        const CastStatus(
          state: CastPlaybackState.playing,
          device: tv,
          mediaId: 'one',
        ),
      );
      await connecting;
      await controller.returnToPhone();
      expect(controller.awaitingPhoneOutput, isTrue);
      expect(local.restores, isEmpty);
      air.statusEvents.add(
        const CastStatus(
          state: CastPlaybackState.connected,
          selectionCancelled: true,
        ),
      );
      expect(controller.awaitingPhoneOutput, isFalse);
      expect(controller.ownsPlayback, isTrue);
      expect(controller.status.state, CastPlaybackState.playing);
      await controller.returnToPhone();
      air.statusEvents.add(
        const CastStatus(
          state: CastPlaybackState.disconnected,
          phoneOutputConfirmed: true,
        ),
      );
      await flush();
      expect(local.restores.single.play, isTrue);
      expect(controller.ownsPlayback, isFalse);
    },
  );

  test(
    'switching an already active AirPlay receiver loads current media',
    () async {
      await controller.shutdown();
      final air = Receiver(routeKind: CastRouteKind.airPlay)
        ..autoConfirm = false;
      controller = CastingController(
        local: local,
        transports: [air],
        operationTimeout: const Duration(milliseconds: 100),
      );
      const first = CastDevice(
        id: 'air1',
        name: 'Air1',
        kind: CastRouteKind.airPlay,
      );
      const second = CastDevice(
        id: 'air2',
        name: 'Air2',
        kind: CastRouteKind.airPlay,
      );
      final connecting = controller.connect(first);
      await flush();
      air.statusEvents.add(
        const CastStatus(
          state: CastPlaybackState.playing,
          device: first,
          mediaId: 'one',
        ),
      );
      await connecting;
      controller.beginAirPlaySelection();
      air.statusEvents.add(
        const CastStatus(state: CastPlaybackState.connected, device: second),
      );
      await flush();
      air.statusEvents.add(
        const CastStatus(
          state: CastPlaybackState.playing,
          device: second,
          mediaId: 'one',
        ),
      );
      await flush();
      expect(controller.target?.id, second.id);
      expect(air.loaded, ['one', 'one']);
    },
  );

  test(
    'cancelled cross-transport switch never connects after old disconnect',
    () async {
      await controller.shutdown();
      receiver = Receiver();
      final airPlay = Receiver(routeKind: CastRouteKind.airPlay);
      controller = CastingController(
        local: local,
        transports: [receiver, airPlay],
        operationTimeout: const Duration(milliseconds: 50),
      );
      await controller.connect(shield);
      receiver.pendingDisconnect = Completer<void>();
      final switching = controller.connect(
        const CastDevice(id: 'air', name: 'Air', kind: CastRouteKind.airPlay),
      );
      await flush();
      final stopping = controller.stopPlayback();
      receiver.pendingDisconnect!.complete();
      await Future.wait([switching, stopping]);
      expect(airPlay.connects, 0);
    },
  );

  test(
    'never completing local pause does not strand stop or shutdown',
    () async {
      local.pendingPause = Completer<void>();
      final connecting = controller.connect(shield);
      await flush();
      await controller.stopPlayback().timeout(
        const Duration(milliseconds: 400),
      );
      await connecting;
      expect(receiver.loaded, isEmpty);
    },
  );

  test('never completing transport dispose has a bounded shutdown', () async {
    receiver.pendingDispose = Completer<void>();
    await controller.shutdown().timeout(const Duration(milliseconds: 400));
    receiver.pendingDispose!.complete();
  });

  test('restore timeout invalidates late local playback', () async {
    await controller.connect(shield);
    local.pendingRestore = Completer<void>();
    await controller.returnToPhone();
    local.pendingRestore!.complete();
    await flush();
    expect(local.restores, isEmpty);
  });

  test(
    'route change cancels restore before new connection completes',
    () async {
      await controller.connect(shield);
      local.pendingRestore = Completer<void>();
      final returning = controller.returnToPhone();
      await flush();
      receiver.pendingConnection = Completer<void>();
      final connecting = controller.connect(shield);
      local.pendingRestore!.complete();
      await returning;
      expect(local.restores, isEmpty);
      receiver.pendingConnection!.complete();
      await connecting;
    },
  );

  test(
    'slow Google initialization does not delay AirPlay listener readiness',
    () async {
      await controller.shutdown();
      receiver = Receiver()..pendingInitialize = Completer<void>();
      final airPlay = Receiver(routeKind: CastRouteKind.airPlay);
      controller = CastingController(
        local: local,
        transports: [receiver, airPlay],
      );
      final discovery = controller.startDiscovery();
      await flush();
      expect(airPlay.initialized, isTrue);
      receiver.pendingInitialize!.complete();
      await discovery;
    },
  );

  test('old media failure cannot reject newer pending confirmation', () async {
    await controller.connect(shield);
    receiver.autoConfirm = false;
    local.id = 'two';
    controller.synchronizeChannel();
    await flush();
    receiver.statusEvents.add(
      const CastStatus(
        state: CastPlaybackState.failed,
        device: shield,
        mediaId: 'one',
      ),
    );
    receiver.statusEvents.add(
      const CastStatus(
        state: CastPlaybackState.playing,
        device: shield,
        mediaId: 'two',
      ),
    );
    await flush();
    expect(controller.status.state, CastPlaybackState.playing);
    expect(controller.status.mediaId, 'two');
  });

  test(
    'reconnection that never resolves reaches failure with remote ownership',
    () async {
      await controller.connect(shield);
      receiver.statusEvents.add(
        const CastStatus(state: CastPlaybackState.reconnecting, device: shield),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(controller.status.state, CastPlaybackState.failed);
      expect(controller.ownsPlayback, isTrue);
    },
  );

  test(
    'failed initial load restores local playback and hides provider error',
    () async {
      receiver.rejectLoad = true;
      await controller.connect(shield);
      expect(receiver.loaded, ['one']);
      expect(local.playing, isTrue);
      expect(local.suppressed, isFalse);
      expect(controller.status.state, CastPlaybackState.failed);
      expect(controller.status.error, isNot(contains('secret-provider-url')));
    },
  );

  test('paused local playback stays paused when casting fails', () async {
    local.playing = false;
    receiver.rejectLoad = true;
    await controller.connect(shield);
    expect(local.playing, isFalse);
    expect(local.restores.single.play, isFalse);
  });

  test('channel changed during resolution never loads stale media', () async {
    final oldResolution = Completer<CastMedia?>();
    local.pendingResolution = oldResolution;
    final first = controller.connect(shield);
    await flush();
    local.id = 'two';
    local.pendingResolution = null;
    controller.synchronizeChannel();
    oldResolution.complete(media('one'));
    await first;
    await flush();
    expect(receiver.loaded, ['two']);
  });

  test('stop during connection prevents a late media load', () async {
    receiver.pendingConnection = Completer<void>();
    final connecting = controller.connect(shield);
    await flush();
    local.id = null;
    final stopped = controller.stopPlayback();
    receiver.pendingConnection!.complete();
    await connecting;
    await stopped;
    expect(receiver.loaded, isEmpty);
    expect(local.restores, isEmpty);
  });

  test('request completion alone does not claim the TV is playing', () async {
    receiver.autoConfirm = false;
    final connecting = controller.connect(shield);
    await flush();
    expect(controller.status.state, CastPlaybackState.loading);
    receiver.statusEvents.add(
      const CastStatus(
        state: CastPlaybackState.playing,
        device: shield,
        mediaId: 'one',
      ),
    );
    await connecting;
    expect(controller.status.state, CastPlaybackState.playing);
    expect(local.suppressed, isTrue);
    expect(local.playing, isFalse);
  });

  test('status for another media item cannot confirm our load', () async {
    receiver.autoConfirm = false;
    final connecting = controller.connect(shield);
    await flush();
    receiver.statusEvents.add(
      const CastStatus(
        state: CastPlaybackState.playing,
        device: shield,
        mediaId: 'different',
      ),
    );
    expect(controller.status.state, CastPlaybackState.loading);
    await connecting;
    expect(controller.status.state, CastPlaybackState.failed);
    expect(local.suppressed, isFalse);
  });

  test('remote pause never resumes the local decoder', () async {
    await controller.connect(shield);
    receiver.statusEvents.add(
      const CastStatus(
        state: CastPlaybackState.paused,
        device: shield,
        mediaId: 'one',
      ),
    );
    expect(controller.status.state, CastPlaybackState.paused);
    expect(local.playing, isFalse);
    expect(local.restores, isEmpty);
  });

  test('return to phone uses the remote recording position', () async {
    local.seekable = true;
    await controller.connect(shield);
    receiver.statusEvents.add(
      const CastStatus(
        state: CastPlaybackState.playing,
        device: shield,
        mediaId: 'one',
        position: Duration(seconds: 75),
        canSeek: true,
      ),
    );
    await controller.returnToPhone();
    expect(local.restores.single, (
      play: true,
      position: const Duration(seconds: 75),
    ));
    expect(local.suppressed, isFalse);
  });

  test('connecting without a channel does not claim playback', () async {
    local.id = null;
    await controller.connect(shield);
    expect(receiver.loaded, isEmpty);
    expect(controller.status.state, CastPlaybackState.connected);
  });

  test('closing discovery leaves playback on the receiver', () async {
    await controller.connect(shield);
    await controller.stopDiscovery();
    expect(receiver.stops, 0);
    expect(local.suppressed, isTrue);
  });

  test('an old stop cannot overwrite a newer connection', () async {
    await controller.connect(shield);
    receiver.pendingStop = Completer<void>();
    final stopping = controller.stopPlayback();
    await flush();
    receiver.pendingConnection = Completer<void>();
    final connecting = controller.connect(shield);
    receiver.pendingStop!.complete();
    await stopping;
    expect(controller.status.state, CastPlaybackState.connecting);
    receiver.pendingConnection!.complete();
    await connecting;
    expect(controller.status.state, CastPlaybackState.playing);
  });
}
