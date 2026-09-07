import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_app/models/models.dart';
import 'package:flutter_app/services/api_client.dart';
import 'package:flutter_app/services/playlist_store.dart';

const serviceRef = '1:0:19:EF10:421:1:C00000:0:0:0:';
const legacyUrl =
    'http://receiver.test:8001/1%3A0%3A19%3AEF10%3A421%3A1%3AC00000%3A0%3A0%3A0%3A';
const relayUrl = 'http://receiver.test:17999/1:0:19:EF10:421:1:C00000:0:0:0:';

Channel channel({
  int playlistId = 1,
  String streamId = serviceRef,
  String streamUrl = legacyUrl,
  String groupName = 'Sat',
}) => Channel(
  id: 100,
  playlistId: playlistId,
  streamId: streamId,
  name: 'Test HD',
  groupName: groupName,
  streamUrl: streamUrl,
  logoUrl: '',
  epgChannelId: streamId,
  isFavorite: true,
);

void main() {
  late PlaylistStore store;

  setUp(() {
    store = PlaylistStore(
      api: ApiClient(baseUrl: 'http://backend.test/api/v1'),
    );
    store.playlists = const [
      Playlist(
        id: 1,
        name: 'Receiver',
        type: 'vuplus',
        vuplusIp: 'receiver.test',
        vuplusPort: '8088',
      ),
      Playlist(id: 2, name: 'IPTV', type: 'xtream'),
      Playlist(id: 3, name: 'M3U', type: 'm3u'),
    ];
    // A favourite/search result can belong to a different playlist than the
    // one currently selected in the sidebar.
    store.selectedPlaylistId = 2;
  });

  tearDown(() => store.dispose());

  test(
    'cached Vu+ channel uses the relay URL supplied by its receiver',
    () async {
      final requests = <http.Request>[];
      final url = await http.runWithClient(
        () => store.resolveChannelStreamUrl(channel()),
        () => MockClient((request) async {
          requests.add(request);
          return http.Response(
            '\uFEFF#EXTM3U \r\n#EXTVLCOPT:http-reconnect=true\r\n'
            '#EXTINF:-1,Test HD\r\n#EXTVLCOPT:program=61200\r\n'
            '$relayUrl\r\n',
            200,
            headers: {'content-type': 'application/x-mpegurl; charset=utf-8'},
          );
        }),
      );

      expect(url, relayUrl);
      expect(requests, hasLength(1));
      expect(requests.single.method, 'GET');
      expect(requests.single.url.host, 'receiver.test');
      expect(requests.single.url.port, 8088);
      expect(requests.single.url.path, '/web/stream.m3u');
      expect(requests.single.url.queryParameters['ref'], serviceRef);
    },
  );

  test(
    'normal Vu+ service preserves the URL and session supplied by OpenWebif',
    () async {
      const streamUrl =
          'http://-sid:session-token@receiver.test:8001/$serviceRef?option=1&next=2';
      final url = await http.runWithClient(
        () => store.resolveChannelStreamUrl(channel()),
        () => MockClient(
          (_) async => http.Response('#EXTM3U\n$streamUrl\n', 200),
        ),
      );

      expect(url, streamUrl);
    },
  );

  test(
    'each playback resolves again instead of caching a receiver session',
    () async {
      var attempts = 0;
      final urls = await http.runWithClient(
        () async => [
          await store.resolveChannelStreamUrl(channel()),
          await store.resolveChannelStreamUrl(channel()),
        ],
        () => MockClient((_) async {
          attempts++;
          return http.Response('#EXTM3U\n$relayUrl?session=$attempts\n', 200);
        }),
      );

      expect(urls, ['$relayUrl?session=1', '$relayUrl?session=2']);
    },
  );

  for (final entry in <String, Channel>{
    'Xtream': channel(playlistId: 2),
    'M3U': channel(playlistId: 3),
    'unknown playlist': channel(playlistId: 999),
    'recording': channel(
      groupName: 'Aufnahmen',
      streamId: '1:0:0:0:0:0:0:0:0:0:/hdd/movie/Test.ts',
      streamUrl: 'http://receiver.test:8088/file?file=%2Fhdd%2Fmovie%2FTest.ts',
    ),
  }.entries) {
    test('${entry.key} keeps its stream without a receiver request', () async {
      var requests = 0;
      final url = await http.runWithClient(
        () => store.resolveChannelStreamUrl(entry.value),
        () => MockClient((_) async {
          requests++;
          return http.Response('#EXTM3U\n$relayUrl\n', 200);
        }),
      );

      expect(url, entry.value.streamUrl);
      expect(requests, 0);
    });
  }

  for (final entry in {
    'missing endpoint': http.Response('Not found', 404),
    'HTML response': http.Response('<html>Login required</html>', 200),
    'empty playlist': http.Response('#EXTM3U\n# no stream available\n', 200),
    'local file URL': http.Response('#EXTM3U\nfile:///etc/passwd\n', 200),
  }.entries) {
    test('OpenWebif ${entry.key} falls back to the direct stream', () async {
      final url = await http.runWithClient(
        () => store.resolveChannelStreamUrl(channel()),
        () => MockClient((_) async => entry.value),
      );

      expect(url, legacyUrl);
    });
  }

  testWidgets(
    'unresponsive OpenWebif times out before player startup timeout',
    (tester) async {
      final response = Completer<http.Response>();
      String? resolved;
      final pending = http.runWithClient(
        () => store
            .resolveChannelStreamUrl(channel())
            .then((url) => resolved = url),
        () => MockClient((_) => response.future),
      );
      await tester.pump();
      expect(resolved, isNull);

      await tester.pump(const Duration(seconds: 8));
      expect(resolved, legacyUrl);
      await pending;
      response.complete(http.Response('#EXTM3U\n$relayUrl\n', 200));
      await tester.pump();
      expect(resolved, legacyUrl);
    },
  );

  test(
    'receiver connection failure retains the direct stream fallback',
    () async {
      final url = await http.runWithClient(
        () => store.resolveChannelStreamUrl(channel()),
        () =>
            MockClient((_) async => throw http.ClientException('Unavailable')),
      );

      expect(url, legacyUrl);
    },
  );
}
