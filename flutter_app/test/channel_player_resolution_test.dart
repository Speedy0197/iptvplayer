import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' hide Playlist;
import 'package:media_kit_video/media_kit_video.dart';

import 'package:flutter_app/models/models.dart';
import 'package:flutter_app/services/api_client.dart';
import 'package:flutter_app/services/playlist_store.dart';
import 'package:flutter_app/widgets/channel_player.dart';

// Keep the real player widget and store; replace only the native media output.
class TestPlayer extends PlatformPlayer {
  TestPlayer() : super(configuration: const PlayerConfiguration());

  final opened = <String>[];
  void emitError(String message) => errorController.add(message);
  void emitBuffering(bool buffering) {
    state = state.copyWith(buffering: buffering);
    bufferingController.add(buffering);
  }

  void emitPlaying(bool playing) {
    state = state.copyWith(playing: playing);
    playingController.add(playing);
  }

  void emitPosition(Duration position) {
    state = state.copyWith(position: position);
    positionController.add(position);
  }

  int plays = 0;
  int seeks = 0;
  Completer<void>? pendingOpen;
  @override
  Future<void> play() async {
    plays++;
  }

  @override
  Future<void> seek(Duration position) async {
    seeks++;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened.add((playable as Media).uri);
    await pendingOpen?.future;
  }
}

class TestVideoController implements VideoController {
  TestVideoController(this.player);

  @override
  final Player player;
  @override
  final notifier = ValueNotifier<Never?>(null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Channel channel(String url) => Channel(
  id: 1,
  playlistId: 1,
  streamId: '1:0:19:1:1:1:0:0:0:0:',
  name: 'Test channel',
  groupName: 'Sat',
  streamUrl: url,
  logoUrl: '',
  epgChannelId: '',
  isFavorite: false,
);

void main() {
  group('network buffering', () {
    late TestPlayer output;
    late PlaylistStore store;

    Future<void> mount(
      WidgetTester tester, {
      bool alreadyPlaying = true,
      bool alreadyBuffering = false,
    }) async {
      output = TestPlayer();
      output.state = output.state.copyWith(
        playing: alreadyPlaying,
        buffering: alreadyBuffering,
        position: alreadyPlaying ? const Duration(seconds: 30) : Duration.zero,
      );
      final player = Player(platformPlayer: output);
      final controller = TestVideoController(player);
      store = PlaylistStore(
        api: ApiClient(baseUrl: 'http://backend.test/api/v1'),
      )..nowPlaying = channel('http://receiver.test:8001/first');
      store.replacePlayer(player, controller);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChannelPlayer(
              store: store,
              streamUrl: store.nowPlaying!.streamUrl,
            ),
          ),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        store.dispose();
        controller.notifier.dispose();
        await tester.idle();
      });
    }

    testWidgets('opens immediately and allows a slow startup to finish', (
      tester,
    ) async {
      await mount(tester, alreadyPlaying: false);
      expect(output.opened, ['http://receiver.test:8001/first']);
      await tester.pump(const Duration(seconds: 20));
      expect(output.opened, hasLength(1));

      output.emitPlaying(true);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pump(const Duration(seconds: 30));
      expect(output.opened, hasLength(1));
    });

    testWidgets('initial connection and a later refill have distinct labels', (
      tester,
    ) async {
      await mount(tester, alreadyPlaying: false);
      expect(find.text('Connecting…'), findsOneWidget);
      output.emitPlaying(true);
      output.emitBuffering(true);
      await tester.pump();
      expect(find.text('Buffering…'), findsOneWidget);
      expect(find.text('Connecting…'), findsNothing);
    });

    testWidgets(
      'unavailable playback keeps provider URLs and credentials out of UI',
      (tester) async {
        await mount(tester);
        for (var i = 0; i < 3; i++) {
          output.emitError(
            'HTTP 403 https://provider.invalid/live/private-user/private-password/7?token=secret',
          );
          await tester.pump();
        }
        expect(find.text('Unavailable'), findsOneWidget);
        expect(find.textContaining('source account'), findsOneWidget);
        expect(find.byTooltip('Pause'), findsNothing);
        expect(find.byTooltip('Play'), findsNothing);
        expect(find.byTooltip('Mute'), findsNothing);
        expect(find.text('Retry'), findsOneWidget);
        expect(find.textContaining('private-password'), findsNothing);
        expect(find.textContaining('provider.invalid'), findsNothing);
        expect(store.playbackError.value, isNot(contains('private-user')));
      },
    );

    testWidgets('a startup that never finishes still exhausts retries', (
      tester,
    ) async {
      await mount(tester, alreadyPlaying: false);
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 31));
      }
      expect(output.opened, hasLength(3));
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('playing events do not hide an ongoing buffer refill', (
      tester,
    ) async {
      await mount(tester);
      output.emitBuffering(true);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      output.emitPlaying(true);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      output.emitBuffering(false);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a recreated preview reflects the existing buffer refill', (
      tester,
    ) async {
      await mount(tester, alreadyBuffering: true);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(output.opened, isEmpty);
    });

