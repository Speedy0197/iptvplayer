import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:flutter_app/screens/home_screen.dart';
import 'package:flutter_app/screens/home/widgets/home_search_bar.dart';
import 'package:flutter_app/services/api_client.dart';
import 'package:flutter_app/services/playlist_store.dart';
import 'package:flutter_app/models/models.dart';
import 'package:flutter_app/services/casting/cast_transport.dart';
import 'package:flutter_app/services/casting/casting_controller.dart';
import 'package:flutter_app/widgets/casting/cast_button.dart';
import 'package:flutter_app/widgets/casting/cast_player_surface.dart';

import 'casting_controller_test.dart' show LocalPlayback, Receiver, shield;

class EmptyStore extends PlaylistStore {
  EmptyStore() : super(api: ApiClient(baseUrl: 'http://backend.test'));
  @override
  Future<void> bootstrap() async {}
}

void main() {
  for (final width in [320.0, 390.0, 430.0]) {
    testWidgets('actual home keeps search and page selector at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
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
          child: MaterialApp(theme: ThemeData.dark(), home: const HomeScreen()),
        ),
      );
      await tester.pump();
      expect(find.byType(HomeSearchBar), findsOneWidget);
      expect(find.byType(CastButton), findsOneWidget);
      for (final entry in {
        'Groups': Icons.folder_open,
        'Channels': Icons.tv,
        'Player': Icons.smart_display,
      }.entries) {
        await tester.tap(find.byIcon(entry.value).first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text(entry.key), findsWidgets);
      }
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(CastButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(find.text('Stream on TV'), findsOneWidget);
      expect(find.text('Living Room'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(controller.shutdown);
      controller.dispose();
      store.dispose();
    });
  }

  testWidgets('remote surface waits for actual playing status', (tester) async {
    final pair = (await tester.runAsync(() async {
      final receiver = Receiver()..autoConfirm = false;
      return (
        receiver: receiver,
        controller: CastingController(
          local: LocalPlayback(),
          transports: [receiver],
        ),
      );
    }))!;
    final receiver = pair.receiver;
    final controller = pair.controller;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CastPlayerSurface(controller: controller)),
      ),
    );
    late Future<void> connecting;
    await tester.runAsync(() async {
      connecting = controller.connect(shield);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(receiver.loaded, ['one']);
    expect(find.text('Playing on Living Room'), findsNothing);
    expect(find.text('Starting on Living Room…'), findsOneWidget);
    await tester.runAsync(() async {
      receiver.statusEvents.add(
        const CastStatus(
          state: CastPlaybackState.playing,
          device: shield,
          mediaId: 'one',
        ),
      );
      await connecting;
    });
    await tester.pump();
    expect(find.text('Playing on Living Room'), findsOneWidget);
    await tester.runAsync(controller.shutdown);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('actual player retains EPG and mini player while casting', (
    tester,
  ) async {
    if (const bool.fromEnvironment('CAPTURE_CAST_UI')) {
      await tester.runAsync(() async {
        const dir = String.fromEnvironment(
          'FLUTTER_TEST_FONT_DIR',
          defaultValue:
              '../.superpowers/toolchain/flutter/bin/cache/artifacts/material_fonts',
        );
        for (final font in {
          'Roboto': 'roboto-regular.ttf',
          'MaterialIcons': 'MaterialIcons-Regular.otf',
        }.entries) {
          final loader = FontLoader(font.key)
            ..addFont(
              File(
                '$dir/${font.value}',
              ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
            );
          await loader.load();
        }
      });
    }
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = EmptyStore()
      ..nowPlaying = const Channel(
        id: 1,
        playlistId: 1,
        streamId: 'one',
        name: 'BBC One HD',
        groupName: 'Entertainment',
        streamUrl: 'https://example.test/live.m3u8',
        logoUrl: '',
        epgChannelId: 'one',
        isFavorite: false,
      );
    store.epgEntries = [
      EpgEntry(
        channelEpgId: 'one',
        title: 'Evening programme',
        description:
            'Programme information stays available while you watch on TV.',
        startTime: DateTime.now().subtract(const Duration(minutes: 10)),
        endTime: DateTime.now().add(const Duration(minutes: 20)),
      ),
    ];
    final controller = (await tester.runAsync(() async {
      final controller = CastingController(
        local: LocalPlayback(),
        transports: [Receiver()],
      );
      await controller.connect(shield);
      return controller;
    }))!;
    final captureKey = GlobalKey();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaylistStore>.value(value: store),
          ChangeNotifierProvider<CastingController>.value(value: controller),
        ],
        child: RepaintBoundary(
          key: captureKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(brightness: Brightness.dark, fontFamily: 'Roboto')
                .copyWith(
                  scaffoldBackgroundColor: const Color(0xFF0D1117),
                  colorScheme: ColorScheme.fromSeed(
                    seedColor: const Color(0xFF1E88E5),
                    brightness: Brightness.dark,
                  ),
                  appBarTheme: const AppBarTheme(
                    backgroundColor: Color(0xFF0B1220),
                  ),
                ),
            home: const HomeScreen(),
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.smart_display).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CastPlayerSurface), findsOneWidget);
    expect(find.text('EPG'), findsOneWidget);
    expect(find.text('Evening programme'), findsOneWidget);
    expect(find.text('Playing on Living Room'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CAPTURE_CAST_UI')) {
      await tester.runAsync(() async {
        final boundary =
            captureKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final snapshot = await boundary.toImage(pixelRatio: 2);
        final data = await snapshot.toByteData(format: ui.ImageByteFormat.png);
        final file = File('../.superpowers/preview/casting-home.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        snapshot.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(controller.shutdown);
    controller.dispose();
    store.dispose();
  });
}
