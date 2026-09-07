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
