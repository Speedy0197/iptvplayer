import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:media_kit/media_kit.dart' hide Playlist;
import 'package:flutter_app/screens/home_screen.dart';
import 'package:flutter_app/services/api_client.dart';
import 'package:flutter_app/services/playlist_store.dart';
import 'package:flutter_app/widgets/channel_player.dart';
import 'channel_player_resolution_test.dart'
    show TestPlayer, TestVideoController;

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://fixture.invalid');
  @override
  Future<dynamic> get(String path) async {
    if (path == '/playlists') {
      return [
        {'id': 1, 'name': 'Home source', 'type': 'm3u'},
        {'id': 2, 'name': 'Other source', 'type': 'm3u'},
      ];
    }
    if (path.contains('/channels') && !path.startsWith('/favorites')) {
      return ['A', 'B']
          .map(
            (name) => {
              'id': name == 'A' ? 1 : 2,
              'playlist_id': path.contains('/2/') ? 2 : 1,
              'name': 'Channel $name',
              'group_name': 'News',
              'stream_url': 'https://fixture.invalid/$name',
              'epg_channel_id': '',
              'is_favorite': false,
            },
          )
          .toList();
    }
    return <dynamic>[];
  }
}

void main() {
  late PlaylistStore store;
  late TestPlayer engine;
  late TestVideoController controller;
  setUp(() {
    engine = TestPlayer();
    final player = Player(platformPlayer: engine);
    controller = TestVideoController(player);
    store = PlaylistStore(api: _Api())..replacePlayer(player, controller);
  });
  tearDown(() {
    store.dispose();
    controller.notifier.dispose();
  });
  Future<void> mount(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: store,
        child: MaterialApp(theme: ThemeData.dark(), home: const HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.idle();
    });
  }

  Future<void> startA(WidgetTester tester) async {
    await tester.tap(find.text('Channel A'));
    await tester.pump();
    await tester.pump();
    engine.emitPosition(const Duration(seconds: 30));
    engine.emitPlaying(true);
    await tester.pumpAndSettle();
    expect(engine.opened, ['https://fixture.invalid/A']);
  }

  testWidgets(
    'A then browsing then B opens B and retains a single player state',
    (tester) async {
      await mount(tester);
      await startA(tester);
      final state = tester.state(find.byType(ChannelPlayer));
      await tester.tap(find.text('Back to channels'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Channel B'));
      await tester.pump();
      await tester.pump();
      expect(engine.opened, [
        'https://fixture.invalid/A',
        'https://fixture.invalid/B',
      ]);
      expect(
        identical(state, tester.state(find.byType(ChannelPlayer))),
        isTrue,
      );
    },
  );
  testWidgets('paused playback stays paused after browsing and reopening', (
    tester,
  ) async {
    await mount(tester);
    await startA(tester);
    engine.emitPlaying(false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Back to channels'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Paused').first);
    await tester.pumpAndSettle();
    expect(engine.opened, ['https://fixture.invalid/A']);
    expect(engine.state.playing, isFalse);
    expect(engine.plays, 0);
  });
  testWidgets(
    'errors while browsing reach the mini player and Retry retains recovery',
    (tester) async {
      await mount(tester);
      await startA(tester);
      await tester.tap(find.text('Back to channels'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        engine.emitError('HTTP 403 https://fixture.invalid/private-token');
        await tester.pump();
        await tester.pump();
      }
      expect(store.playbackError.value, isNotNull);
      expect(find.textContaining('Unavailable'), findsOneWidget);
      await tester.tap(find.textContaining('Unavailable'));
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
      final attempts = engine.opened.length;
      await tester.ensureVisible(find.text('Retry'));
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();
      expect(engine.opened.length, attempts + 1);
    },
  );
  testWidgets(
    'source and destination changes keep the same subscriptions and player state',
    (tester) async {
      await mount(tester);
      await startA(tester);
      final state = tester.state(find.byType(ChannelPlayer));
      await tester.tap(find.text('Back to channels'));
      await tester.pumpAndSettle();
      await store.selectPlaylist(2, preservePlayback: true);
      await tester.pumpAndSettle();
      for (final destination in ['Favorites', 'Sources', 'Watch']) {
        await tester.tap(find.text(destination).last);
        await tester.pumpAndSettle();
        expect(find.byType(ChannelPlayer, skipOffstage: false), findsOneWidget);
        expect(
          identical(
            state,
            tester.state(find.byType(ChannelPlayer, skipOffstage: false)),
          ),
          isTrue,
        );
      }
      engine.emitBuffering(true);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Buffering'), findsOneWidget);
      expect(engine.opened, ['https://fixture.invalid/A']);
    },
  );
}
