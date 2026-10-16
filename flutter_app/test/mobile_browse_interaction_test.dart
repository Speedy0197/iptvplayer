import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/config/app_theme.dart';
import 'package:flutter_app/models/models.dart';
import 'package:flutter_app/screens/home_screen.dart';
import 'package:flutter_app/screens/home/widgets/browse_controls.dart';
import 'package:flutter_app/services/playlist_store.dart';
import 'package:provider/provider.dart';

import 'browsing_ui_test.dart' show FixtureApi;

void main() {
  late PlaylistStore store;
  setUp(() => store = PlaylistStore(api: FixtureApi(channelCount: 30)));
  tearDown(() => store.dispose());

  Future<void> mount(
    WidgetTester tester, {
    bool pickerOnly = false,
    bool largeText = false,
    bool tv = false,
    Size? size,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize =
        size ??
        (tv
            ? const Size(1280, 720)
            : largeText
            ? const Size(320, 700)
            : const Size(390, 844));
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: store,
        child: MaterialApp(
          theme: createStreamPilotTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(largeText ? 1.6 : 1),
              navigationMode: tv
                  ? NavigationMode.directional
                  : NavigationMode.traditional,
            ),
            child: child!,
          ),
          home: pickerOnly
              ? Scaffold(
                  body: Consumer<PlaylistStore>(
                    builder: (_, store, _) => GroupSelector(store: store),
                  ),
                )
              : const HomeScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester) async {
    await mount(tester);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'News');
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);
  }

  testWidgets(
    'phone Search action dismisses IME and keeps the results',
    (tester) async {
      await search(tester);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
      expect(store.searchQuery, 'News');
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Sample News 00'), findsWidgets);
      await tester.tap(find.byType(TextFormField));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'scrolling phone search results dismisses IME without clearing',
    (tester) async {
      await search(tester);
      final results = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(ListView),
      );
      await tester.drag(results, const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
      expect(store.searchQuery, 'News');
      expect(find.byType(Dialog), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'tapping a phone search filter dismisses IME',
    (tester) async {
      await search(tester);
      await tester.ensureVisible(find.text('Channels only'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Channels only'));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
      expect(store.searchQuery, 'News');
      expect(find.byType(Dialog), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'search fits a small phone with large text and keyboard open',
    (tester) async {
      await mount(tester, largeText: true);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextFormField), 'News');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Close search').hitTestable(), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'TV submit still hands focus to remote navigation',
    (tester) async {
      await mount(tester, tv: true);
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'News');
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'firstSearchResult',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      expect(store.searchQuery, 'News');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'landscape group picker scrolls with its keyboard open',
    (tester) async {
      await store.bootstrap();
      store.groups = List.generate(
        20,
        (i) => Group(
          name: 'Country $i',
          playlistId: 1,
          channelCount: 10,
          isFavorite: false,
        ),
      );
      await mount(tester, pickerOnly: true, size: const Size(568, 320));
      await tester.tap(find.byTooltip('Select group'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Country');
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
      expect(tester.testTextInput.isVisible, isTrue);
      tester.testTextInput.enterText('Country 0');
      await tester.pumpAndSettle();
      final option = find.widgetWithText(InkWell, 'Country 0');
      await tester.scrollUntilVisible(
        option,
        60,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(option);
      await tester.pumpAndSettle();
      expect(store.selectedGroup, 'Country 0');
      expect(find.byType(BottomSheet), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'long group picker filters and selects without stopping playback',
    (tester) async {
      await store.bootstrap();
      const name = 'Dazn Germany Events (Auto Update Daily)';
      store.groups = [
        const Group(
          name: name,
          playlistId: 1,
          channelCount: 100,
          isFavorite: false,
        ),
        ...List.generate(
          25,
          (i) => Group(
            name: 'Country $i',
            playlistId: 1,
            channelCount: 312,
            isFavorite: false,
          ),
        ),
      ];
      final playing = store.channels.first;
      store.nowPlaying = playing;
      await mount(tester, pickerOnly: true, largeText: true);
      await tester.tap(find.byTooltip('Select group'));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
      final input = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(TextField),
      );
      expect(input, findsOneWidget);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.enterText(input, 'dazn');
      await tester.pumpAndSettle();
      expect(find.text('Country 0'), findsNothing);
      expect(find.text(name), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(name));
      await tester.pumpAndSettle();
      expect(store.selectedGroup, name);
      expect(store.nowPlaying, same(playing));
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.testTextInput.isVisible, isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
