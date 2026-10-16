import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/config/app_theme.dart';
import 'package:flutter_app/models/models.dart';
import 'package:flutter_app/screens/home_screen.dart';
import 'package:flutter_app/screens/login_screen.dart';
import 'package:flutter_app/screens/register_screen.dart';
import 'package:flutter_app/screens/tv_pairing_screen.dart';
import 'package:flutter_app/services/auth_store.dart';
import 'package:flutter_app/services/playlist_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' hide Playlist;
import 'package:provider/provider.dart';

import 'browsing_ui_test.dart' show FixtureApi;
import 'channel_player_resolution_test.dart'
    show TestPlayer, TestVideoController;
import 'tv_pairing_screen_test.dart' show PairingApi;

// Optional local capture output uses synthetic accounts, sources and channels.
// CI runs the same layout assertions without system fonts or file writes.
const captureDir = String.fromEnvironment('UI_CAPTURE_DIR');
const captureFont = String.fromEnvironment('UI_CAPTURE_FONT');
const captureIcons = String.fromEnvironment('UI_CAPTURE_ICONS');

class LayoutApi extends FixtureApi {
  LayoutApi() : super(channelCount: 18);
  @override
  Future<dynamic> get(String path) async {
    if (path.contains('/groups')) {
      return [
        {'name': 'News', 'playlist_id': 1, 'channel_count': 18},
        {'name': 'Documentaries', 'playlist_id': 1, 'channel_count': 12},
        {'name': 'Sports', 'playlist_id': 1, 'channel_count': 8},
      ];
    }
    if (path == '/favorites/channels') {
      return [
        {
          'id': 10,
          'playlist_id': 1,
          'name': 'Sample News 00',
          'group_name': 'News',
          'is_favorite': true,
        },
        {
          'id': 11,
          'playlist_id': 1,
          'name': 'Sample News 01',
          'group_name': 'News',
          'is_favorite': true,
        },
      ];
    }
    return super.get(path);
  }
}

List<EpgEntry> sampleGuide() {
  final now = DateTime.now();
  return [
    EpgEntry(
      channelEpgId: 'news',
      startTime: now.subtract(const Duration(minutes: 20)),
      endTime: now.add(const Duration(minutes: 40)),
      title: 'The evening report: news and stories from around the world',
      description: 'Headlines, local stories and the weather forecast.',
    ),
    EpgEntry(
      channelEpgId: 'news',
      startTime: now.add(const Duration(minutes: 40)),
      endTime: now.add(const Duration(minutes: 70)),
      title: 'Around the world',
      description: 'Today’s stories from around the world.',
    ),
  ];
}

class LayoutStore extends PlaylistStore {
  LayoutStore() : super(api: LayoutApi());
  @override
  Future<List<EpgEntry>> loadChannelEpg(Channel channel) async => sampleGuide();
}

