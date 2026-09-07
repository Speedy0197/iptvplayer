import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_app/services/casting/cast_media_resolver.dart';

void main() {
  test('cancellation closes a stalled in-flight probe immediately', () async {
    final client = StalledClient();
    final cancellation = Completer<void>();
    final result = CastMediaResolver(clientFactory: () => client).resolve(
      id: 'old',
      url: 'https://media.example/live',
      title: 'Old',
      cancelled: cancellation.future,
    );
    final failure = expectLater(result, throwsA(isA<CastMediaException>()));
    cancellation.complete();
    await Future<void>.delayed(Duration.zero);
    expect(client.closed, isTrue);
    await failure;
  });
  Future<String> resolve(http.Client client, String url) async =>
      (await CastMediaResolver(
        clientFactory: () => client,
        timeout: const Duration(milliseconds: 50),
      ).resolve(id: 'channel', url: url, title: 'Channel')).contentType;

  test('uses the response type for extensionless live streams', () async {
    expect(
      await resolve(
        MockClient(
          (r) async => http.Response(
            '',
            200,
            headers: {'content-type': 'video/MP2T; charset=binary'},
          ),
        ),
        'http://receiver.local/live/1',
      ),
      'video/mp2t',
    );
  });

  test('sniffs HLS when a server sends generic content type', () async {
    final methods = <String>[];
    final client = MockClient((request) async {
      methods.add(request.method);
      return http.Response(
        request.method == 'GET' ? '#EXTM3U\n#EXT-X-VERSION:3' : '',
        200,
        headers: {'content-type': 'application/octet-stream'},
      );
    });
    expect(
      await resolve(client, 'https://media.example/play'),
      'application/x-mpegURL',
    );
    expect(methods, ['HEAD', 'GET']);
  });

  test(
    'falls back to a known MP4 extension when HEAD is unsupported',
    () async {
      expect(
        await resolve(
          MockClient((r) async => http.Response('', 405)),
          'https://media.example/movie.mp4?token=private',
        ),
        'video/mp4',
      );
    },
  );

  test('does not disguise a failed request as supported media', () async {
    await expectLater(
      resolve(
        MockClient((r) async => http.Response('', 403)),
        'https://media.example/movie.m3u8?token=private',
      ),
      throwsA(isA<CastMediaException>()),
    );
  });

  test('rejects invalid and phone-only URLs before making requests', () async {
    final client = MockClient((r) async => fail('Unexpected probe'));
    for (final url in [
      'file:///movie.mp4',
      'http://localhost/live',
      'http://127.0.0.1/live',
      'http://[::1]/live',
      'not a URL',
    ]) {
      await expectLater(
        resolve(client, url),
        throwsA(isA<CastMediaException>()),
      );
    }
  });

  test('times out without exposing the source URL', () async {
    try {
      await resolve(
        MockClient((r) => Completer<http.Response>().future),
        'https://media.example/secret-token',
      );
      fail('Should time out');
    } on CastMediaException catch (error) {
      expect(error.toString(), isNot(contains('secret-token')));
    }
  });

  test('does not start a body probe when selection becomes stale', () async {
    var current = true;
    final client = MockClient((r) async {
      expect(r.method, 'HEAD');
      current = false;
      return http.Response('', 200);
    });
    await expectLater(
      CastMediaResolver(clientFactory: () => client).resolve(
        id: 'old',
        url: 'https://media.example/live',
        title: 'Old',
        isCurrent: () => current,
      ),
      throwsA(isA<CastMediaException>()),
    );
  });
}

class StalledClient extends http.BaseClient {
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
  @override
  void close() {
    closed = true;
  }
}
