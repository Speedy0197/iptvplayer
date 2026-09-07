import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/models.dart';
import 'package:flutter_app/screens/home/tv/tv_home_view.dart';
import 'package:flutter_app/screens/home_screen.dart';
import 'package:flutter_app/screens/home/widgets/compact_watch_section.dart';
import 'package:flutter_app/services/api_client.dart';
import 'package:flutter_app/services/playlist_store.dart';
import 'package:provider/provider.dart';

void main() {
  late PlaylistStore store;
  late List<int> watched;
  late int exits;

  setUp(() {
    watched = [];
    exits = 0;
    store = PlaylistStore(api: _TvFixtureApi())
      ..playlists = [const Playlist(id: 1, name: 'My TV', type: 'm3u')]
      ..selectedPlaylistId = 1
      ..channels = List.generate(
        20,
        (i) => Channel(
          id: i,
          playlistId: 1,
          streamId: '',
          name: 'Channel ${i.toString().padLeft(2, '0')}',
          groupName: i < 10 ? 'News' : 'Sports',
          streamUrl: 'https://example.invalid/$i',
          logoUrl: '',
          epgChannelId: '',
          isFavorite: false,
        ),
      );
  });
  tearDown(() => store.dispose());

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(960, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Builder(
          builder: (context) => TvHomeView(
            store: store,
            preview: const ColoredBox(color: Colors.black),
            onWatch: (channel) async {
              watched.add(channel.id);
              await showDialog<void>(
                context: context,
                builder: (ctx) =>
                    const AlertDialog(content: Text('Playback route')),
              );
            },
            onSearch: () async {},
            onManagePlaylists: () async {},
            onLogout: () async {},
            onExit: () => exits++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('one OK opens playback and return keeps the channel cursor', (
    tester,
  ) async {
    await mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(watched, [2]);
    expect(find.text('Playback route'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(watched, [2, 2]);
  });

  testWidgets('Back moves from channels to groups to menu before exiting', (
    tester,
  ) async {
    await mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(exits, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Live TV'), findsOneWidget);
    expect(exits, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(exits, 1);
  });

  testWidgets('empty channels retain a path to the main menu', (tester) async {
    store.channels = [];
    await mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('Live TV'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'group browsing keeps playback and restores each channel cursor',
    (tester) async {
      await store.selectPlaylist(1);
      final playing = store.channels.first;
      store.nowPlaying = playing;
      await mount(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      // All channels -> Favorites -> News -> Sports.
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(store.selectedGroup, 'Sports');
      expect(store.nowPlaying?.streamUrl, playing.streamUrl);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(watched, [2]);
      expect(store.nowPlaying?.streamUrl, playing.streamUrl);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(watched, [2, 11]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('playlist chooser releases focus after its exit animation', (
    tester,
  ) async {
    await mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(watched, [0]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('OK on the same group retries a failed channel load', (
    tester,
  ) async {
    store.dispose();
    store = PlaylistStore(api: _TvFixtureApi(failFirstChannels: true))
      ..playlists = [const Playlist(id: 1, name: 'My TV', type: 'm3u')]
      ..selectedPlaylistId = 1;
    await mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(store.channels, isEmpty);
    expect(find.textContaining('Could not load channels'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(store.channels.length, 20);
    expect(find.textContaining('Could not load channels'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a channel revealed from Search initializes fullscreen switching',
    (tester) async {
      await mount(tester);
      final state = tester.state<TvHomeViewState>(find.byType(TvHomeView));
      store.nowPlaying = store.channels[5];
      state.reveal(channel: store.channels[5]);
      await tester.pumpAndSettle();
      state.playAdjacent(1);
      await tester.pumpAndSettle();
      expect(watched, [6]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'directional Android uses TV home below the compact breakpoint',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: store,
          child: MaterialApp(
            theme: ThemeData.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(navigationMode: NavigationMode.directional),
              child: child!,
            ),
            home: const HomeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TvHomeView), findsOneWidget);
      expect(find.byType(CompactWatchSection), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}

class _TvFixtureApi extends ApiClient {
  _TvFixtureApi({this.failFirstChannels = false})
    : super(baseUrl: 'http://fixture.invalid');
  final bool failFirstChannels;
  int channelRequests = 0;

  @override
  Future<dynamic> get(String path) async {
    if (path == '/playlists') {
      return [
        {'id': 1, 'name': 'My TV', 'type': 'm3u'},
      ];
    }
    if (path == '/favorites/channels' || path == '/favorites/groups') {
      return <dynamic>[];
    }
    if (path == '/playlists/1/channels') {
      if (failFirstChannels && channelRequests++ == 0) {
        throw StateError('fixture channel load failed');
      }
      return List.generate(
        20,
        (i) => {
          'id': i,
          'playlist_id': 1,
          'stream_id': '',
          'name': 'Channel ${i.toString().padLeft(2, '0')}',
          'group_name': i < 10 ? 'News' : 'Sports',
          'stream_url': 'https://example.invalid/$i',
          'logo_url': '',
          'epg_channel_id': '',
          'is_favorite': false,
        },
      );
    }
    throw StateError('Unexpected fixture path: $path');
  }
}
