import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_app/services/casting/airplay_transport.dart';
import 'package:flutter_app/services/casting/cast_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('streampilot/airplay');
  const eventChannel = EventChannel('streampilot/airplay/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final methodCalls = <MethodCall>[];

  setUp(() {
    methodCalls.clear();
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      methodCalls.add(call);
      return true;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
  });

  test(
    'phone output confirmation and picker cancellation retain distinct native evidence',
    () async {
      final transport = AirPlayTransport.forTesting(supportedPlatform: true);
      addTearDown(transport.dispose);
      await transport.initialize();
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        methodCalls.add(call);
        return call.method != 'preparePhoneOutput';
      });
      expect(await transport.preparePhoneOutput(), isFalse);
      final cancellation = transport.statuses.firstWhere(
        (s) => s.selectionCancelled,
      );
      await _sendEvent(eventChannel.name, {'event': 'selectionCancelled'});
      expect((await cancellation).phoneOutputConfirmed, isFalse);
      final confirmed = transport.statuses.firstWhere(
        (s) => s.phoneOutputConfirmed,
      );
      await _sendEvent(eventChannel.name, {
        'event': 'route',
        'connected': false,
        'phoneOutputConfirmed': true,
      });
      expect((await confirmed).state, CastPlaybackState.disconnected);
      expect(methodCalls.where((c) => c.method == 'disconnect'), isEmpty);
    },
  );

  test('maps a selected native route to a concrete AirPlay device', () async {
    final transport = AirPlayTransport.forTesting(supportedPlatform: true);
    addTearDown(transport.dispose);
    await transport.initialize();

    final devicesFuture = transport.devices.firstWhere(
      (value) => value.isNotEmpty,
    );
    final statusFuture = transport.statuses.firstWhere(
      (value) => value.state == CastPlaybackState.connected,
    );
    await _sendEvent(eventChannel.name, <String, Object?>{
      'event': 'route',
      'connected': true,
      'deviceId': 'airplay-living-room',
      'deviceName': 'Living Room TV',
    });

    final devices = await devicesFuture;
    final status = await statusFuture;
    expect(devices, hasLength(1));
    expect(devices.single.id, 'airplay-living-room');
    expect(devices.single.name, 'Living Room TV');
    expect(devices.single.kind, CastRouteKind.airPlay);
    expect(status.device?.id, 'airplay-living-room');
  });

  test(
    'connect completes only after native confirms the selected route',
    () async {
      final nativeConnect = Completer<bool>();
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        methodCalls.add(call);
        if (call.method == 'connect') return nativeConnect.future;
        return true;
      });
      final transport = AirPlayTransport.forTesting(supportedPlatform: true);
      addTearDown(transport.dispose);
      await transport.initialize();
      const device = CastDevice(
        id: 'airplay-living-room',
        name: 'Living Room TV',
        kind: CastRouteKind.airPlay,
      );

      var completed = false;
      final connection = transport
          .connect(device)
          .then((_) => completed = true);
      await pumpEventQueue();
      expect(completed, isFalse);
      expect(methodCalls.last.method, 'connect');
      expect(methodCalls.last.arguments, <String, Object?>{
        'deviceId': 'airplay-living-room',
      });

      nativeConnect.complete(true);
      await connection;
      expect(completed, isTrue);
    },
  );

  test(
    'encodes the complete media payload and waits for playback events',
    () async {
      final transport = AirPlayTransport.forTesting(supportedPlatform: true);
      addTearDown(transport.dispose);
      await transport.initialize();
      const device = CastDevice(
        id: 'airplay-living-room',
        name: 'Living Room TV',
        kind: CastRouteKind.airPlay,
      );
      await transport.connect(device);

      final states = <CastPlaybackState>[];
      final subscription = transport.statuses.listen(
        (status) => states.add(status.state),
      );
      addTearDown(subscription.cancel);
      await transport.load(
        const CastMedia(
          id: 'channel-42',
          url: 'https://media.example/live/index.m3u8?token=secret',
          title: 'News',
          contentType: 'application/x-mpegURL',
          imageUrl: 'https://media.example/news.png',
          isLive: false,
          position: Duration(milliseconds: 17500),
        ),
      );

      expect(methodCalls.last.method, 'load');
      expect(methodCalls.last.arguments, <String, Object?>{
        'id': 'channel-42',
        'url': 'https://media.example/live/index.m3u8?token=secret',
        'title': 'News',
        'contentType': 'application/x-mpegURL',
        'imageUrl': 'https://media.example/news.png',
        'isLive': false,
        'positionMilliseconds': 17500,
      });
      expect(states, contains(CastPlaybackState.loading));
      expect(states, isNot(contains(CastPlaybackState.playing)));

      await _sendEvent(eventChannel.name, <String, Object?>{
        'event': 'playback',
        'state': 'playing',
        'mediaId': 'channel-42',
        'positionMilliseconds': 18000,
        'canSeek': true,
      });
      await pumpEventQueue();
      expect(states.last, CastPlaybackState.playing);
    },
  );

  test('maps pause, seek, play, stop and disconnect commands', () async {
    final transport = AirPlayTransport.forTesting(supportedPlatform: true);
    addTearDown(transport.dispose);
    await transport.initialize();
    const device = CastDevice(
      id: 'airplay-bedroom',
      name: 'Bedroom',
      kind: CastRouteKind.airPlay,
    );
    await transport.connect(device);

    await transport.pause();
    await transport.seek(const Duration(milliseconds: 3210));
    await transport.play();
    await transport.stop();
    await transport.disconnect();

    expect(methodCalls.skip(2).map((call) => call.method), <String>[
      'pause',
      'seek',
      'play',
      'stop',
      'disconnect',
    ]);
    expect(methodCalls[3].arguments, <String, Object?>{
      'positionMilliseconds': 3210,
    });
  });

  test('route loss pauses ownership and reports disconnected', () async {
    final transport = AirPlayTransport.forTesting(supportedPlatform: true);
    addTearDown(transport.dispose);
    await transport.initialize();
    await _sendEvent(eventChannel.name, <String, Object?>{
      'event': 'route',
      'connected': true,
      'deviceId': 'airplay-bedroom',
      'deviceName': 'Bedroom',
    });
    final disconnected = transport.statuses.firstWhere(
      (status) => status.state == CastPlaybackState.disconnected,
    );
    final devicesCleared = transport.devices.firstWhere(
      (devices) => devices.isEmpty,
    );

    await _sendEvent(eventChannel.name, <String, Object?>{
      'event': 'route',
      'connected': false,
    });

    expect((await disconnected).device, isNull);
    expect(await devicesCleared, isEmpty);
  });

  test('native failures never expose a source URL or credentials', () async {
    final transport = AirPlayTransport.forTesting(supportedPlatform: true);
    addTearDown(transport.dispose);
    await transport.initialize();
    final failed = transport.statuses.firstWhere(
      (status) => status.state == CastPlaybackState.failed,
    );

    await _sendEvent(eventChannel.name, <String, Object?>{
      'event': 'error',
      'code': 'AVPlayerItemFailed',
      'message': 'https://example.test/live.m3u8?token=secret failed',
    });

    final status = await failed;
    expect(status.error, 'AirPlay could not play this stream.');
    expect(status.error, isNot(contains('example.test')));
    expect(status.error, isNot(contains('secret')));
  });
}

Future<void> _sendEvent(String channel, Object? event) async {
  final completer = Completer<void>();
  final data = const StandardMethodCodec().encodeSuccessEnvelope(event);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(channel, data, (ByteData? _) {
        completer.complete();
      });
  await completer.future;
  await pumpEventQueue();
}
