import 'dart:async';
import 'dart:io';

import 'package:flutter_app/models/models.dart';
import 'package:flutter_app/services/api_client.dart';
import 'package:flutter_app/services/playlist_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TV browsing store support', () {
    test('playlist selection preserves playback only when requested', () async {
      final epgFile = await _writeEpgFixture();
      addTearDown(() => epgFile.parent.delete(recursive: true));
      final store = PlaylistStore(
        api: _fixtureApi(
          playlists: [
            _playlistJson(1, epgUrl: epgFile.uri.toString()),
            _playlistJson(2),
          ],
          channelsByPlaylist: {
            1: [_channelJson(11, 1, 'News', epgId: 'news.one')],
            2: [_channelJson(21, 2, 'Sports')],
          },
        ),
      );
      addTearDown(store.dispose);

      await store.fetchPlaylists();
      final playing = store.channels.single;
      await store.play(playing);
      final playingEpg = store.epgEntries;

      await store.selectPlaylist(2, preservePlayback: true);

      expect(store.nowPlaying, same(playing));
      expect(store.epgEntries, same(playingEpg));

      await store.selectPlaylist(1);

      expect(store.nowPlaying, isNull);
      expect(store.epgEntries, isEmpty);
    });

    test('group selection preserves playback only when requested', () async {
      final epgFile = await _writeEpgFixture();
      addTearDown(() => epgFile.parent.delete(recursive: true));
      final store = PlaylistStore(
        api: _fixtureApi(
          playlists: [_playlistJson(1, epgUrl: epgFile.uri.toString())],
          channelsByPlaylist: {
            1: [
              _channelJson(11, 1, 'News', epgId: 'news.one'),
              _channelJson(12, 1, 'Sports'),
            ],
          },
        ),
      );
      addTearDown(store.dispose);

      await store.fetchPlaylists();
      final playing = store.channels.first;
      await store.play(playing);
      final playingEpg = store.epgEntries;

      await store.selectGroup('Sports', preservePlayback: true);

      expect(store.nowPlaying, same(playing));
      expect(store.epgEntries, same(playingEpg));

      await store.selectGroup('News');

      expect(store.nowPlaying, isNull);
      expect(store.epgEntries, isEmpty);
    });

    test('older playlist response cannot replace a newer group view', () async {
      final firstChannels = Completer<dynamic>();
      final secondChannels = Completer<dynamic>();
      final api = FixtureApiClient({
        '/favorites/groups': () => const <dynamic>[],
        '/playlists/1/channels': () => firstChannels.future,
        '/playlists/2/channels': () => secondChannels.future,
      });
      final store = PlaylistStore(api: api);
      addTearDown(store.dispose);

      final firstSelection = store.selectPlaylist(1);
      await api.whenRequested('/playlists/1/channels');
      final secondSelection = store.selectPlaylist(2);
      await api.whenRequested('/playlists/2/channels');
      secondChannels.complete([
        _channelJson(21, 2, 'News'),
        _channelJson(22, 2, 'Sports'),
      ]);
      await secondSelection;
      await store.selectGroup('Sports', preservePlayback: true);

      firstChannels.complete([_channelJson(11, 1, 'Old')]);
      await firstSelection;

      expect(store.selectedPlaylistId, 2);
      expect(store.selectedGroup, 'Sports');
      expect(
        store.groups.map((group) => group.name),
        containsAll(['News', 'Sports']),
      );
      expect(store.channels.map((channel) => channel.id), [22]);
    });

    test(
      'channel load failure exposes a safe error and retry clears it',
      () async {
        final retryChannels = Completer<dynamic>();
        var attempts = 0;
        final api = FixtureApiClient({
          '/playlists': () => [_playlistJson(1)],
          '/favorites/groups': () => const <dynamic>[],
          '/playlists/1/channels': () {
            attempts++;
            if (attempts == 1) {
              throw const ApiException('provider password was rejected');
            }
            return retryChannels.future;
          },
        });
        final store = PlaylistStore(api: api);
        addTearDown(store.dispose);

        await store.fetchPlaylists();

        expect(
          store.channelsError,
          'Could not load channels. Select the group to retry.',
        );
        expect(store.channels, isEmpty);

        final retry = store.selectGroup(null);
        expect(store.channelsError, isNull);
        retryChannels.complete([_channelJson(11, 1, 'News')]);
        await retry;

        expect(store.channelsError, isNull);
        expect(store.channels.map((channel) => channel.id), [11]);
        expect(store.loadingChannels, isFalse);
      },
    );

    test('stale refresh cannot cancel a newer channel failure', () async {
      final m3uFile = await _writeM3uFixture();
      addTearDown(() => m3uFile.parent.delete(recursive: true));
      final secondChannels = Completer<dynamic>();
      final api = FixtureApiClient({
        '/playlists': () => [_playlistJson(1), _playlistJson(2)],
        '/favorites/groups': () => const <dynamic>[],
        '/playlists/1/channels': () => [_channelJson(11, 1, 'News')],
        '/playlists/2/channels': () => secondChannels.future,
        '/playlists/1/source': () =>
            _playlistJson(1, m3uUrl: m3uFile.uri.toString()),
      });
      final store = PlaylistStore(api: api);
      addTearDown(store.dispose);
      await store.fetchPlaylists();
      var watchRefresh = true;
      var navigated = false;
      Future<void>? navigation;
      store.addListener(() {
        if (watchRefresh &&
            !navigated &&
            store.selectedPlaylistId == 1 &&
            store.loadingGroups) {
          navigated = true;
          navigation = store.selectPlaylist(2);
        }
      });

      await store.refreshPlaylist(1);
      watchRefresh = false;
      expect(navigated, isTrue);
      secondChannels.completeError(
        const ApiException('provider credentials expired'),
      );
      await navigation;

      expect(store.selectedPlaylistId, 2);
      expect(store.channels, isEmpty);
      expect(
        store.channelsError,
        'Could not load channels. Select the group to retry.',
      );
      expect(store.loadingChannels, isFalse);
    });

    test('playlist invalidation clears the channel error', () async {
      var playlistLoads = 0;
      final api = FixtureApiClient({
        '/playlists': () {
          playlistLoads++;
          return playlistLoads == 1 ? [_playlistJson(1)] : const <dynamic>[];
        },
        '/favorites/groups': () => const <dynamic>[],
        '/playlists/1/channels': () =>
            throw const ApiException('provider failed'),
      });
      final store = PlaylistStore(api: api);
      addTearDown(store.dispose);
      await store.fetchPlaylists();
      expect(store.channelsError, isNotNull);

      await store.fetchPlaylists();

      expect(store.selectedPlaylistId, isNull);
      expect(store.channels, isEmpty);
      expect(store.channelsError, isNull);
    });

    test(
      'loadChannelEpg returns data without changing playback state',
      () async {
        final epgFile = await _writeEpgFixture();
        addTearDown(() => epgFile.parent.delete(recursive: true));
        final store = PlaylistStore(
          api: _fixtureApi(
            playlists: [_playlistJson(1, epgUrl: epgFile.uri.toString())],
            channelsByPlaylist: {
              1: [
                _channelJson(11, 1, 'News', epgId: 'news.one'),
                _channelJson(12, 1, 'Sports', epgId: 'sports.one'),
              ],
            },
          ),
        );
        addTearDown(store.dispose);

        await store.fetchPlaylists();
        final playing = store.channels.first;
        final browsed = store.channels.last;
        await store.play(playing);
        final playingEpg = store.epgEntries;
        final missing = store.epgSourceMissing;
        final loading = store.loadingEpg;
        var notifications = 0;
        store.addListener(() => notifications++);

        final result = await store.loadChannelEpg(browsed);

        expect(result.map((entry) => entry.title), ['Live sport']);
        expect(store.nowPlaying, same(playing));
        expect(store.epgEntries, same(playingEpg));
        expect(store.epgSourceMissing, missing);
        expect(store.loadingEpg, loading);
        expect(notifications, 0);
      },
    );

    test('VU+ EPG cache isolates identical refs by playlist', () async {
      final firstRequests = <String>[];
      final secondRequests = <String>[];
      final firstServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final secondServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => firstServer.close(force: true));
      addTearDown(() => secondServer.close(force: true));
      firstServer.listen((request) async {
        firstRequests.add(request.uri.path);
        request.response.write(_vuplusEpgXml('shared.ref', 'Provider one'));
        await request.response.close();
      });
      secondServer.listen((request) async {
        secondRequests.add(request.uri.path);
        request.response.write(_vuplusEpgXml('shared.ref', 'Provider two'));
        await request.response.close();
      });
      final store = PlaylistStore(
        api: _fixtureApi(
          playlists: [
            _playlistJson(
              1,
              type: 'vuplus',
              vuplusIp: 'http://${firstServer.address.address}',
              vuplusPort: '${firstServer.port}',
            ),
            _playlistJson(
              2,
              type: 'vuplus',
              vuplusIp: 'http://${secondServer.address.address}',
              vuplusPort: '${secondServer.port}',
            ),
          ],
          channelsByPlaylist: {
            1: [_channelJson(11, 1, 'Live', epgId: 'shared.ref')],
            2: [_channelJson(21, 2, 'Live', epgId: 'shared.ref')],
          },
        ),
      );
      addTearDown(store.dispose);
      await store.fetchPlaylists();
      final firstChannel = store.channels.single;
      await store.selectPlaylist(2, preservePlayback: true);
      final secondChannel = store.channels.single;

      final firstEpg = await store.loadChannelEpg(firstChannel);
      final secondEpg = await store.loadChannelEpg(secondChannel);

      expect(firstEpg.map((entry) => entry.title), ['Provider one']);
      expect(secondEpg.map((entry) => entry.title), ['Provider two']);
      expect(firstRequests, ['/web/epgservice']);
      expect(secondRequests, ['/web/epgservice']);
    });

    test(
      'slow EPG completion cannot overwrite a newer playing channel',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final slowRequested = Completer<void>();
        final releaseSlow = Completer<void>();
        server.listen((request) async {
          request.response.headers.contentType = ContentType.text;
          if (request.uri.path == '/slow.xml') {
            slowRequested.complete();
            await releaseSlow.future;
            request.response.write(_xmltv('slow.one', 'Old programme'));
          } else {
            request.response.write(_xmltv('fast.one', 'Current programme'));
          }
          await request.response.close();
        });
        final origin = 'http://${server.address.address}:${server.port}';
        final api = _fixtureApi(
          playlists: [
            _playlistJson(1, epgUrl: '$origin/slow.xml'),
            _playlistJson(2, epgUrl: '$origin/fast.xml'),
          ],
          channelsByPlaylist: {
            1: [_channelJson(11, 1, 'Slow', epgId: 'slow.one')],
            2: [_channelJson(21, 2, 'Fast', epgId: 'fast.one')],
          },
        );
        final store = PlaylistStore(api: api);
        addTearDown(store.dispose);
        await store.fetchPlaylists();
        final slowChannel = store.channels.single;
        await store.selectPlaylist(2, preservePlayback: true);
        final fastChannel = store.channels.single;

        final slowPlay = store.play(slowChannel);
        await slowRequested.future;
        await store.play(fastChannel);
        releaseSlow.complete();
        await slowPlay;

        expect(store.nowPlaying, same(fastChannel));
        expect(store.epgEntries.map((entry) => entry.title), [
          'Current programme',
        ]);
        expect(store.loadingEpg, isFalse);
        expect(store.epgSourceMissing, isFalse);
      },
    );

    test('default playlist selection clears pending EPG loading', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final slowRequested = Completer<void>();
      final releaseSlow = Completer<void>();
      server.listen((request) async {
        slowRequested.complete();
        await releaseSlow.future;
        request.response.write(_xmltv('slow.one', 'Old programme'));
        await request.response.close();
      });
      final origin = 'http://${server.address.address}:${server.port}';
      final store = PlaylistStore(
        api: _fixtureApi(
          playlists: [
            _playlistJson(1, epgUrl: '$origin/slow.xml'),
            _playlistJson(2),
          ],
          channelsByPlaylist: {
            1: [_channelJson(11, 1, 'Slow', epgId: 'slow.one')],
            2: [_channelJson(21, 2, 'Fast')],
          },
        ),
      );
      addTearDown(store.dispose);
      await store.fetchPlaylists();
      final slowPlay = store.play(store.channels.single);
      await slowRequested.future;

      await store.selectPlaylist(2);
      final loadingAfterSelection = store.loadingEpg;
      releaseSlow.complete();
      await slowPlay;

      expect(loadingAfterSelection, isFalse);
      expect(store.loadingEpg, isFalse);
      expect(store.nowPlaying, isNull);
    });

    test('stale VU+ timer failure cannot overwrite newer EPG', () async {
      final timerRequested = Completer<void>();
      final releaseTimer = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        if (request.uri.path == '/web/timerlist') {
          timerRequested.complete();
          await releaseTimer.future;
          request.response.statusCode = HttpStatus.internalServerError;
        } else {
          request.response.write(_vuplusEpgXml('slow.vu', 'Old VU programme'));
        }
        await request.response.close();
      });
      final epgFile = await _writeEpgFixture();
      addTearDown(() => epgFile.parent.delete(recursive: true));
      final store = PlaylistStore(
        api: _fixtureApi(
          playlists: [
            _playlistJson(
              1,
              type: 'vuplus',
              vuplusIp: 'http://${server.address.address}',
              vuplusPort: '${server.port}',
            ),
            _playlistJson(2, epgUrl: epgFile.uri.toString()),
          ],
          channelsByPlaylist: {
            1: [_channelJson(11, 1, 'Live', epgId: 'slow.vu')],
            2: [_channelJson(21, 2, 'News', epgId: 'news.one')],
          },
        ),
      );
      addTearDown(store.dispose);
      await store.fetchPlaylists();
      final slowChannel = store.channels.single;
      await store.selectPlaylist(2, preservePlayback: true);
      final fastChannel = store.channels.single;

      final slowPlay = store.play(slowChannel);
      await timerRequested.future;
      await store.play(fastChannel);
      releaseTimer.complete();
      await slowPlay;

      expect(store.nowPlaying, same(fastChannel));
      expect(store.epgEntries.map((entry) => entry.title), ['Daily news']);
      expect(store.loadingEpg, isFalse);
    });

    test('VU+ recording playback loads timers from its own playlist', () async {
      final selectedPaths = <String>[];
      final recordingPaths = <String>[];
      final selectedServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final recordingServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => selectedServer.close(force: true));
      addTearDown(() => recordingServer.close(force: true));
      selectedServer.listen((request) async {
        selectedPaths.add(request.uri.path);
        request.response.write(_timerXml('/hdd/recordings/other.ts'));
        await request.response.close();
      });
      recordingServer.listen((request) async {
        recordingPaths.add(request.uri.path);
        request.response.write(_timerXml('/hdd/recordings/show.ts'));
        await request.response.close();
      });
      final api = _fixtureApi(
        playlists: [
          _playlistJson(
            1,
            type: 'vuplus',
            vuplusIp: 'http://${selectedServer.address.address}',
            vuplusPort: '${selectedServer.port}',
          ),
          _playlistJson(
            2,
            type: 'vuplus',
            vuplusIp: 'http://${recordingServer.address.address}',
            vuplusPort: '${recordingServer.port}',
          ),
        ],
        channelsByPlaylist: {
          1: [_channelJson(11, 1, 'Live')],
          2: const [],
        },
      );
      final store = PlaylistStore(api: api);
      addTearDown(store.dispose);
      await store.fetchPlaylists();
      final recording = Channel.fromJson(
        _channelJson(
          21,
          2,
          'Aufnahmen',
          epgId: '1:0:0:0:0:0:0:0:0:0:/hdd/recordings/show.ts',
        ),
      );

      await store.play(recording);

      expect(store.selectedPlaylistId, 1);
      expect(store.nowPlaying, same(recording));
      expect(store.isChannelActivelyRecording(recording), isTrue);
      expect(store.loadingEpg, isFalse);

      final timers = await store.loadChannelTimers(recording);
      final timer = timers.single;
      final entry = EpgEntry(
        channelEpgId: timer.channelEpgId,
        startTime: DateTime.fromMillisecondsSinceEpoch(
          timer.beginUnix * 1000,
          isUtc: true,
        ),
        endTime: DateTime.fromMillisecondsSinceEpoch(
          timer.endUnix * 1000,
          isUtc: true,
        ),
        title: timer.name,
        description: 'Fixture',
      );
      final playingEpg = store.epgEntries;
      await store.recordEpgEntry(entry, playlistId: 2);
      await store.removeEpgTimer(entry, playlistId: 2);

      expect(selectedPaths, isEmpty);
      expect(recordingPaths, [
        '/web/timerlist',
        '/web/timerlist',
        '/web/timeradd',
        '/web/timerlist',
        '/web/timerdelete',
        '/web/timerlist',
      ]);
      expect(store.selectedPlaylistId, 1);
      expect(store.nowPlaying, same(recording));
      expect(store.epgEntries, same(playingEpg));

      final selectedRecording = Channel.fromJson(
        _channelJson(
          12,
          1,
          'Aufnahmen',
          epgId: '1:0:0:0:0:0:0:0:0:0:/hdd/recordings/other.ts',
        ),
      );
      await store.play(selectedRecording);
      expect(store.isChannelActivelyRecording(selectedRecording), isTrue);
      selectedPaths.clear();
      recordingPaths.clear();
      final selectedPlayingEpg = store.epgEntries;
      var notifications = 0;
      store.addListener(() => notifications++);

      await store.recordEpgEntry(entry, playlistId: 2);
      await store.removeEpgTimer(entry, playlistId: 2);

      expect(selectedPaths, isEmpty);
      expect(recordingPaths, [
        '/web/timeradd',
        '/web/timerlist',
        '/web/timerdelete',
        '/web/timerlist',
      ]);
      expect(store.isChannelActivelyRecording(selectedRecording), isTrue);
      expect(store.nowPlaying, same(selectedRecording));
      expect(store.epgEntries, same(selectedPlayingEpg));
      expect(notifications, 0);
    });
  });
}

