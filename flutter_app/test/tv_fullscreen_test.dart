import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/models/models.dart' show Channel;
import 'package:flutter_app/services/api_client.dart';
import 'package:flutter_app/services/playlist_store.dart';
import 'package:flutter_app/widgets/channel_player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  late _TestPlayer engine;
  late PlaylistStore store;
  late StateSetter update;
  late int previewGeneration;
  late int closed;

  setUp(() {
    engine = _TestPlayer();
    final player = Player(platformPlayer: engine);
    store = PlaylistStore(api: ApiClient(baseUrl: 'http://fixture.invalid'))
      ..nowPlaying = const Channel(
        id: 1,
        playlistId: 1,
        streamId: '',
        name: 'Fixture channel',
        groupName: '',
        streamUrl: 'https://example.invalid/channel',
        logoUrl: '',
        epgChannelId: '',
        isFavorite: false,
      )
      ..replacePlayer(player, _TestVideoController(player));
    previewGeneration = 0;
    closed = 0;
  });
  tearDown(() => store.dispose());

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(960, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(navigationMode: NavigationMode.directional),
          child: child!,
        ),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return ChannelPlayer(
                key: ValueKey(previewGeneration),
                store: store,
                streamUrl: 'https://example.invalid/channel',
                fullscreenRequest: previewGeneration == 0 ? 1 : 0,
                previewFocusable: false,
                onFullscreenClosed: () => closed++,
              );
            },
          ),
        ),
      ),
    );
    // A stalled stream animates forever, so settle only route transitions.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets(
    'fullscreen opens immediately and Back first dismisses controls',
    (tester) async {
      await mount(tester);
      expect(find.byTooltip('Exit Fullscreen'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 400));
      expect(closed, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 400));
      expect(closed, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'fullscreen Retry works after the preview is recreated',
    (tester) async {
      engine.failOpen = true;
      await mount(tester);
      expect(find.text('Retry'), findsOneWidget);
      update(() => previewGeneration++);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final attempts = engine.opens;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(engine.opens, greaterThan(attempts));
      // A late successful playing event also removes the fullscreen error.
      engine.recover();
      await tester.pump();
      expect(find.text('Retry'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}

class _TestPlayer extends PlatformPlayer {
  _TestPlayer() : super(configuration: const PlayerConfiguration());
  bool failOpen = false;
  int opens = 0;
  void recover() => playingController.add(true);
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opens++;
    if (failOpen) throw StateError('fixture stream failed');
  }

  @override
  Future<void> stop() async {}
}

/// No native video surface is required to exercise navigation and playback
/// events; the media engine above provides the real stream contract.
class _TestVideoController implements VideoController {
  _TestVideoController(this.player);
  @override
  final Player player;
  @override
  final platform = Completer<PlatformVideoController>();
  @override
  final notifier = ValueNotifier<PlatformVideoController?>(null);
  @override
  final id = ValueNotifier<int?>(null);
  @override
  final rect = ValueNotifier<Rect?>(null);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
