import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_app/services/casting/cast_transport.dart';
import 'package:flutter_app/services/casting/google_cast_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = GoogleCastMessageCodec();

  group('native session boundaries', () {
    const contextChannel = MethodChannel('google_cast.context');
    const discoveryChannel = MethodChannel('google_cast.discovery_manager');
    const sessionChannel = MethodChannel('google_cast.session_manager');
    const mediaChannel = MethodChannel('google_cast.remote_media_client');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late GoogleCastTransport transport;
    late CastDevice device;
    final states = <CastStatus>[];
    final calls = <String>[];
    Completer<Object?>? request;
    setUp(() async {
      states.clear();
      calls.clear();
      request = null;
      messenger.setMockMethodCallHandler(contextChannel, (call) async => true);
      messenger.setMockMethodCallHandler(discoveryChannel, (call) async {
        calls.add(call.method);
        return true;
      });
      messenger.setMockMethodCallHandler(sessionChannel, (call) async {
        calls.add(call.method);
        return true;
      });
      messenger.setMockMethodCallHandler(
        mediaChannel,
        (call) async => request == null ? true : request!.future,
      );
      transport = GoogleCastTransport.forTesting(
        supportedPlatform: true,
        operationTimeout: const Duration(milliseconds: 80),
      );
      transport.statuses.listen(states.add);
      await transport.initialize();
      final devices = transport.devices.firstWhere((v) => v.isNotEmpty);
      await _sendNativeMethodCall(discoveryChannel.name, 'onDevicesChanged', [
        _iosDevice,
      ]);
      device = (await devices).single;
    });
    tearDown(() async {
      await transport.dispose();
      for (final channel in [
        contextChannel,
        discoveryChannel,
        sessionChannel,
        mediaChannel,
      ]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
    Future<void> session(int state) =>
        _sendNativeMethodCall(sessionChannel.name, 'onCurrentSessionChanged', {
          'device': _iosDevice,
          'sessionID': 'session-1',
          'connectionState': state,
          'currentDeviceMuted': false,
          'currentDeviceVolume': 0.5,
          'deviceStatusText': '',
        });
    Future<void> connect() async {
      final pending = transport.connect(device);
      await pumpEventQueue();
      await session(2);
      await pending;
    }

    test('initialize does not request discovery', () {
      expect(calls, isNot(contains('startDiscovery')));
    });
    test(
      'two authenticated scopes initialize without scanning or changing restored session',
      () async {
        await session(2);
        await transport.dispose();
        calls.clear();
        transport = GoogleCastTransport.forTesting(supportedPlatform: true);
        await transport.initialize();
        await pumpEventQueue();
        expect(calls, isEmpty);
      },
    );
    test(
      'rejected disconnect retains the connected receiver status stream',
      () async {
        await connect();
        messenger.setMockMethodCallHandler(
          sessionChannel,
          (call) async => false,
        );
        await expectLater(transport.disconnect(), throwsStateError);
        await _sendNativeMethodCall(mediaChannel.name, 'onUpdateMediaStatus', {
          'playerState': 2,
          'repeatMode': 0,
          'queueHasNextItem': false,
        });
        await pumpEventQueue();
        expect(states.last.state, CastPlaybackState.playing);
      },
    );
    test(
      'unsolicited restored session is ignored without stopping receiver',
      () async {
        await session(2);
        await pumpEventQueue();
        expect(calls, isNot(contains('endSessionAndStopCasting')));
      },
    );
    test(
      'disconnect waits for ended event and stops receiver casting',
      () async {
        await connect();
        var done = false;
        final disconnecting = transport.disconnect().then((_) => done = true);
        await pumpEventQueue();
        expect(calls, contains('endSessionAndStopCasting'));
        expect(done, isFalse);
        await session(3);
        await pumpEventQueue();
        expect(done, isFalse);
        await _sendNativeMethodCall(
          sessionChannel.name,
          'onCurrentSessionChanged',
          null,
        );
        await disconnecting;
      },
    );
    test(
      'connection deadline tears down and ignores late connected session',
      () async {
        await expectLater(
          transport.connect(device),
          throwsA(isA<TimeoutException>()),
        );
        expect(calls, contains('endSessionAndStopCasting'));
        states.clear();
        await session(2);
        await pumpEventQueue();
        expect(
          states.where((s) => s.state == CastPlaybackState.connected),
          isEmpty,
        );
        expect(
          calls.where((c) => c == 'endSessionAndStopCasting').length,
          greaterThanOrEqualTo(2),
        );
      },
    );
    test('suspended session preserves device through reconnect', () async {
      await connect();
      await session(1);
      await pumpEventQueue();
      expect(states.last.state, CastPlaybackState.reconnecting);
      expect(states.last.device?.id, device.id);
      await session(2);
      await pumpEventQueue();
      expect(states.last.state, CastPlaybackState.connected);
    });
    test(
      'control waits for native callback and propagates sanitized failure',
      () async {
        await connect();
        request = Completer<Object?>();
        var done = false;
        final control = transport.pause().then((_) => done = true);
        final failure = expectLater(control, throwsA(isA<PlatformException>()));
        await pumpEventQueue();
        expect(done, isFalse);
        request!.complete({'error': 'The Cast request did not complete.'});
        await failure;
        await pumpEventQueue();
        expect(states.last.state, CastPlaybackState.failed);
      },
    );
    test(
      'media status without receiver identity never inherits last sent id',
      () async {
        await connect();
        await transport.load(
          const CastMedia(
            id: 'new',
            url: 'https://media.example/live.m3u8',
            title: 'News',
            contentType: 'application/x-mpegURL',
          ),
        );
        await _sendNativeMethodCall(mediaChannel.name, 'onUpdateMediaStatus', {
          'playerState': 2,
          'repeatMode': 0,
          'queueHasNextItem': false,
        });
        await pumpEventQueue();
        expect(states.last.state, CastPlaybackState.playing);
        expect(states.last.mediaId, isNull);
      },
    );
  });

  test('encodes the domain media id in Cast media and request custom data', () {
    const media = CastMedia(
      id: 'channel-42',
      url: 'https://media.example/live/index.m3u8?token=secret',
      title: 'News',
      contentType: 'application/x-mpegURL',
      imageUrl: 'https://media.example/news.png',
      isLive: true,
      position: Duration(seconds: 17),
    );

    expect(codec.encodeLoadRequest(media), <String, Object?>{
      'contentId': 'channel-42',
      'contentUrl': 'https://media.example/live/index.m3u8?token=secret',
      'contentType': 'application/x-mpegURL',
      'streamType': 'live',
      'title': 'News',
      'imageUrl': 'https://media.example/news.png',
      'positionMilliseconds': 17000,
      'mediaCustomData': <String, Object?>{'streamPilotMediaId': 'channel-42'},
      'requestCustomData': <String, Object?>{
        'streamPilotMediaId': 'channel-42',
      },
    });
  });

  test(
    'recovers domain media id and confirmed playback from remote status',
    () {
      const device = CastDevice(
        id: 'living-room',
        name: 'Living room',
        kind: CastRouteKind.googleCast,
      );

      final status = codec.decodeRemoteStatus(<String, Object?>{
        'playerState': 'playing',
        'idleReason': 'none',
        'positionMilliseconds': 12500,
        'streamType': 'buffered',
        'mediaCustomData': <String, Object?>{
          'streamPilotMediaId': 'recording-7',
        },
      }, device: device);

      expect(status.state, CastPlaybackState.playing);
      expect(status.device, same(device));
      expect(status.mediaId, 'recording-7');
      expect(status.position, const Duration(milliseconds: 12500));
      expect(status.canSeek, isTrue);
    },
  );

  test('maps a receiver playback error to a credential-free failure', () {
    final status = codec.decodeRemoteStatus(<String, Object?>{
      'playerState': 'idle',
      'idleReason': 'error',
      'positionMilliseconds': 0,
      'streamType': 'live',
      'mediaCustomData': <String, Object?>{'streamPilotMediaId': 'channel-42'},
    });

    expect(status.state, CastPlaybackState.failed);
    expect(status.mediaId, 'channel-42');
    expect(status.canSeek, isFalse);
    expect(status.error, 'The Cast receiver could not play this stream.');
    expect(status.error, isNot(contains('secret')));
  });

  test('waits for a connected session before loading media', () async {
    const contextChannel = MethodChannel('google_cast.context');
    const discoveryChannel = MethodChannel('google_cast.discovery_manager');
    const sessionChannel = MethodChannel('google_cast.session_manager');
    const mediaChannel = MethodChannel('google_cast.remote_media_client');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var loadCalls = 0;

    messenger.setMockMethodCallHandler(contextChannel, (call) async => true);
    messenger.setMockMethodCallHandler(discoveryChannel, (call) async => true);
    messenger.setMockMethodCallHandler(sessionChannel, (call) async => true);
    messenger.setMockMethodCallHandler(mediaChannel, (call) async {
      if (call.method == 'loadMedia') loadCalls++;
      return <String, Object?>{
        'inProgress': true,
        'isExternal': false,
        'requestID': 1,
      };
    });

    final transport = GoogleCastTransport.forTesting(supportedPlatform: true);
    addTearDown(() async {
      await transport.dispose();
      messenger.setMockMethodCallHandler(contextChannel, null);
      messenger.setMockMethodCallHandler(discoveryChannel, null);
      messenger.setMockMethodCallHandler(sessionChannel, null);
      messenger.setMockMethodCallHandler(mediaChannel, null);
    });
    await transport.initialize();
    final deviceFuture = transport.devices.firstWhere(
      (devices) => devices.isNotEmpty,
    );
    await _sendNativeMethodCall(
      discoveryChannel.name,
      'onDevicesChanged',
      <Object?>[_iosDevice],
    );
    final device = await deviceFuture;

    var workflowCompleted = false;
    final workflow = () async {
      await transport.connect(device.single);
      await transport.load(
        const CastMedia(
          id: 'channel-42',
          url: 'https://media.example/live.m3u8',
          title: 'News',
          contentType: 'application/x-mpegURL',
        ),
      );
      workflowCompleted = true;
    }();
    await pumpEventQueue();

    expect(loadCalls, 0);
    expect(workflowCompleted, isFalse);

    await _sendNativeMethodCall(
      sessionChannel.name,
      'onCurrentSessionChanged',
      <String, Object?>{
        'device': _iosDevice,
        'sessionID': 'session-1',
        'connectionState': 2,
        'currentDeviceMuted': false,
        'currentDeviceVolume': 0.5,
        'deviceStatusText': '',
      },
    );
    await workflow;

    expect(loadCalls, 1);
    expect(workflowCompleted, isTrue);
  });
}

const Map<String, Object?> _iosDevice = <String, Object?>{
  'deviceID': 'living-room',
  'friendlyName': 'Living room',
  'modelName': 'Chromecast',
  'statusText': '',
  'deviceVersion': '1',
  'isOnLocalNetwork': true,
  'category': 'cast',
  'uniqueID': 'living-room',
  'index': 0,
};

Future<void> _sendNativeMethodCall(
  String channel,
  String method,
  Object? arguments,
) async {
  final completer = Completer<void>();
  final data = const StandardMethodCodec().encodeMethodCall(
    MethodCall(method, arguments),
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(channel, data, (ByteData? _) {
        completer.complete();
      });
  await completer.future;
}