class FixtureApiClient extends ApiClient {
  FixtureApiClient(this.fixtures) : super(baseUrl: 'http://fixture.invalid');

  final Map<String, FutureOr<dynamic> Function()> fixtures;
  final Map<String, Completer<void>> _requests = {};

  Future<void> whenRequested(String path) =>
      (_requests[path] ??= Completer<void>()).future;

  @override
  Future<dynamic> get(String path) async {
    final request = _requests[path] ??= Completer<void>();
    if (!request.isCompleted) request.complete();
    final fixture = fixtures[path];
    if (fixture == null) {
      throw StateError('No GET fixture for $path');
    }
    return fixture();
  }

  @override
  Future<dynamic> put(String path, [Map<String, dynamic>? body]) async => null;
}

FixtureApiClient _fixtureApi({
  required List<Map<String, dynamic>> playlists,
  required Map<int, List<Map<String, dynamic>>> channelsByPlaylist,
}) {
  return FixtureApiClient({
    '/playlists': () => playlists,
    '/favorites/groups': () => const <dynamic>[],
    for (final entry in channelsByPlaylist.entries)
      '/playlists/${entry.key}/channels': () => entry.value,
  });
}

Map<String, dynamic> _playlistJson(
  int id, {
  String? epgUrl,
  String? m3uUrl,
  String type = 'm3u',
  String? vuplusIp,
  String? vuplusPort,
}) => {
  'id': id,
  'name': 'Playlist $id',
  'type': type,
  'm3u_url': m3uUrl ?? 'https://example.invalid/$id.m3u',
  'epg_url': epgUrl,
  'xtream_server': null,
  'xtream_username': null,
  'xtream_password': null,
  'vuplus_ip': vuplusIp,
  'vuplus_port': vuplusPort,
  'last_refreshed': '2026-09-07T12:00:00Z',
};

