import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/models.dart';
import 'package:flutter_app/screens/home/widgets/player_pane.dart';
import 'package:flutter_app/screens/home/widgets/compact_mini_player_bar.dart';
import 'package:flutter_app/services/api_client.dart';
import 'package:flutter_app/services/playlist_store.dart';
import 'package:media_kit/media_kit.dart' hide Playlist;
import 'channel_player_resolution_test.dart'
    show TestPlayer, TestVideoController, channel;

class RecordingStore extends PlaylistStore {
  RecordingStore() : super(api: ApiClient(baseUrl: 'https://fixture.invalid'));
  int removed = 0;
  int? receiver;
  @override
  bool isTimerScheduled(EpgEntry entry) => true;
  @override
  Future<void> removeEpgTimer(EpgEntry entry, {int? playlistId}) async {
    removed++;
    receiver = playlistId;
  }
}

void main() {
  late RecordingStore store;
  late TestPlayer engine;
  late TestVideoController controller;
  setUp(() {
    engine = TestPlayer();
    engine.state = engine.state.copyWith(
      playing: true,
      position: const Duration(seconds: 30),
    );
    final player = Player(platformPlayer: engine);
    controller = TestVideoController(player);
    store = RecordingStore()
      ..nowPlaying = channel('https://fixture.invalid/live')
      ..replacePlayer(player, controller);
    store.playlists = [const Playlist(id: 1, name: 'Receiver', type: 'vuplus')];
    store.selectedPlaylistId = 1;
    final now = DateTime.now();
    store.epgEntries = [
      EpgEntry(
        channelEpgId: 'one',
        startTime: now.subtract(const Duration(minutes: 20)),
        endTime: now.add(const Duration(minutes: 40)),
        title: 'Current programme',
        description: 'Current details',
      ),
      EpgEntry(
        channelEpgId: 'one',
        startTime: now.add(const Duration(minutes: 40)),
        endTime: now.add(const Duration(minutes: 70)),
        title: 'Next programme',
        description: 'Next details',
      ),
    ];
  });
  tearDown(() {
    store.dispose();
    controller.notifier.dispose();
  });

  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(900, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    await tester.pump();
  }

  testWidgets(
    'mini player reports playback state and uses the existing player',
    (tester) async {
      await mount(
        tester,
        CompactMiniPlayerBar(
          store: store,
          channel: store.nowPlaying!,
          iosCompact: false,
          onTap: () {},
          onStop: () {},
        ),
      );
      expect(find.textContaining('Playing'), findsOneWidget);
      expect(find.byTooltip('Pause'), findsOneWidget);
      engine.emitPlaying(false);
      await tester.pumpAndSettle();
      expect(find.textContaining('Paused'), findsOneWidget);
      expect(find.byTooltip('Play'), findsOneWidget);
      await tester.tap(find.byTooltip('Play'));
      expect(engine.plays, 1);
      engine.emitBuffering(true);
      await tester.pumpAndSettle();
      expect(find.textContaining('Buffering'), findsOneWidget);
      store.playbackError.value =
          'A raw https://fixture.invalid/private-secret failure';
      await tester.pump();
      expect(find.textContaining('Unavailable'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.play_arrow),
            )
            .onPressed,
        isNull,
      );
      expect(engine.opened, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('guide emphasizes current progress and the next programme', (
    tester,
  ) async {
    await mount(tester, PlayerPane(store: store));
    expect(find.text('On now'), findsOneWidget);
    expect(find.text('Up next'), findsOneWidget);
    expect(find.textContaining('40 min remaining'), findsOneWidget);
    final progress = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(progress.value, closeTo(1 / 3, .01));
    await tester.tap(find.text('Current programme'));
    await tester.pumpAndSettle();
    expect(find.text('Current details'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'cancellation requires confirmation and preserves receiver source',
    (tester) async {
      await mount(tester, PlayerPane(store: store));
      await tester.tap(find.byTooltip('Cancel recording').first);
      await tester.pumpAndSettle();
      expect(store.removed, 0);
      expect(find.text('Keep recording'), findsOneWidget);
      await tester.tap(find.text('Keep recording'));
      await tester.pumpAndSettle();
      expect(store.removed, 0);
      await tester.tap(find.byTooltip('Cancel recording').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel recording'));
      await tester.pumpAndSettle();
      expect(store.removed, 1);
      expect(store.receiver, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
