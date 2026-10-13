import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/models.dart';
import 'package:flutter_app/screens/home/tv/tv_programme_panel.dart';
import 'package:flutter_app/services/api_client.dart';
import 'package:flutter_app/services/playlist_store.dart';

class _GuideStore extends PlaylistStore {
  _GuideStore() : super(api: ApiClient(baseUrl: 'https://fixture.invalid'));
  @override
  Future<List<EpgEntry>> loadChannelEpg(Channel channel) async {
    final now = DateTime.now();
    return [
      EpgEntry(
        channelEpgId: 'fixture',
        startTime: now.subtract(const Duration(minutes: 10)),
        endTime: now.add(const Duration(minutes: 20)),
        title:
            'A very long current programme title that needs both readable lines on television',
        description: 'Fixture details',
      ),
    ];
  }
}

void main() {
  testWidgets('TV On now rows fit two title lines at 1.6 text scaling', (
    tester,
  ) async {
    final store = _GuideStore();
    final focus = FocusNode();
    final channel = Channel.fromJson({
      'id': 1,
      'playlist_id': 1,
      'name': 'Fixture channel',
    });
    store.nowPlaying = channel;
    addTearDown(() {
      focus.dispose();
      store.dispose();
    });
    await tester.binding.setSurfaceSize(const Size(960, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 340,
              height: 860,
              child: TvProgrammePanel(
                store: store,
                channel: channel,
                preview: const SizedBox.shrink(),
                focusNode: focus,
                onReturn: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(find.textContaining('On now'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
