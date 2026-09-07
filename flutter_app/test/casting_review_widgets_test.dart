import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:flutter_app/models/models.dart';
import 'package:flutter_app/screens/home_screen.dart';
import 'package:flutter_app/screens/home/widgets/player_pane.dart';
import 'package:flutter_app/screens/home/widgets/home_search_bar.dart';
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
  testWidgets(
    'tall Android phone shows actual remote PlayerPane without overflow',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(390, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = EmptyStore()
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
        ChangeNotifierProvider<CastingController>.value(
          value: controller,
          child: MaterialApp(
            home: Scaffold(body: PlayerPane(store: store)),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(CastPlayerSurface), findsOneWidget);
      expect(find.text('EPG'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(controller.shutdown);
      controller.dispose();
      store.dispose();
      debugDefaultTargetPlatformOverride = null;
    },
  );
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