    for (final action in [
      'recovers',
      'recovers then pauses',
      'recovers then buffers again',
      'stays stalled',
      'switches channel',
    ]) {
      testWidgets('audio packet error during buffer refill $action', (
        tester,
      ) async {
        await mount(tester);
        output.emitError('Error decoding audio.');
        output.emitBuffering(true);
        await tester.pump();
        await tester.pump(const Duration(seconds: 4));
        expect(output.opened, isEmpty);
        expect(store.playbackError.value, isNull);

        if (action.startsWith('recovers')) {
          output.emitBuffering(false);
          output.emitPosition(const Duration(seconds: 31));
          await tester.pump();
          if (action == 'recovers then pauses') {
            output.emitPlaying(false);
          } else if (action == 'recovers then buffers again') {
            output.emitBuffering(true);
          }
          await tester.pump();
        } else if (action == 'switches channel') {
          store.nowPlaying = channel('http://receiver.test:8001/second');
        }
        await tester.pump(const Duration(seconds: 31));
        expect(
          output.opened,
          action == 'stays stalled'
              ? ['http://receiver.test:8001/first']
              : isEmpty,
        );
        expect(store.playbackError.value, isNull);
      });
    }
  });

  for (final scenario in [
    'continues',
    'stalls',
    'stops after advancing',
    'switches',
    'fatal error',
  ]) {
    testWidgets('audio decode error while playback $scenario', (tester) async {
      final output = TestPlayer();
      output.state = output.state.copyWith(
        playing: true,
        position: const Duration(seconds: 30),
      );
      final player = Player(platformPlayer: output);
      final controller = TestVideoController(player);
      final store = PlaylistStore(
        api: ApiClient(baseUrl: 'http://backend.test/api/v1'),
      );
      store.replacePlayer(player, controller);
      store.nowPlaying = channel('http://receiver.test:8001/first');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChannelPlayer(
              store: store,
              streamUrl: store.nowPlaying!.streamUrl,
            ),
          ),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        store.dispose();
        controller.notifier.dispose();
        await tester.idle();
      });

      // Bad packets must not exhaust retries or cover working playback.
      for (var i = 0; i < 4; i++) {
        output.emitError('Error decoding audio.');
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(output.opened, isEmpty);
      expect(store.playbackError.value, isNull);
      expect(find.text('Retry'), findsNothing);

      if (scenario == 'continues') {
        output.state = output.state.copyWith(
          position: const Duration(seconds: 33),
        );
      } else if (scenario == 'stops after advancing') {
        output.state = output.state.copyWith(
          playing: false,
          position: const Duration(seconds: 31),
        );
      } else if (scenario == 'switches') {
        store.nowPlaying = channel('http://receiver.test:8001/second');
      } else if (scenario == 'fatal error') {
        output.emitError('Could not open codec.');
        await tester.pump();
        expect(output.opened, hasLength(1));
      }
      await tester.pump(const Duration(seconds: 4));
      expect(
        output.opened,
        scenario == 'stalls' ||
                scenario == 'stops after advancing' ||
                scenario == 'fatal error'
            ? ['http://receiver.test:8001/first']
            : isEmpty,
      );
      expect(store.playbackError.value, isNull);
      expect(find.text('Retry'), findsNothing);
    });
  }

  for (final action in ['keep playing', 'stop', 'switch before rebuild']) {
    testWidgets('pending resolution respects $action', (tester) async {
      final output = TestPlayer();
      final player = Player(platformPlayer: output);
      final controller = TestVideoController(player);
      final store = PlaylistStore(
        api: ApiClient(baseUrl: 'http://backend.test/api/v1'),
      );
      store.replacePlayer(player, controller);
      store.nowPlaying = channel('http://receiver.test:8001/first');
      final pending = Completer<String>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChannelPlayer(
              store: store,
              streamUrl: store.nowPlaying!.streamUrl,
              resolveStreamUrl: () => pending.future,
            ),
          ),
        ),
      );
      expect(output.opened, isEmpty);

      if (action == 'stop') {
        store.stopPlayback();
      } else if (action == 'switch before rebuild') {
        store.nowPlaying = channel('http://receiver.test:8001/second');
      }
      // Complete before the frame which would update/dispose ChannelPlayer.
      pending.complete('http://receiver.test:17999/resolved');
      await tester.idle();

      expect(
        output.opened,
        action == 'keep playing'
            ? ['http://receiver.test:17999/resolved']
            : isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      store.dispose();
      controller.notifier.dispose();
      await tester.idle();
    });
  }
}