void main() {
  setUpAll(() async {
    if (captureFont.isNotEmpty) {
      final loader = FontLoader('PreviewSans')
        ..addFont(
          Future.value(
            ByteData.sublistView(await File(captureFont).readAsBytes()),
          ),
        );
      await loader.load();
    }
    if (captureIcons.isNotEmpty) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(
            ByteData.sublistView(await File(captureIcons).readAsBytes()),
          ),
        );
      await loader.load();
    }
  });

  Future<void> mount(
    WidgetTester tester,
    Widget screen, {
    required Size size,
    double scale = 1,
    bool tv = false,
    required PlaylistStore store,
    required AuthStore auth,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    var theme = createStreamPilotTheme();
    if (captureFont.isNotEmpty) {
      theme = theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'PreviewSans'),
        primaryTextTheme: theme.primaryTextTheme.apply(
          fontFamily: 'PreviewSans',
        ),
      );
    }
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaylistStore>.value(value: store),
          ChangeNotifierProvider<AuthStore>.value(value: auth),
        ],
        child: MaterialApp(
          theme: theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              navigationMode: tv
                  ? NavigationMode.directional
                  : NavigationMode.traditional,
            ),
            child: RepaintBoundary(
              key: const ValueKey('ui-capture'),
              child: child!,
            ),
          ),
          home: screen,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
  }

  Future<void> capture(WidgetTester tester, String name) async {
    expect(tester.takeException(), isNull);
    if (captureDir.isEmpty) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('ui-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final output = File('$captureDir/$name.png');
      await output.parent.create(recursive: true);
      await output.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final layout in [
    ('phone', const Size(390, 844), 1.0, TargetPlatform.iOS),
    ('phone-large-text', const Size(320, 700), 1.6, TargetPlatform.iOS),
    ('tablet', const Size(768, 1024), 1.0, TargetPlatform.iOS),
    ('desktop-minimum', const Size(901, 640), 1.6, TargetPlatform.macOS),
    ('desktop', const Size(1440, 900), 1.0, TargetPlatform.macOS),
    ('tv', const Size(1280, 720), 1.0, TargetPlatform.android),
    ('tv-large-text', const Size(1280, 720), 1.6, TargetPlatform.android),
  ]) {
    testWidgets(
      '${layout.$1} keeps browsing and playback readable',
      (tester) async {
        final store = LayoutStore();
        final auth = AuthStore(api: LayoutApi())..initializing = false;
        final engine = TestPlayer();
        engine.state = engine.state.copyWith(
          playing: true,
          position: const Duration(seconds: 30),
        );
        final player = Player(platformPlayer: engine);
        final video = TestVideoController(player);
        store.replacePlayer(player, video);
        addTearDown(store.dispose);
        addTearDown(auth.dispose);
        addTearDown(video.notifier.dispose);
        await mount(
          tester,
          const HomeScreen(),
          size: layout.$2,
          scale: layout.$3,
          tv: layout.$1.startsWith('tv'),
          store: store,
          auth: auth,
        );
        store.nowPlaying = store.channels.first;
        final now = DateTime.now();
        store.epgEntries = [
          EpgEntry(
            channelEpgId: 'news',
            startTime: now.subtract(const Duration(minutes: 20)),
            endTime: now.add(const Duration(minutes: 40)),
            title: 'The evening report',
            description: 'Headlines, local stories and the weather forecast.',
          ),
          EpgEntry(
            channelEpgId: 'news',
            startTime: now.add(const Duration(minutes: 40)),
            endTime: now.add(const Duration(minutes: 70)),
            title: 'Around the world',
            description: 'Today’s stories from around the world.',
          ),
        ];
        store.setSearchQuery('');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await capture(tester, '${layout.$1}-watch');
        if (layout.$1.startsWith('phone')) {
          store.groups = [
            const Group(
              name: 'Dazn Germany Events (Auto Update Daily)',
              playlistId: 1,
              channelCount: 100,
              isFavorite: false,
            ),
            const Group(
              name: 'Germany HEVC and RAW Multi Audio',
              playlistId: 1,
              channelCount: 102,
              isFavorite: false,
            ),
            ...store.groups,
            ...List.generate(
              12,
              (i) => Group(
                name: 'Country ${i + 1}',
                playlistId: 1,
                channelCount: 312,
                isFavorite: false,
              ),
            ),
          ];
          store.setSearchQuery('');
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Switch source'));
          await tester.pumpAndSettle();
          await capture(tester, '${layout.$1}-source-picker');
          await tester.tap(find.byTooltip('Close picker'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Select group'));
          await tester.pumpAndSettle();
          await capture(tester, '${layout.$1}-group-picker');
          await tester.enterText(find.byType(TextField), 'dazn');
          await tester.pumpAndSettle();
          await capture(tester, '${layout.$1}-group-filtered');
          await tester.tap(find.byTooltip('Close picker'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Search'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextFormField), 'News');
          await tester.testTextInput.receiveAction(TextInputAction.search);
          await tester.pumpAndSettle();
          await capture(tester, '${layout.$1}-search');
          await tester.tap(find.byTooltip('Close search'));
          await tester.pumpAndSettle();
        } else if (layout.$1.startsWith('desktop')) {
          await tester.tap(find.byTooltip('Select group'));
          await tester.pumpAndSettle();
          await capture(tester, '${layout.$1}-group-picker');
          await tester.tap(find.text('All channels').last);
          await tester.pumpAndSettle();
        }
        if (!layout.$1.startsWith('tv')) {
          await tester.tap(find.text('Favorites').last);
          await tester.pumpAndSettle();
          await capture(tester, '${layout.$1}-favorites');
          await tester.tap(find.text('Sources').last);
          await tester.pumpAndSettle();
          await capture(tester, '${layout.$1}-sources');
        }
      },
      variant: TargetPlatformVariant.only(layout.$4),
    );
  }

  testWidgets(
    'phone account and pairing cards fit with large text',
    (tester) async {
      final api = PairingApi();
      final auth = AuthStore(api: api)..initializing = false;
      final store = PlaylistStore(api: LayoutApi());
      addTearDown(auth.dispose);
      addTearDown(store.dispose);
      for (final screen in [const LoginScreen(), const RegisterScreen()]) {
        await mount(
          tester,
          screen,
          size: const Size(320, 700),
          scale: 1.6,
          store: store,
          auth: auth,
        );
        await capture(
          tester,
          screen is LoginScreen ? 'phone-login' : 'phone-register',
        );
      }
      auth.token = 'synthetic-session';
      auth.username = 'viewer@example.test';
      await mount(
        tester,
        const TvPairingScreen(
          pairingToken: 'abcdef0123456789abcdef0123456789abcdef0123456789',
        ),
        size: const Size(390, 844),
        scale: 1.6,
        store: store,
        auth: auth,
      );
      await capture(tester, 'phone-approve-tv');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