Map<String, dynamic> _channelJson(
  int id,
  int playlistId,
  String group, {
  String? epgId,
}) => {
  'id': id,
  'playlist_id': playlistId,
  'stream_id': 'stream-$id',
  'name': 'Channel $id',
  'group_name': group,
  'stream_url': 'https://example.invalid/$id.ts',
  'logo_url': 'https://example.invalid/$id.png',
  'epg_channel_id': epgId ?? '',
  'sort_order': id,
  'is_favorite': false,
};

Future<File> _writeEpgFixture() async {
  final directory = await Directory.systemTemp.createTemp('stream-pilot-epg-');
  final file = File('${directory.path}${Platform.pathSeparator}epg.xml');
  await file.writeAsString('''
<tv>
  <channel id="news.one"><display-name>Channel 11</display-name></channel>
  <channel id="sports.one"><display-name>Channel 12</display-name></channel>
  <programme start="20260907120000 +0000" stop="20260907130000 +0000" channel="news.one">
    <title>Daily news</title><desc>Headlines</desc>
  </programme>
  <programme start="20260907130000 +0000" stop="20260907140000 +0000" channel="sports.one">
    <title>Live sport</title><desc>Match</desc>
  </programme>
</tv>
''');
  return file;
}

Future<File> _writeM3uFixture() async {
  final directory = await Directory.systemTemp.createTemp('stream-pilot-m3u-');
  final file = File('${directory.path}${Platform.pathSeparator}channels.m3u');
  await file.writeAsString('''
#EXTM3U
#EXTINF:-1 tvg-id="refreshed.one" group-title="News",Refreshed
https://example.invalid/refreshed.ts
''');
  return file;
}

String _xmltv(String channelId, String title) =>
    '''
<tv>
  <channel id="$channelId"><display-name>$channelId</display-name></channel>
  <programme start="20260907120000 +0000" stop="20260907130000 +0000" channel="$channelId">
    <title>$title</title><desc>Fixture</desc>
  </programme>
</tv>
''';

String _timerXml(String filename) =>
    '''
<e2timerlist>
  <e2timer>
    <e2servicereference>1:0:1:timer</e2servicereference>
    <e2timebegin>1788782400</e2timebegin>
    <e2timeend>4102444800</e2timeend>
    <e2name>Recording</e2name>
    <e2filename>$filename</e2filename>
  </e2timer>
</e2timerlist>
''';

String _vuplusEpgXml(String channelId, String title) =>
    '''
<e2eventlist>
  <e2event>
    <e2eventstart>1788782400</e2eventstart>
    <e2eventduration>3600</e2eventduration>
    <e2eventtitle>$title</e2eventtitle>
    <e2eventdescription>Fixture</e2eventdescription>
    <e2eventservicereference>$channelId</e2eventservicereference>
  </e2event>
</e2eventlist>
''';
