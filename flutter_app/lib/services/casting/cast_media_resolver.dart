import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'cast_transport.dart';

class CastMediaException implements Exception {
  const CastMediaException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Identifies the container without downloading a live stream. Each bounded
/// probe owns its client, so timeout/cancellation closes the source connection.
class CastMediaResolver {
  CastMediaResolver({
    http.Client Function()? clientFactory,
    this.timeout = const Duration(seconds: 5),
  }) : _clientFactory = clientFactory ?? http.Client.new;

  final http.Client Function() _clientFactory;
  final Duration timeout;

  Future<CastMedia> resolve({
    required String id,
    required String url,
    required String title,
    String? imageUrl,
    bool isLive = true,
    Duration position = Duration.zero,
    bool Function()? isCurrent,
    Future<void>? cancelled,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        [
          'localhost',
          '::1',
          '[::1]',
          '0.0.0.0',
        ].contains(uri.host.toLowerCase()) ||
        uri.host.startsWith('127.')) {
      throw const CastMediaException(
        'The TV needs a network-accessible HTTP stream.',
      );
    }
    var didCancel = false;
    void checkCurrent() {
      if (didCancel || isCurrent?.call() == false) {
        throw const CastMediaException('The selected channel changed.');
      }
    }

    checkCurrent();
    final client = _clientFactory();
    final cancellation = cancelled?.then<String?>((_) {
      didCancel = true;
      client.close();
      throw const CastMediaException('The selected channel changed.');
    });
    try {
      final probe = (() async {
        final head = await client.send(http.Request('HEAD', uri));
        await head.stream.listen((_) {}).cancel();
        checkCurrent();
        if (head.statusCode >= 400 &&
            head.statusCode != 405 &&
            head.statusCode != 501) {
          throw const CastMediaException('The stream could not be reached.');
        }
        final declared = _normalize(head.headers['content-type']);
        if (declared != null) return declared;
        final extension = _extensionType(uri.path);
        if (extension != null) return extension;
        final request = http.Request('GET', uri)
          ..headers['Range'] = 'bytes=0-511';
        final response = await client.send(request);
        checkCurrent();
        if (response.statusCode >= 400) {
          throw const CastMediaException('The stream could not be reached.');
        }
        final bodyType = _normalize(response.headers['content-type']);
        if (bodyType != null) return bodyType;
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          bytes.addAll(chunk.take(512 - bytes.length));
          checkCurrent();
          if (bytes.length >= 512 || _sniff(bytes) != null) break;
        }
        return _sniff(bytes);
      })();
      final type =
          await (cancellation == null
                  ? probe
                  : Future.any([probe, cancellation]))
              .timeout(timeout);
      checkCurrent();
      if (type == null) {
        throw const CastMediaException(
          'This stream format could not be identified for TV playback.',
        );
      }
      return CastMedia(
        id: id,
        url: url,
        title: title,
        contentType: type,
        imageUrl: imageUrl,
        isLive: isLive,
        position: isLive ? Duration.zero : position,
      );
    } on CastMediaException {
      rethrow;
    } catch (_) {
      throw const CastMediaException(
        'The stream could not be checked. Try again.',
      );
    } finally {
      didCancel = true;
      client.close();
    }
  }

  static String? _normalize(String? value) =>
      switch (value?.split(';').first.trim().toLowerCase()) {
        'application/vnd.apple.mpegurl' ||
        'application/x-mpegurl' ||
        'audio/mpegurl' ||
        'audio/x-mpegurl' => 'application/x-mpegURL',
        'video/mp2t' || 'video/mpegts' => 'video/mp2t',
        'video/mp4' || 'application/mp4' => 'video/mp4',
        'application/dash+xml' => 'application/dash+xml',
        'video/webm' => 'video/webm',
        _ => null,
      };

  static String? _extensionType(String path) =>
      switch (path.toLowerCase().split('.').last) {
        'm3u8' => 'application/x-mpegURL',
        'mp4' || 'm4v' => 'video/mp4',
        'ts' => 'video/mp2t',
        'mpd' => 'application/dash+xml',
        'webm' => 'video/webm',
        _ => null,
      };

  static String? _sniff(List<int> bytes) {
    final prefix = utf8.decode(bytes, allowMalformed: true).trimLeft();
    if (prefix.startsWith('#EXTM3U')) return 'application/x-mpegURL';
    if (bytes.length >= 8 &&
        ascii.decode(bytes.sublist(4, 8), allowInvalid: true) == 'ftyp') {
      return 'video/mp4';
    }
    if (bytes.length > 188 && bytes[0] == 0x47 && bytes[188] == 0x47) {
      return 'video/mp2t';
    }
    return null;
  }
}
