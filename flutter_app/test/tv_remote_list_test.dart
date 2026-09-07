import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/screens/home/tv/tv_remote_list.dart';

void main() {
  late FocusNode focus;
  late List<String> items;
  late String? selected;
  late List<String> activated;
  late List<String> held;
  late List<String> directions;
  late StateSetter update;
  late String memoryKey;

  setUp(() {
    focus = FocusNode();
    items = List.generate(100, (i) => 'channel-$i');
    selected = 'channel-2';
    activated = [];
    held = [];
    directions = [];
    memoryKey = 'all';
  });
  tearDown(() => focus.dispose());

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return SizedBox(
                width: 400,
                height: 216,
                child: TvRemoteList<String>(
                  focusNode: focus,
                  autofocus: true,
                  items: items,
                  itemId: (item) => item,
                  selectedId: selected,
                  memoryKey: memoryKey,
                  itemExtent: 72,
                  itemBuilder: (context, item, focused) => Text(item),
                  onFocused: (item) => setState(() => selected = item),
                  onActivate: activated.add,
                  onLongPress: held.add,
                  onLeft: () => directions.add('left'),
                  onRight: () => directions.add('right'),
                  onBack: () => directions.add('back'),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('remote reaches rows beyond the lazy viewport without playing', (
    tester,
  ) async {
    await mount(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    for (var i = 0; i < 24; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(selected, 'channel-27');
    expect(find.text('channel-27').hitTestable(), findsOneWidget);
    expect(activated, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(activated, ['channel-27']);
  });

  testWidgets('selection follows channel identity when the list is reordered', (
    tester,
  ) async {
    await mount(tester);
    update(() => items = ['channel-2', 'channel-0', 'channel-1']);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(activated, ['channel-2']);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(selected, 'channel-0');
  });

  testWidgets('holding OK opens options once without starting playback', (
    tester,
  ) async {
    await mount(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 550));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    expect(held, ['channel-2']);
    expect(activated, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(activated, ['channel-2']);
  });

  testWidgets('empty lists still allow leaving the column and going Back', (
    tester,
  ) async {
    items = [];
    selected = null;
    await mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(
      LogicalKeyboardKey.goBack,
      physicalKey: PhysicalKeyboardKey.escape,
    );
    expect(directions, ['left', 'right', 'back']);
    expect(activated, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a held selection is cancelled when the list loses focus', (
    tester,
  ) async {
    await mount(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    focus.unfocus();
    await tester.pump(const Duration(milliseconds: 550));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    expect(held, isEmpty);
    expect(activated, isEmpty);
  });

  testWidgets(
    'restores the exact viewport after a group loads asynchronously',
    (tester) async {
      await mount(tester);
      for (var i = 0; i < 50; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      for (var i = 0; i < 10; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
      }
      expect(selected, 'channel-42');
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
        3024,
      );
      final original = items;
      update(() {
        memoryKey = 'other';
        selected = 'channel-0';
        items = [];
      });
      await tester.pump();
      update(() => items = original);
      await tester.pumpAndSettle();
      update(() {
        memoryKey = 'all';
        selected = 'channel-42';
        items = [];
      });
      await tester.pump();
      update(() => items = original);
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
        3024,
      );
    },
  );
}
