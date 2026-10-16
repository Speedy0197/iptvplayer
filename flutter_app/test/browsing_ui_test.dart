import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/models.dart';
import 'package:flutter_app/screens/home_screen.dart';
import 'package:flutter_app/screens/home/widgets/favorites_view.dart';
import 'package:flutter_app/screens/home/widgets/channels_pane.dart';
import 'package:flutter_app/screens/home/widgets/playlist_management_view.dart';
import 'package:flutter_app/services/api_client.dart';
import 'package:flutter_app/services/playlist_store.dart';
import 'package:provider/provider.dart';
import 'package:media_kit/media_kit.dart' hide Playlist;
import 'channel_player_resolution_test.dart'
    show TestPlayer, TestVideoController;

class FixtureApi extends ApiClient {
  final bool empty;
  final int channelCount;
  FixtureApi({this.empty = false, this.channelCount = 1})
    : super(baseUrl: 'https://fixture.invalid');
  @override
  Future<dynamic> get(String path) async {
    if (path == '/playlists') {
      return empty
          ? []
          : [
              {'id': 1, 'name': 'Home TV', 'type': 'm3u'},
              {'id': 2, 'name': 'Travel TV', 'type': 'm3u'},
            ];
    }
    if (path.startsWith('/favorites/')) return <dynamic>[];
    if (path.contains('/channels')) {
      return List.generate(
        channelCount,
        (index) => {
          'id': 10 + index,
          'playlist_id': path.contains('/2/') ? 2 : 1,
          'name': channelCount == 1
              ? 'Sample News'
              : 'Sample News ${index.toString().padLeft(2, '0')}',
          'group_name': 'News',
          'stream_url': 'https://fixture.invalid/channel',
          'is_favorite': false,
        },
      );
    }
    return <dynamic>[];
  }
}

