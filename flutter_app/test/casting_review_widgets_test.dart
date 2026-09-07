import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:flutter_app/models/models.dart';
import 'package:flutter_app/screens/home_screen.dart';
import 'package:flutter_app/screens/home/widgets/home_search_bar.dart';
import 'package:flutter_app/screens/home/widgets/compact_watch_section.dart';
import 'package:flutter_app/services/casting/casting_controller.dart';
import 'package:flutter_app/services/playlist_store.dart';
import 'package:flutter_app/widgets/casting/cast_button.dart';
import 'package:flutter_app/widgets/casting/cast_player_surface.dart';
import 'casting_widgets_test.dart' show EmptyStore;
import 'casting_controller_test.dart' show LocalPlayback, Receiver, shield;

void main() {
  testWidgets('connected header announces the selected receiver', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final controller = (await tester.runAsync(() async {
      final controller = CastingController(
        local: LocalPlayback(),
        transports: [Receiver()],
      );
      await controller.connect(shield);
      return controller;
    }))!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CastButton(controller: controller)),
      ),
    );
    expect(find.bySemanticsLabel('Stream on TV · Living Room'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(controller.shutdown);
    controller.dispose();
    semantics.dispose();
  });
  testWidgets('tall Android phone keeps the casting home and remote player', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = SearchStore()
      ..selectedPlaylistId = 1
      ..nowPlaying = const Channel(
        id: 1,
        playlistId: 1,
        streamId: 'one',
        name: 'News',
        groupName: 'TV',
        streamUrl: 'https://example.test/live',
        logoUrl: '',
        epgChannelId: 'one',
        isFavorite: false,
      );
    final controller = (await tester.runAsync(() async {
      final controller = CastingController(
        local: LocalPlayback(),
        transports: [Receiver()],
      );
      await controller.connect(shield);
      return controller;
    }))!;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaylistStore>.value(value: store),
          ChangeNotifierProvider<CastingController>.value(value: controller),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();
    expect(find.byType(HomeSearchBar), findsOneWidget);
    expect(find.byType(CastButton), findsOneWidget);
    await tester.tap(find.byIcon(Icons.smart_display).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CastPlayerSurface), findsOneWidget);
    expect(find.text('EPG'), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.widget<HomeSearchBar>(find.byType(HomeSearchBar)).onTap();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'News');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'News results'));
    await tester.pumpAndSettle();
    expect(store.preservedPlayback, isFalse);
    expect(
      tester
          .widget<CompactWatchSection>(find.byType(CompactWatchSection))
          .currentPage,
      CompactWatchSection.viewChannels,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(controller.shutdown);
    controller.dispose();
    store.dispose();
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets(
    '320px home keeps header search selector and Cast at 1.5 text scale',
    (tester) async {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = EmptyStore();
      final controller = (await tester.runAsync(
        () async => CastingController(
          local: LocalPlayback()..id = null,
          transports: [Receiver()],
        ),
      ))!;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlaylistStore>.value(value: store),
            ChangeNotifierProvider<CastingController>.value(value: controller),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: const HomeScreen(),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(HomeSearchBar), findsOneWidget);
      expect(find.byType(CastButton), findsOneWidget);
      for (final icon in [Icons.folder_open, Icons.tv, Icons.smart_display]) {
        await tester.tap(find.byIcon(icon).first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(controller.shutdown);
      controller.dispose();
      store.dispose();
    },
  );
}

class SearchStore extends EmptyStore {
  bool? preservedPlayback;

  @override
  Future<void> ensureGlobalSearchData() async {}

  @override
  List<Group> get globalFilteredGroups => const [
    Group(
      name: 'News results',
      playlistId: 1,
      channelCount: 1,
      isFavorite: false,
    ),
  ];

  @override
  Future<void> selectGroup(
    String? group, {
    bool preservePlayback = false,
  }) async {
    preservedPlayback = preservePlayback;
    selectedGroup = group;
    notifyListeners();
  }
}
