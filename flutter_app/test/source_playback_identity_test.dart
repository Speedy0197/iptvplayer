import 'package:flutter_app/models/models.dart';
import 'package:flutter_app/services/api_client.dart';
import 'package:flutter_app/services/playlist_store.dart';
import 'package:flutter_test/flutter_test.dart';

class SourceApi extends ApiClient {
  SourceApi() : super(baseUrl: 'https://fixture.invalid');
  final remaining = <int>{1, 2};
  String updated = '2020-01-01T00:00:00Z';
  @override
  Future<dynamic> get(String path) async {
    if (path.endsWith('/source')) {
      return {'id': 1, 'name': 'Source 1', 'type': 'm3u'};
    }
    if (path == '/playlists') {
      return remaining
          .map(
            (id) => {
              'id': id,
              'name': 'Source $id',
              'type': 'm3u',
              'last_refreshed': updated,
            },
          )
          .toList();
    }
    return <dynamic>[];
  }

  @override
  Future<dynamic> put(String path, [Map<String, dynamic>? body]) async => {
    'message': 'ok',
  };
  @override
  Future<dynamic> delete(String path) async {
    remaining.remove(int.parse(path.split('/').last));
    return {'message': 'ok'};
  }
}

void main() {
  for (final deleted in [1, 2]) {
    test('deleting source $deleted separates browsing from playback', () async {
      final api = SourceApi();
      final store = PlaylistStore(api: api);
      addTearDown(store.dispose);
      await store.fetchPlaylists();
      final channel = Channel.fromJson({
        'id': 10,
        'playlist_id': 1,
        'name': 'Playing source 1',
        'stream_url': 'https://fixture.invalid/live',
      });
      store.nowPlaying = channel;
      await store.selectPlaylist(2, preservePlayback: true);
      await store.deletePlaylist(deleted);
      if (deleted == 1) {
        expect(store.nowPlaying, isNull);
      } else {
        expect(store.nowPlaying?.id, channel.id);
        expect(store.nowPlaying?.playlistId, channel.playlistId);
        expect(store.nowPlaying?.streamUrl, channel.streamUrl);
      }
      expect(store.selectedPlaylistId, deleted == 1 ? 2 : 1);
    });
  }
  test('successful source refresh reloads its server timestamp', () async {
    final api = SourceApi();
    final store = PlaylistStore(api: api);
    addTearDown(store.dispose);
    await store.fetchPlaylists();
    api.updated = '2026-10-13T12:00:00Z';
    await store.refreshPlaylist(1);
    expect(store.playlists.first.lastRefreshed, api.updated);
  });
}
