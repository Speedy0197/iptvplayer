import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/models/models.dart';
import 'package:flutter_app/screens/home/widgets/channel_action_sheet.dart';
import 'package:flutter_app/screens/home/widgets/channels_pane.dart';
import 'package:flutter_app/services/api_client.dart';
import 'package:flutter_app/services/playlist_store.dart';

const _group = 'Dazn Germany Events';
const _longName =
    'Imola | Rennen 1 - Formula Regional European Championship - '
    'Live coverage including qualifying, interviews and the podium ceremony';

Channel _channel(int id, String name) => Channel(
  id: id,
  playlistId: 1,
  streamId: '',
  name: name,
  groupName: _group,
  streamUrl: '',
  logoUrl: '',
  epgChannelId: '',
  isFavorite: false,
);

class _FavoritesApi extends ApiClient {
  _FavoritesApi() : super(baseUrl: 'http://localhost');

  Map<String, dynamic>? savedFavorite;
  Completer<dynamic>? pendingFavorite;

  @override
  Future<dynamic> post(String path, [Map<String, dynamic>? body]) async {
    expect(path, '/favorites/channels');
    savedFavorite = body;
    return pendingFavorite?.future;
  }
}

Future<void> _pumpPane(
  WidgetTester tester,
  PlaylistStore store, {
  Size size = const Size(390, 844),
  double textScale = 1,
  NavigationMode navigationMode = NavigationMode.traditional,
  Future<void> Function()? onChannelSelected,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          navigationMode: navigationMode,
        ),
        child: child!,
      ),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: store,
          builder: (context, _) => ChannelsPane(
            store: store,
            compact: true,
            fullscreen: true,
            onChannelSelected: onChannelSelected,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _tile(String name) =>
    find.ancestor(of: find.text(name), matching: find.byType(ListTile));

void main() {
  late PlaylistStore store;
  late _FavoritesApi api;

  setUp(() {
    api = _FavoritesApi();
    store = PlaylistStore(api: api)
      ..selectedGroup = _group
      ..channels = [_channel(1, 'Darts'), _channel(2, _longName)];
  });

  tearDown(() {
    store.dispose();
  });

  testWidgets('mixed names share a row height and use both title lines', (
    tester,
  ) async {
    await _pumpPane(tester, store);
    final shortTitle = tester.getRect(find.text('Darts'));
    final longTitle = tester.getRect(find.text(_longName));
    final shortRow = tester.getRect(_tile('Darts'));
    final longRow = tester.getRect(_tile(_longName));

    expect(longTitle.height, closeTo(shortTitle.height * 2, 1));
    expect(shortRow.height, 72);
    expect(longRow.height, shortRow.height);
    expect(shortTitle.center.dy, closeTo(shortRow.center.dy, 1));
    expect(longTitle.center.dy, closeTo(longRow.center.dy, 1));
    expect(find.text(_group), findsOneWidget);
    expect(find.text('Channels'), findsNothing);
    expect(find.byIcon(Icons.tv), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('details reveal the full name without starting playback', (
    tester,
  ) async {
    await _pumpPane(tester, store);
    await tester.tap(find.byTooltip('Channel details').last);
    await tester.pumpAndSettle();

    final sheetTitle = find.descendant(
      of: find.byType(ChannelActionSheet),
      matching: find.text(_longName),
    );
    expect(tester.getSize(sheetTitle).height, greaterThan(60));
    expect(tester.widget<Text>(sheetTitle).maxLines, isNull);
    expect(store.nowPlaying, isNull);
    expect(find.text(_group), findsNWidgets(2));

    await tester.tap(find.text('Add to favorites'));
    await tester.pumpAndSettle();
    expect(api.savedFavorite?['name'], _longName);
    expect(store.channels.last.isFavorite, isTrue);
    expect(find.byType(ChannelActionSheet), findsNothing);
  });

  testWidgets('tapping a title and sheet Play both open the player', (
    tester,
  ) async {
    var playerOpened = 0;
    await _pumpPane(
      tester,
      store,
      onChannelSelected: () async => playerOpened++,
    );
    await tester.tap(find.text('Darts'));
    await tester.pumpAndSettle();
    expect(store.nowPlaying?.name, 'Darts');
    expect(playerOpened, 1);
    final paragraph = find.descendant(
      of: find.text('Darts'),
      matching: find.byType(RichText),
    );
    final richText = tester.widget<RichText>(paragraph);
    final titleContext = tester.element(find.text('Darts'));
    expect(
      (richText.text as TextSpan).style?.color,
      Theme.of(titleContext).colorScheme.primary,
    );

    await tester.tap(find.byTooltip('Channel details').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    expect(store.nowPlaying?.name, _longName);
    expect(playerOpened, 2);
  });

  testWidgets('favorite errors remain visible after the details sheet closes', (
    tester,
  ) async {
    api.pendingFavorite = Completer<dynamic>();
    await _pumpPane(tester, store);
    await tester.tap(find.byTooltip('Channel details').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to favorites'));
    await tester.pumpAndSettle();
    expect(find.byType(ChannelActionSheet), findsNothing);

    api.pendingFavorite!.completeError(
      const ApiException('Could not save favorite'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Could not save favorite'), findsOneWidget);
    expect(store.channels.last.isFavorite, isFalse);
  });

  testWidgets('large text keeps uniform rows and scrolls to playing channel', (
    tester,
  ) async {
    store.channels = List.generate(
      100,
      (i) => _channel(i, i.isEven ? 'Darts $i' : '$_longName $i'),
    );
    await _pumpPane(tester, store, textScale: 2);
    final shortRow = tester.getRect(_tile('Darts 0'));
    final longRow = tester.getRect(_tile('$_longName 1'));
    final longTitle = tester.getRect(find.text('$_longName 1'));
    expect(shortRow.height, greaterThan(72));
    expect(longRow.height, shortRow.height);
    expect(longTitle.top, greaterThanOrEqualTo(longRow.top));
    expect(longTitle.bottom, lessThanOrEqualTo(longRow.bottom));

    await store.play(store.channels[50]);
    await tester.pumpAndSettle();
    expect(find.text('Darts 50').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android tablet offers touch details and direct playback', (
    tester,
  ) async {
    await _pumpPane(tester, store, size: const Size(800, 1280));
    await tester.tap(find.byTooltip('Channel details').last);
    await tester.pumpAndSettle();
    expect(find.byType(ChannelActionSheet), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Darts'));
    await tester.pumpAndSettle();
    expect(store.nowPlaying?.name, 'Darts');
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV select plays and long select opens details', (tester) async {
    await _pumpPane(
      tester,
      store,
      size: const Size(1280, 720),
      navigationMode: NavigationMode.directional,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(store.nowPlaying?.name, 'Darts');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(ChannelActionSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