void main() {
  late PlaylistStore store;
  setUp(() => store = PlaylistStore(api: FixtureApi()));
  tearDown(() => store.dispose());
  Future<void> mount(
    WidgetTester tester,
    Widget widget, {
    Size size = const Size(390, 844),
    double scale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: store,
        child: MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(body: widget),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Watch opens in channels with source and group selectors', (
    tester,
  ) async {
    await mount(tester, const HomeScreen());
    expect(find.text('Sample News'), findsOneWidget);
    expect(find.byTooltip('Switch source'), findsOneWidget);
    expect(find.byTooltip('Select group'), findsOneWidget);
    expect(find.text('Sources'), findsOneWidget);
    expect(find.text('Logout'), findsNothing);
  });
  testWidgets('source selection keeps playback and returning keeps the group', (
    tester,
  ) async {
    await mount(tester, const HomeScreen());
    final playing = store.channels.first;
    final output = TestPlayer();
    output.state = output.state.copyWith(
      playing: true,
      position: const Duration(seconds: 30),
    );
    final player = Player(platformPlayer: output);
    final controller = TestVideoController(player);
    addTearDown(controller.notifier.dispose);
    store.replacePlayer(player, controller);
    store.nowPlaying = playing;
    await tester.tap(find.byTooltip('Switch source'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Travel TV').last);
    await tester.pumpAndSettle();
    expect(store.selectedPlaylistId, 2);
    expect(store.nowPlaying, playing);
    await store.selectGroup('News', preservePlayback: true);
    await tester.tap(find.text('Sources'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Watch').last);
    await tester.pumpAndSettle();
    expect(store.selectedGroup, 'News');
    expect(store.nowPlaying, playing);
    expect(
      find.descendant(
        of: find.byType(ChannelsPane),
        matching: find.text('Sample News'),
      ),
      findsOneWidget,
    );
  });
  testWidgets(
    'Favorites channels start near the heading when groups are empty',
    (tester) async {
      store.playlists = [const Playlist(id: 1, name: 'Home TV', type: 'm3u')];
      store.favoriteChannels = [
        Channel.fromJson({
          'id': 1,
          'playlist_id': 1,
          'name': 'Saved News',
          'group_name': 'News',
          'is_favorite': true,
        }),
      ];
      await mount(
        tester,
        FavoritesView(
          store: store,
          compact: true,
          withPlayer: false,
          onGroupTap: (_) async {},
          onChannelTap: (_) async {},
        ),
      );
      expect(tester.getTopLeft(find.text('Saved News')).dy, lessThan(250));
      expect(find.text('Home TV · News'), findsOneWidget);
    },
  );
  testWidgets('Sources show refresh date and persistent inline completion', (
    tester,
  ) async {
    store.playlists = [
      const Playlist(
        id: 1,
        name: 'Home TV',
        type: 'm3u',
        lastRefreshed: '2026-10-12T12:00:00Z',
      ),
    ];
    await mount(
      tester,
      PlaylistManagementView(
        store: store,
        onCreate: () {},
        onEdit: (_) {},
        onRefresh: (_) async {},
        onDelete: (_) {},
      ),
    );
    expect(find.textContaining('Last updated'), findsOneWidget);
    await tester.tap(find.byTooltip('Refresh source'));
    await tester.pumpAndSettle();
    expect(find.text('Source updated'), findsOneWidget);
  });
  testWidgets('narrow Watch supports large text without overflow', (
    tester,
  ) async {
    await mount(
      tester,
      const HomeScreen(),
      size: const Size(320, 700),
      scale: 1.6,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Sources'), findsOneWidget);
  });
  testWidgets('search has explicit close and type and source filters', (
    tester,
  ) async {
    await mount(tester, const HomeScreen());
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Close search'), findsOneWidget);
    expect(find.text('Channels only'), findsOneWidget);
    expect(find.text('All sources'), findsOneWidget);
    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  });
  testWidgets('empty Watch offers a direct action to Sources', (tester) async {
    store.dispose();
    store = PlaylistStore(api: FixtureApi(empty: true));
    await mount(tester, const HomeScreen());
    expect(find.text('Add a source to start watching'), findsOneWidget);
    await tester.tap(find.text('Add source'));
    await tester.pumpAndSettle();
    expect(find.text('Add your first source'), findsOneWidget);
  });

  testWidgets('Watch channel scroll position survives changing destinations', (
    tester,
  ) async {
    store.dispose();
    store = PlaylistStore(api: FixtureApi(channelCount: 40));
    await mount(tester, const HomeScreen());
    final list = find.descendant(
      of: find.byType(ChannelsPane),
      matching: find.byType(ListView),
    );
    await tester.drag(list, const Offset(0, -700));
    await tester.pumpAndSettle();
    final offset = tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)),
        )
        .position
        .pixels;
    expect(offset, greaterThan(500));
    await tester.tap(find.text('Sources'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Watch').last);
    await tester.pumpAndSettle();
    final restored = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(ChannelsPane),
            matching: find.byType(Scrollable),
          ),
        )
        .position
        .pixels;
    expect(restored, closeTo(offset, 1));
  });

  testWidgets('desktop minimum width and large text fit the header and panes', (
    tester,
  ) async {
    await mount(
      tester,
      const HomeScreen(),
      size: const Size(900, 700),
      scale: 1.6,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('StreamPilot'), findsOneWidget);
    expect(find.text('Sources'), findsOneWidget);
  });

  testWidgets('search type and source filters narrow real results', (
    tester,
  ) async {
    await mount(tester, const HomeScreen());
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'News');
    await tester.pumpAndSettle();
    expect(find.text('Sample News'), findsNWidgets(2));
    await tester.ensureVisible(find.text('Channels only'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Channels only'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'News'), findsNothing);
    await tester.ensureVisible(find.byTooltip('Filter search by source'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Filter search by source'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Travel TV').last);
    await tester.pumpAndSettle();
    expect(find.text('Sample News'), findsOneWidget);
  });
  testWidgets('search channel opens the player and returns to its browser', (
    tester,
  ) async {
    final engine = TestPlayer();
    engine.state = engine.state.copyWith(
      playing: true,
      position: const Duration(seconds: 30),
    );
    final player = Player(platformPlayer: engine);
    final video = TestVideoController(player);
    store.replacePlayer(player, video);
    addTearDown(video.notifier.dispose);
    await mount(tester, const HomeScreen());
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Sample');
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(Dialog),
            matching: find.text('Sample News'),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Back to channels'), findsOneWidget);
    expect(store.nowPlaying?.name, 'Sample News');
    await tester.tap(find.text('Back to channels'));
    await tester.pumpAndSettle();
    expect(store.nowPlaying?.name, 'Sample News');
    expect(find.byTooltip('Select group'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
