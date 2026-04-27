import 'dart:convert';
import 'dart:io';

import 'vuplus_api.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../models/models.dart';
import 'api_client.dart';
import 'channel_sort.dart';
import 'playlist_search.dart';

export 'channel_sort.dart' show ChannelSortOrder;
export 'playlist_search.dart' show SearchResultItem, SearchResultType;

class PlaylistStore extends ChangeNotifier {
  PlaylistStore({required this.api});

  VuplusApi _selectedVuplusApi() {
    final playlist = selectedPlaylist;
    if (playlist == null) {
      throw const ApiException('No selected playlist');
    }
    if (playlist.type != 'vuplus') {
      throw const ApiException('Selected playlist is not a VU+ playlist');
    }
    final ip = (playlist.vuplusIp ?? '').trim();
    if (ip.isEmpty) {
      throw const ApiException('VU+ IP is missing on selected playlist');
    }
    final port = (playlist.vuplusPort ?? '').trim().isEmpty
        ? '80'
        : playlist.vuplusPort!.trim();
    final host = ip.startsWith('http://') || ip.startsWith('https://')
        ? '$ip:$port'
        : 'http://$ip:$port';
    return VuplusApi(host: host);
  }

  // Fetch channels directly from VU+
  Future<void> fetchChannelsFromVuplus({String? bouquet}) async {
    loadingChannels = true;
    notifyListeners();
    try {
      final vuplusApi = _selectedVuplusApi();
      final xml = await vuplusApi.fetchChannels(serviceRef: bouquet);
      final services = _parseE2Services(xml);
      final parsed = <Channel>[];
      var index = 0;
      for (final s in services) {
        final ref = s['ref'] ?? '';
        if (!ref.startsWith('1:0:')) {
          continue;
        }
        parsed.add(
          Channel(
            id: _channelIdFor(selectedPlaylistId ?? 0, ref, index),
            playlistId: selectedPlaylistId ?? 0,
            streamId: ref,
            name: (s['name'] ?? '').isEmpty ? 'Unknown channel' : s['name']!,
            groupName: selectedGroup ?? 'Uncategorized',
            streamUrl: '',
            logoUrl: vuplusApi.piconUrl(ref),
            epgChannelId: ref,
            sortOrder: index,
            isFavorite: false,
          ),
        );
        index++;
      }
      channels = sortChannels(parsed, channelSortOrder);
    } finally {
      loadingChannels = false;
      notifyListeners();
    }
  }

  // Fetch EPG directly from VU+
  Future<void> fetchEpgFromVuplus(String serviceRef) async {
    loadingEpg = true;
    notifyListeners();
    try {
      final vuplusApi = _selectedVuplusApi();
      final xml = await vuplusApi.fetchEpg(serviceRef);
      epgEntries = _parseVuplusEpg(xml, serviceRef);
    } finally {
      loadingEpg = false;
      notifyListeners();
    }
  }

  // Fetch timers directly from VU+
  Future<void> fetchTimersFromVuplus() async {
    final vuplusApi = _selectedVuplusApi();
    final xml = await vuplusApi.fetchTimers();
    _vuplusTimerList = _parseVuplusTimers(xml);
    _timerKeys = _parseVuplusTimerKeys(xml);
    notifyListeners();
  }

  // Add timer directly to VU+
  Future<void> recordEpgEntry(EpgEntry entry) async {
    final vuplusApi = _selectedVuplusApi();
    final beginUnix = entry.startTime.toUtc().millisecondsSinceEpoch ~/ 1000;
    final endUnix = entry.endTime.toUtc().millisecondsSinceEpoch ~/ 1000;
    final key = _timerKeyFromServiceRefAndBegin(entry.channelEpgId, beginUnix);

    await vuplusApi.addTimer({
      'sRef': entry.channelEpgId,
      'begin': beginUnix.toString(),
      'end': endUnix.toString(),
      'name': entry.title,
      'description': entry.description,
      'disabled': '0',
      'justplay': '0',
      'afterevent': '3',
      // Add other timer params as needed
    });

    _timerKeys = Set.from(_timerKeys)..add(key);
    notifyListeners();
  }

  // Remove timer directly from VU+
  Future<void> removeEpgTimer(EpgEntry entry) async {
    final vuplusApi = _selectedVuplusApi();
    final beginUnix = entry.startTime.toUtc().millisecondsSinceEpoch ~/ 1000;

    // Use exact values from timerlist; OpenWebif delete can require matching end.
    final timersXml = await vuplusApi.fetchTimers();
    final timers = _parseVuplusTimers(timersXml);
    final normalizedEntryRef = _normalizeServiceRef(entry.channelEpgId);

    VuplusTimer? match;
    for (final t in timers) {
      if (_normalizeServiceRef(t.channelEpgId) == normalizedEntryRef &&
          t.beginUnix == beginUnix) {
        match = t;
        break;
      }
    }

    match ??= timers.cast<VuplusTimer?>().firstWhere(
      (t) =>
          t != null &&
          _normalizeServiceRef(t.channelEpgId) == normalizedEntryRef &&
          (t.beginUnix - beginUnix).abs() <= 180,
      orElse: () => null,
    );

    if (match != null) {
      await vuplusApi.deleteTimer(
        begin: match.beginUnix.toString(),
        serviceRef: match.channelEpgId,
        end: match.endUnix.toString(),
      );
    } else {
      final endUnix = entry.endTime.toUtc().millisecondsSinceEpoch ~/ 1000;
      await vuplusApi.deleteTimer(
        begin: beginUnix.toString(),
        serviceRef: entry.channelEpgId,
        end: endUnix.toString(),
      );
    }

    final refreshedTimersXml = await vuplusApi.fetchTimers();
    _vuplusTimerList = _parseVuplusTimers(refreshedTimersXml);
    _timerKeys = _parseVuplusTimerKeys(refreshedTimersXml);
    notifyListeners();
  }

  // Get picon URL for a service
  String getPiconUrl(String serviceRef) {
    final vuplusApi = _selectedVuplusApi();
    return vuplusApi.piconUrl(serviceRef);
  }

  final ApiClient api;
  final Map<int, List<Channel>> _playlistChannelsCache = {};
  final Map<int, Future<List<Channel>>> _playlistChannelsInFlight = {};
  final Map<int, String> _runtimeEpgUrlByPlaylist = {};

  // XMLTV cache: url -> (fetchedAt, rawXml)
  final Map<String, ({DateTime fetchedAt, String xml})> _xmltvCache = {};
  static const Duration _xmltvCacheTtl = Duration(minutes: 30);

  bool _isMaskedXtreamPassword(String? value) => (value ?? '').trim() == '***';

  String _sanitizeUrlForLog(String value) {
    final parsed = Uri.tryParse(value);
    if (parsed == null || !parsed.hasScheme) {
      return value;
    }
    final qp = Map<String, String>.from(parsed.queryParameters);
    if (qp.containsKey('password')) {
      qp['password'] = '***';
    }
    return parsed.replace(queryParameters: qp).toString();
  }

  Future<http.Response> _httpGetWithRetry(
    Uri uri, {
    Map<String, String>? headers,
    int maxAttempts = 3,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final response = await http.get(uri, headers: headers);
        final code = response.statusCode;
        final retriable =
            code == 429 || code == 502 || code == 503 || code == 504;
        if (!retriable || attempt == maxAttempts) {
          return response;
        }
      } catch (e) {
        lastError = e;
        if (attempt == maxAttempts) {
          rethrow;
        }
      }

      await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
    }

    throw ApiException('HTTP request failed for $uri: $lastError');
  }

  Future<String> _readTextFromUrlOrFile(
    String source, {
    Map<String, String>? requestHeaders,
  }) async {
    final trimmed = source.trim();
    if (trimmed.isEmpty) {
      throw const ApiException('Source URL is empty');
    }

    if (trimmed.startsWith('file://')) {
      final uri = Uri.parse(trimmed);
      return File.fromUri(uri).readAsString();
    }

    if (trimmed.startsWith('/')) {
      return File(trimmed).readAsString();
    }

    final uri = Uri.parse(trimmed);
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      final response = await _httpGetWithRetry(
        uri,
        headers: requestHeaders,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException(
          'HTTP ${response.statusCode} while fetching ${_sanitizeUrlForLog(trimmed)}',
        );
      }
      return response.body;
    }

    throw ApiException('Unsupported source URI: $trimmed');
  }

  String _resolveUrl(String base, String value) {
    final v = value.trim();
    if (v.isEmpty) return v;
    final parsed = Uri.tryParse(v);
    if (parsed != null && parsed.hasScheme) {
      return v;
    }
    final baseUri = Uri.tryParse(base.trim());
    if (baseUri == null) return v;
    return baseUri.resolve(v).toString();
  }

  int _channelIdFor(int playlistId, String streamId, int index) {
    final seed = streamId.isEmpty ? 'idx:$index' : streamId;
    final hash = seed.hashCode & 0x7fffffff;
    return (playlistId * 1000003) ^ hash;
  }

  Playlist _playlistById(int playlistId) {
    for (final p in playlists) {
      if (p.id == playlistId) return p;
    }
    throw ApiException('Playlist $playlistId not found');
  }

  String? _extractAttr(String line, String attr) {
    final quoted = RegExp(
      '$attr="([^"]*)"',
      caseSensitive: false,
    ).firstMatch(line)?.group(1);
    if (quoted != null && quoted.isNotEmpty) return quoted.trim();

    final plain = RegExp(
      '$attr=([^\\s]+)',
      caseSensitive: false,
    ).firstMatch(line)?.group(1);
    return plain?.trim();
  }

  Future<List<Channel>> _loadM3uChannels(
    Playlist playlist, {
    Map<String, String>? requestHeaders,
  }) async {
    final source = (playlist.m3uUrl ?? '').trim();
    if (source.isEmpty) return const [];

    final raw = await _readTextFromUrlOrFile(
      source,
      requestHeaders: requestHeaders,
    );
    final lines = const LineSplitter().convert(raw);
    final out = <Channel>[];

    String pendingName = '';
    String pendingGroup = 'Uncategorized';
    String pendingLogo = '';
    String pendingEpgId = '';

    var idx = 0;
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXTM3U')) {
        final discovered =
            _extractAttr(line, 'url-tvg') ??
            _extractAttr(line, 'x-tvg-url') ??
            _extractAttr(line, 'tvg-url');
        if (discovered != null && discovered.isNotEmpty) {
          _runtimeEpgUrlByPlaylist[playlist.id] = discovered;
        }
        continue;
      }

      if (line.startsWith('#EXTINF:')) {
        pendingName = _extractAttr(line, 'tvg-name') ?? '';
        if (pendingName.isEmpty) {
          final comma = line.lastIndexOf(',');
          if (comma >= 0 && comma < line.length - 1) {
            pendingName = line.substring(comma + 1).trim();
          }
        }
        pendingGroup = _extractAttr(line, 'group-title') ?? 'Uncategorized';
        pendingLogo = _extractAttr(line, 'tvg-logo') ?? '';
        pendingEpgId = _extractAttr(line, 'tvg-id') ?? '';
        continue;
      }

      if (line.startsWith('#')) continue;

      final streamUrl = _resolveUrl(source, line);
      final name = pendingName.isEmpty ? 'Channel ${idx + 1}' : pendingName;
      final streamId = line;

      out.add(
        Channel(
          id: _channelIdFor(playlist.id, streamId, idx),
          playlistId: playlist.id,
          streamId: streamId,
          name: name,
          groupName: pendingGroup.isEmpty ? 'Uncategorized' : pendingGroup,
          streamUrl: streamUrl,
          logoUrl: pendingLogo,
          epgChannelId: pendingEpgId,
          sortOrder: idx,
          isFavorite: false,
        ),
      );
      idx++;

      pendingName = '';
      pendingGroup = 'Uncategorized';
      pendingLogo = '';
      pendingEpgId = '';
    }

    return out;
  }

  Future<List<Channel>> _loadXtreamChannels(Playlist playlist) async {
    final server = (playlist.xtreamServer ?? '').trim().replaceAll(
      RegExp(r'/+$'),
      '',
    );
    final user = (playlist.xtreamUsername ?? '').trim();
    final pass = (playlist.xtreamPassword ?? '').trim();
    if (_isMaskedXtreamPassword(pass)) {
      throw const ApiException(
        'Xtream password is masked. Open Edit Playlist and enter the Xtream password again.',
      );
    }
    if (server.isEmpty || user.isEmpty || pass.isEmpty) return const [];

    final headers = <String, String>{
      'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)',
      'Accept': 'application/json,text/plain,*/*',
      'Connection': 'keep-alive',
    };

    Future<List<dynamic>?> fetchXtreamAction(String action) async {
      final endpointCandidates = <String>['player_api.php', 'panel_api.php'];
      for (final endpoint in endpointCandidates) {
        final uri = Uri.parse('$server/$endpoint').replace(
          queryParameters: {
            'username': user,
            'password': pass,
            'action': action,
          },
        );
        try {
          final response = await _httpGetWithRetry(
            uri,
            headers: headers,
          );
          if (response.statusCode < 200 || response.statusCode >= 300) {
            continue;
          }
          final decoded = jsonDecode(response.body);
          if (decoded is List<dynamic>) {
            return decoded;
          }
        } catch (_) {
        }
      }
      return null;
    }

    final categoriesJson = await fetchXtreamAction('get_live_categories');
    final streamsJson = await fetchXtreamAction('get_live_streams');
    if (categoriesJson == null || streamsJson == null) {
      return _loadXtreamChannelsFromM3u(
        playlist,
        server: server,
        username: user,
        password: pass,
      );
    }

    final categoryNames = <String, String>{};
    for (final row in categoriesJson) {
      final m = row as Map<String, dynamic>;
      final id = (m['category_id'] ?? '').toString();
      final name = (m['category_name'] ?? '').toString();
      if (id.isNotEmpty) categoryNames[id] = name;
    }

    final out = <Channel>[];
    for (var i = 0; i < streamsJson.length; i++) {
      final m = streamsJson[i] as Map<String, dynamic>;
      final streamId = (m['stream_id'] ?? '').toString();
      if (streamId.isEmpty) continue;

      final categoryId = (m['category_id'] ?? '').toString();
      final groupName = categoryNames[categoryId] ?? 'Uncategorized';
      final fallbackUrl = '$server/live/$user/$pass/$streamId.ts';
      final directSource = (m['direct_source'] ?? '').toString().trim();

      out.add(
        Channel(
          id: _channelIdFor(playlist.id, streamId, i),
          playlistId: playlist.id,
          streamId: streamId,
          name: (m['name'] ?? 'Unknown channel').toString(),
          groupName: groupName,
          streamUrl: directSource.isNotEmpty ? directSource : fallbackUrl,
          logoUrl: (m['stream_icon'] ?? '').toString(),
          epgChannelId: (m['epg_channel_id'] ?? '').toString(),
          sortOrder: i,
          isFavorite: false,
        ),
      );
    }

    if ((playlist.epgUrl ?? '').trim().isEmpty) {
      _runtimeEpgUrlByPlaylist[playlist.id] =
          '$server/xmltv.php?username=$user&password=$pass';
    }

    return out;
  }

  Future<List<Channel>> _loadXtreamChannelsFromM3u(
    Playlist playlist, {
    required String server,
    required String username,
    required String password,
  }) async {
    final serverUri = Uri.tryParse(server);
    if (serverUri == null || !serverUri.hasAuthority) {
      throw const ApiException('Invalid Xtream server URL');
    }

    final baseCandidates = <Uri>{serverUri};
    if (serverUri.scheme == 'http') {
      baseCandidates.add(serverUri.replace(scheme: 'https'));
    }

    final m3uCandidates = <String>[];
    final seen = <String>{};
    for (final base in baseCandidates) {
      for (final type in const ['m3u_plus', 'm3u']) {
        for (final output in const ['ts', 'm3u8']) {
          final url = base
              .replace(
                path: '${base.path.replaceAll(RegExp(r'/+$'), '')}/get.php',
                queryParameters: {
                  'username': username,
                  'password': password,
                  'type': type,
                  'output': output,
                },
              )
              .toString();
          if (seen.add(url)) {
            m3uCandidates.add(url);
          }
        }
      }

      final noOutput = base
          .replace(
            path: '${base.path.replaceAll(RegExp(r'/+$'), '')}/get.php',
            queryParameters: {
              'username': username,
              'password': password,
              'type': 'm3u_plus',
            },
          )
          .toString();
      if (seen.add(noOutput)) {
        m3uCandidates.add(noOutput);
      }
    }

    Object? lastError;
    for (var i = 0; i < m3uCandidates.length; i++) {
      final m3uUrl = m3uCandidates[i];
      final fallbackPlaylist = Playlist(
        id: playlist.id,
        name: playlist.name,
        type: 'm3u',
        m3uUrl: m3uUrl,
        epgUrl: playlist.epgUrl,
        xtreamServer: playlist.xtreamServer,
        xtreamUsername: playlist.xtreamUsername,
        xtreamPassword: playlist.xtreamPassword,
        vuplusIp: playlist.vuplusIp,
        vuplusPort: playlist.vuplusPort,
        lastRefreshed: playlist.lastRefreshed,
      );

      try {
        final loaded = await _loadM3uChannels(
          fallbackPlaylist,
          requestHeaders: {
            'User-Agent':
                'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36',
            'Accept':
                'application/x-mpegURL,application/vnd.apple.mpegurl,application/octet-stream,text/plain,*/*',
            'Connection': 'keep-alive',
          },
        );
        if (loaded.isNotEmpty) {
          if ((playlist.epgUrl ?? '').trim().isEmpty) {
            _runtimeEpgUrlByPlaylist[playlist.id] =
                '$server/xmltv.php?username=$username&password=$password';
          }
          return loaded;
        }
      } catch (e) {
        lastError = e;
      }
    }

    if (lastError != null) {
      throw ApiException(
        'Xtream M3U fallback failed after ${m3uCandidates.length} attempts: $lastError',
      );
    }

    throw const ApiException(
      'Xtream source blocked player_api and M3U fallback returned no channels',
    );
  }

  List<Map<String, String>> _parseE2Services(String xmlRaw) {
    final doc = XmlDocument.parse(xmlRaw);
    return doc.findAllElements('e2service').map((node) {
      return {
        'ref': node.getElement('e2servicereference')?.innerText.trim() ?? '',
        'name': node.getElement('e2servicename')?.innerText.trim() ?? '',
      };
    }).toList();
  }

  List<Map<String, String>> _parseE2Movies(String xmlRaw) {
    final doc = XmlDocument.parse(xmlRaw);
    return doc.findAllElements('e2movie').map((node) {
      return {
        'ref': node.getElement('e2servicereference')?.innerText.trim() ?? '',
        'title': node.getElement('e2title')?.innerText.trim() ?? '',
        'name': node.getElement('e2servicename')?.innerText.trim() ?? '',
        'file': node.getElement('e2filename')?.innerText.trim() ?? '',
      };
    }).toList();
  }

  VuplusApi _vuplusApiForPlaylist(Playlist playlist) {
    if (playlist.type != 'vuplus') {
      throw const ApiException('Selected playlist is not a VU+ playlist');
    }
    final ip = (playlist.vuplusIp ?? '').trim();
    if (ip.isEmpty) {
      throw const ApiException('VU+ IP is missing on selected playlist');
    }
    final port = (playlist.vuplusPort ?? '').trim().isEmpty
        ? '80'
        : playlist.vuplusPort!.trim();
    final host = ip.startsWith('http://') || ip.startsWith('https://')
        ? '$ip:$port'
        : 'http://$ip:$port';
    return VuplusApi(host: host);
  }

  Future<List<Channel>> _loadVuplusChannels(Playlist playlist) async {
    final vuplusApi = _vuplusApiForPlaylist(playlist);
    final baseUri = Uri.parse(vuplusApi.host);
    final streamBase = '${baseUri.scheme}://${baseUri.host}:8001';

    final rootXml = await vuplusApi.fetchChannels();
    final bouquets = _parseE2Services(
      rootXml,
    ).where((b) => (b['ref'] ?? '').startsWith('1:7:')).toList();

    final out = <Channel>[];
    var idx = 0;
    for (final bouquet in bouquets) {
      final bouquetRef = bouquet['ref'] ?? '';
      final bouquetName = (bouquet['name'] ?? '').isEmpty
          ? 'Uncategorized'
          : bouquet['name']!;
      if (bouquetRef.isEmpty) continue;

      final channelsXml = await vuplusApi.fetchChannels(serviceRef: bouquetRef);
      final services = _parseE2Services(
        channelsXml,
      ).where((s) => (s['ref'] ?? '').startsWith('1:0:')).toList();

      for (final service in services) {
        final svcRef = service['ref'] ?? '';
        final svcName = service['name'] ?? '';
        if (svcRef.isEmpty || svcName.isEmpty) continue;

        out.add(
          Channel(
            id: _channelIdFor(playlist.id, svcRef, idx),
            playlistId: playlist.id,
            streamId: svcRef,
            name: svcName,
            groupName: bouquetName,
            streamUrl: '$streamBase/${Uri.encodeComponent(svcRef)}',
            logoUrl: vuplusApi.piconUrl(svcRef),
            epgChannelId: svcRef,
            sortOrder: idx,
            isFavorite: false,
          ),
        );
        idx++;
      }
    }

    // Append VU+ recordings as a dedicated pseudo-group.
    try {
      final movieRootRef = '2:0:1:0:0:0:0:0:0:0:/hdd/movie/';
      final moviesXml = await vuplusApi.fetchMovieList(
        serviceRef: movieRootRef,
      );
      final movies = _parseE2Movies(moviesXml);

      for (final movie in movies) {
        final movieRef = movie['ref'] ?? '';
        final movieTitle = (movie['title'] ?? '').isNotEmpty
            ? movie['title']!
            : ((movie['name'] ?? '').isNotEmpty
                  ? movie['name']!
                  : 'Recording ${idx + 1}');
        final movieFile = movie['file'] ?? '';
        if (movieRef.isEmpty && movieFile.isEmpty) {
          continue;
        }

        final streamUrl = movieFile.isNotEmpty
            ? '${vuplusApi.host}/file?file=${Uri.encodeQueryComponent(movieFile)}'
            : '$streamBase/${Uri.encodeComponent(movieRef)}';

        out.add(
          Channel(
            id: _channelIdFor(
              playlist.id,
              movieRef.isNotEmpty ? movieRef : movieFile,
              idx,
            ),
            playlistId: playlist.id,
            streamId: movieRef.isNotEmpty ? movieRef : movieFile,
            name: movieTitle,
            groupName: 'Aufnahmen',
            streamUrl: streamUrl,
            logoUrl: '',
            epgChannelId: movieRef,
            sortOrder: idx,
            isFavorite: false,
          ),
        );
        idx++;
      }
    } catch (_) {
      // Optional group: ignore if movielist endpoint is unavailable.
    }

    return out;
  }

  Future<List<Channel>> _loadChannelsForPlaylist(Playlist playlist) async {
    switch (playlist.type) {
      case 'm3u':
        return _loadM3uChannels(playlist);
      case 'xtream':
        return _loadXtreamChannels(playlist);
      case 'vuplus':
        return _loadVuplusChannels(playlist);
      default:
        return const [];
    }
  }

  Future<Playlist> _loadPlaylistSourceForRefresh(int playlistId) async {
    final raw = await api.get('/playlists/$playlistId/source');
    return Playlist.fromJson(raw as Map<String, dynamic>);
  }

  Future<List<Channel>> _loadChannelsFromBackend(int playlistId) async {
    final raw =
        await api.get('/playlists/$playlistId/channels') as List<dynamic>;
    return raw.map((e) => Channel.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> _persistChannelsToBackend({
    required int playlistId,
    required Playlist sourcePlaylist,
    required List<Channel> channels,
  }) async {
    final configuredEpg = (sourcePlaylist.epgUrl ?? '').trim();
    final discoveredEpg = (_runtimeEpgUrlByPlaylist[playlistId] ?? '').trim();
    final epgToPersist = configuredEpg.isNotEmpty
        ? configuredEpg
        : discoveredEpg;

    final body = <String, dynamic>{
      'channels': channels
          .asMap()
          .entries
          .map(
            (entry) => {
              'stream_id': entry.value.streamId,
              'name': entry.value.name,
              'group_name': entry.value.groupName,
              'stream_url': entry.value.streamUrl,
              'logo_url': entry.value.logoUrl,
              'epg_channel_id': entry.value.epgChannelId,
              'sort_order': entry.key,
            },
          )
          .toList(),
      if (epgToPersist.isNotEmpty) 'epg_url': epgToPersist,
    };

    await api.put('/playlists/$playlistId/channels', body);
  }

  Future<List<Channel>> _getOrLoadPlaylistChannels(
    int playlistId, {
    bool force = false,
  }) async {
    if (!force) {
      final cached = _playlistChannelsCache[playlistId];
      if (cached != null) return cached;
    }

    final existing = _playlistChannelsInFlight[playlistId];
    if (existing != null) return existing;

    final future = () async {
      List<Channel> loaded;
      if (force) {
        final sourcePlaylist = await _loadPlaylistSourceForRefresh(playlistId);
        loaded = await _loadChannelsForPlaylist(sourcePlaylist);
        await _persistChannelsToBackend(
          playlistId: playlistId,
          sourcePlaylist: sourcePlaylist,
          channels: loaded,
        );
      } else {
        loaded = await _loadChannelsFromBackend(playlistId);
      }

      final sorted = sortChannels(
        _applyFavoriteFlagsToChannels(loaded),
        channelSortOrder,
      );
      _playlistChannelsCache[playlistId] = sorted;
      return sorted;
    }();

    _playlistChannelsInFlight[playlistId] = future;
    try {
      return await future;
    } finally {
      _playlistChannelsInFlight.remove(playlistId);
    }
  }

  DateTime? _parseXmltvDate(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return null;
    final m = RegExp(r'^(\d{14})(?:\s+([+-]\d{4}))?').firstMatch(raw);
    if (m == null) return null;

    final digits = m.group(1)!;
    final year = int.parse(digits.substring(0, 4));
    final month = int.parse(digits.substring(4, 6));
    final day = int.parse(digits.substring(6, 8));
    final hour = int.parse(digits.substring(8, 10));
    final minute = int.parse(digits.substring(10, 12));
    final second = int.parse(digits.substring(12, 14));

    final utc = DateTime.utc(year, month, day, hour, minute, second);
    final offset = m.group(2);
    if (offset == null) {
      return utc.toLocal();
    }

    final sign = offset.startsWith('-') ? -1 : 1;
    final offHours = int.parse(offset.substring(1, 3));
    final offMinutes = int.parse(offset.substring(3, 5));
    final totalMinutes = sign * (offHours * 60 + offMinutes);
    return utc.subtract(Duration(minutes: totalMinutes)).toLocal();
  }

  String _normalizeEpgMatchText(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  bool _roughEpgNameMatch(String left, String right) {
    if (left.isEmpty || right.isEmpty) return false;
    if (left == right) return true;
    if (left.length >= 5 && right.contains(left)) return true;
    if (right.length >= 5 && left.contains(right)) return true;
    return false;
  }

  Future<List<EpgEntry>> _loadXmltvEpgForChannel(
    Playlist playlist,
    Channel channel,
  ) async {
    final configured = (playlist.epgUrl ?? '').trim();
    final discovered = (_runtimeEpgUrlByPlaylist[playlist.id] ?? '').trim();
    final epgUrl = configured.isNotEmpty ? configured : discovered;
    if (epgUrl.isEmpty) {
      return const [];
    }

    final cached = _xmltvCache[epgUrl];
    final String xmlRaw;
    if (cached != null &&
        DateTime.now().difference(cached.fetchedAt) < _xmltvCacheTtl) {
      xmlRaw = cached.xml;
    } else {
      xmlRaw = await _readTextFromUrlOrFile(epgUrl);
      _xmltvCache[epgUrl] = (fetchedAt: DateTime.now(), xml: xmlRaw);
    }
    final doc = XmlDocument.parse(xmlRaw);

    final candidateChannelIds = <String>{};
    final targetId = channel.epgChannelId.trim().toLowerCase();
    final normalizedChannelName = _normalizeEpgMatchText(channel.name);


    if (targetId.isNotEmpty) {
      candidateChannelIds.add(targetId);
    }

    // Only do name-based fallback when there is no explicit epgChannelId,
    // to avoid false positives from loose substring matching.
    if (targetId.isEmpty && normalizedChannelName.isNotEmpty) {
      final allXmlChannels = doc.findAllElements('channel').toList();
      for (final xmlChannel in allXmlChannels) {
        final xmlId = (xmlChannel.getAttribute('id') ?? '')
            .trim()
            .toLowerCase();
        if (xmlId.isEmpty) continue;

        final normalizedXmlId = _normalizeEpgMatchText(xmlId);
        if (_roughEpgNameMatch(normalizedChannelName, normalizedXmlId)) {
          candidateChannelIds.add(xmlId);
          continue;
        }

        final displayNames = xmlChannel
            .findElements('display-name')
            .map((e) => _normalizeEpgMatchText(e.innerText.trim()))
            .where((v) => v.isNotEmpty)
            .toList();
        final hasDisplayMatch = displayNames.any(
          (v) => _roughEpgNameMatch(normalizedChannelName, v),
        );
        if (hasDisplayMatch) {
          candidateChannelIds.add(xmlId);
        }
      }
    }

    if (candidateChannelIds.isEmpty) {
      return const [];
    }

    final allProgrammes = doc.findAllElements('programme').toList();
    final entries = <EpgEntry>[];
    for (final programme in allProgrammes) {
      final channelIdAttr = (programme.getAttribute('channel') ?? '')
          .trim()
          .toLowerCase();
      if (!candidateChannelIds.contains(channelIdAttr)) continue;

      final start = _parseXmltvDate(programme.getAttribute('start') ?? '');
      final end = _parseXmltvDate(programme.getAttribute('stop') ?? '');
      if (start == null || end == null || !end.isAfter(start)) continue;

      final title = programme.findElements('title').isEmpty
          ? ''
          : programme.findElements('title').first.innerText.trim();
      final desc = programme.findElements('desc').isEmpty
          ? ''
          : programme.findElements('desc').first.innerText.trim();

      entries.add(
        EpgEntry(
          channelEpgId: channel.epgChannelId.isNotEmpty
              ? channel.epgChannelId
              : channelIdAttr,
          startTime: start,
          endTime: end,
          title: title,
          description: desc,
        ),
      );
    }

    entries.sort((a, b) => a.startTime.compareTo(b.startTime));

    // Deduplicate entries with the same start time (feed may list same slot multiple times)
    final seen = <DateTime>{};
    final deduped = entries.where((e) => seen.add(e.startTime)).toList();

    return deduped;
  }

  List<EpgEntry> _parseVuplusEpg(String xmlRaw, String fallbackServiceRef) {
    final doc = XmlDocument.parse(xmlRaw);
    final out = <EpgEntry>[];

    for (final event in doc.findAllElements('e2event')) {
      final beginRaw =
          event.getElement('e2eventstart')?.innerText.trim() ??
          event.getElement('e2eventstarttimestamp')?.innerText.trim() ??
          '';
      final durationRaw =
          event.getElement('e2eventduration')?.innerText.trim() ?? '';
      final beginUnix = int.tryParse(beginRaw) ?? 0;
      final durationSec = int.tryParse(durationRaw) ?? 0;
      if (beginUnix <= 0 || durationSec <= 0) continue;

      final start = DateTime.fromMillisecondsSinceEpoch(
        beginUnix * 1000,
        isUtc: true,
      ).toLocal();
      final end = start.add(Duration(seconds: durationSec));

      final title = event.getElement('e2eventtitle')?.innerText.trim() ?? '';
      final shortDesc =
          event.getElement('e2eventdescription')?.innerText.trim() ?? '';
      final extDesc =
          event.getElement('e2eventdescriptionextended')?.innerText.trim() ??
          '';
      final desc = [shortDesc, extDesc].where((s) => s.isNotEmpty).join('\n');

      final serviceRef =
          event.getElement('e2eventservicereference')?.innerText.trim() ??
          fallbackServiceRef;

      out.add(
        EpgEntry(
          channelEpgId: serviceRef,
          startTime: start,
          endTime: end,
          title: title,
          description: desc,
        ),
      );
    }

    out.sort((a, b) => a.startTime.compareTo(b.startTime));
    return out;
  }

  Set<String> _parseVuplusTimerKeys(String xmlRaw) {
    final doc = XmlDocument.parse(xmlRaw);
    final out = <String>{};

    for (final timer in doc.findAllElements('e2timer')) {
      final ref =
          timer.getElement('e2servicereference')?.innerText.trim() ?? '';
      final beginRaw = timer.getElement('e2timebegin')?.innerText.trim() ?? '';
      final begin = int.tryParse(beginRaw) ?? 0;
      if (ref.isEmpty || begin <= 0) continue;
      out.add(_timerKeyFromServiceRefAndBegin(ref, begin));
    }

    return out;
  }

  List<VuplusTimer> _parseVuplusTimers(String xmlRaw) {
    final doc = XmlDocument.parse(xmlRaw);
    final out = <VuplusTimer>[];

    for (final timer in doc.findAllElements('e2timer')) {
      final ref =
          timer.getElement('e2servicereference')?.innerText.trim() ?? '';
      final beginRaw = timer.getElement('e2timebegin')?.innerText.trim() ?? '';
      final endRaw = timer.getElement('e2timeend')?.innerText.trim() ?? '';
      final begin = int.tryParse(beginRaw) ?? 0;
      final end = int.tryParse(endRaw) ?? 0;
      if (ref.isEmpty || begin <= 0 || end <= 0) continue;

      out.add(
        VuplusTimer(
          channelEpgId: ref,
          beginUnix: begin,
          endUnix: end,
          name: timer.getElement('e2name')?.innerText.trim() ?? '',
          filename: timer.getElement('e2filename')?.innerText.trim() ?? '',
        ),
      );
    }

    return out;
  }

  List<Playlist> playlists = const [];
  List<Group> groups = const [];
  List<Channel> channels = const [];
  List<Group> _globalGroups = const [];
  List<Channel> _globalChannels = const [];
  List<Channel> favoriteChannels = const [];
  List<Group> favoriteGroups = const [];
  List<EpgEntry> epgEntries = const [];
  Set<String> _timerKeys = {};
  List<VuplusTimer> _vuplusTimerList = const [];
  Set<String> _favoriteSourceKeys = {};

  int? selectedPlaylistId;
  String? selectedGroup;
  Channel? nowPlaying;
  String searchQuery = '';

  bool loadingPlaylists = false;
  bool loadingGroups = false;
  bool loadingChannels = false;
  bool loadingGlobalSearch = false;
  bool loadingFavoriteChannels = false;
  bool loadingFavoriteGroups = false;
  bool _favoriteGroupsLoaded = false;
  bool loadingEpg = false;
  bool epgSourceMissing = false;
  final Set<int> _refreshingPlaylistIds = <int>{};
  ChannelSortOrder channelSortOrder = ChannelSortOrder.byIndex;

  bool isRefreshingPlaylist(int id) => _refreshingPlaylistIds.contains(id);

  bool get hasActiveSearch => searchQuery.trim().isNotEmpty;

  Playlist? get selectedPlaylist {
    final id = selectedPlaylistId;
    if (id == null) return null;
    for (final playlist in playlists) {
      if (playlist.id == id) {
        return playlist;
      }
    }
    return null;
  }

  bool get isSelectedPlaylistVuplus => selectedPlaylist?.type == 'vuplus';

  String _favoriteSourceKey(int playlistId, String streamId) {
    return '$playlistId:${streamId.trim().toLowerCase()}';
  }

  String _favoriteSourceKeyForChannel(Channel channel) {
    return _favoriteSourceKey(channel.playlistId, channel.streamId);
  }

  bool _isChannelFavoriteByKey(Channel channel) {
    return _favoriteSourceKeys.contains(_favoriteSourceKeyForChannel(channel));
  }

  List<Channel> _applyFavoriteFlagsToChannels(Iterable<Channel> values) {
    return values
        .map((c) => c.copyWith(isFavorite: _isChannelFavoriteByKey(c)))
        .toList();
  }

  void _reconcileFavoriteChannelFlags() {
    channels = sortChannels(
      _applyFavoriteFlagsToChannels(channels),
      channelSortOrder,
    );
    _globalChannels = sortChannels(
      _applyFavoriteFlagsToChannels(_globalChannels),
      channelSortOrder,
    );

    final updatedCache = <int, List<Channel>>{};
    for (final entry in _playlistChannelsCache.entries) {
      updatedCache[entry.key] = sortChannels(
        _applyFavoriteFlagsToChannels(entry.value),
        channelSortOrder,
      );
    }
    _playlistChannelsCache
      ..clear()
      ..addAll(updatedCache);

    if (nowPlaying != null) {
      nowPlaying = nowPlaying!.copyWith(
        isFavorite: _isChannelFavoriteByKey(nowPlaying!),
      );
    }
  }

  String _safeDecodeComponent(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }

  String _normalizeServiceRef(String raw) {
    final decoded = _safeDecodeComponent(raw).trim().toLowerCase();
    if (decoded.isEmpty) {
      return '';
    }

    final parts = decoded.split(':');
    if (parts.length >= 10) {
      return '${parts.take(10).join(':')}:';
    }
    return decoded;
  }

  String _timerKeyFromServiceRefAndBegin(String serviceRef, int beginUnix) {
    return '${_normalizeServiceRef(serviceRef)}:$beginUnix';
  }

  /// Returns true if [entry] has a matching timer scheduled on the VU+ box.
  bool isTimerScheduled(EpgEntry entry) {
    final beginUnix = entry.startTime.toUtc().millisecondsSinceEpoch ~/ 1000;
    final key = _timerKeyFromServiceRefAndBegin(entry.channelEpgId, beginUnix);
    return _timerKeys.contains(key);
  }

  /// Returns true if [channel] is a VU+ recording that is currently being written
  /// (i.e. there is an active timer whose service ref matches and whose end time
  /// is still in the future).
  /// Extracts the file path from an enigma2 movie service reference.
  /// E.g. `1:0:0:0:0:0:0:0:0:0:/hdd/recordings/Foo.ts` → `/hdd/recordings/Foo.ts`
  String _filePathFromMovieRef(String ref) {
    final parts = ref.split(':');
    final idx = parts.indexWhere((p) => p.startsWith('/'));
    if (idx < 0) return '';
    return parts.sublist(idx).join(':');
  }

  bool isChannelActivelyRecording(Channel channel) {
    if (channel.groupName != 'Aufnahmen') return false;
    final nowUnix = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final filePath = _filePathFromMovieRef(channel.epgChannelId);
    for (final t in _vuplusTimerList) {
      if (t.endUnix <= nowUnix) continue;
      if (filePath.isNotEmpty && t.filename.isNotEmpty) {
        // Strip video/cut-marker extensions: .ts, .mkv, .mp4, .sc, .ap
        final stripExt = RegExp(r'\.(ts|mkv|mp4|sc|ap)$', caseSensitive: false);
        final tFile = t.filename.replaceAll(stripExt, '');
        final cFile = filePath.replaceAll(stripExt, '');
        if (tFile == cFile) return true;
      }
    }
    return false;
  }

  // --- Derived list getters ---

  List<Group> get filteredGroups => filterGroups(groups, searchQuery);

  List<Group> get globalFilteredGroups {
    if (!hasActiveSearch) return const [];
    return filterGroups(_globalGroups, searchQuery);
  }

  List<Channel> get filteredChannels =>
      filterChannels(channels, searchQuery, channelSortOrder);

  List<Channel> get globalFilteredChannels {
    if (!hasActiveSearch) return const [];
    return filterChannels(_globalChannels, searchQuery, channelSortOrder);
  }

  // --- Favorite group helpers ---

  String _favoriteGroupDeletePath(int playlistId, String groupName) {
    final query = Uri(
      queryParameters: {'playlist_id': '$playlistId', 'group_name': groupName},
    ).query;
    return '/favorites/groups?$query';
  }

  String _favoriteGroupKey(int playlistId, String groupName) {
    return '$playlistId:${groupName.trim().toLowerCase()}';
  }

  List<Group> _mergeFavoriteFlagsIntoGroups(Iterable<Group> values) {
    final favoriteKeys = favoriteGroups
        .map((g) => _favoriteGroupKey(g.playlistId, g.name))
        .toSet();

    return values.map((g) {
      final key = _favoriteGroupKey(g.playlistId, g.name);
      return g.copyWith(isFavorite: g.isFavorite || favoriteKeys.contains(key));
    }).toList();
  }

  void _reconcileFavoriteFlags() {
    groups = sortGroups(_mergeFavoriteFlagsIntoGroups(groups));
    _globalGroups = sortGroups(_mergeFavoriteFlagsIntoGroups(_globalGroups));
  }

  bool isGroupFavorite(int playlistId, String groupName) {
    final key = _favoriteGroupKey(playlistId, groupName);
    return favoriteGroups
        .map((g) => _favoriteGroupKey(g.playlistId, g.name))
        .contains(key);
  }

  // --- Data fetching ---

  Future<void> ensureGlobalSearchData() async {
    if (loadingGlobalSearch) return;

    if (playlists.isEmpty) {
      await fetchPlaylists();
    }

    loadingGlobalSearch = true;
    notifyListeners();

    try {
      final allGroups = <Group>[];
      final allChannels = <Channel>[];

      for (final p in playlists) {
        List<Channel> playlistChannels;
        try {
          playlistChannels = await _getOrLoadPlaylistChannels(p.id);
        } catch (e) {
          debugPrint('Skipping playlist ${p.id} in global search: $e');
          continue;
        }
        allChannels.addAll(playlistChannels);

        final counts = <String, int>{};
        for (final c in playlistChannels) {
          final key = c.groupName.trim().isEmpty
              ? 'Uncategorized'
              : c.groupName;
          counts[key] = (counts[key] ?? 0) + 1;
        }
        allGroups.addAll(
          counts.entries.map(
            (e) => Group(
              name: e.key,
              playlistId: p.id,
              channelCount: e.value,
              isFavorite: false,
            ),
          ),
        );
      }

      final seenGroups = <String>{};
      _globalGroups = sortGroups(
        _mergeFavoriteFlagsIntoGroups(
          allGroups.where((g) {
            final key = '${g.playlistId}:${g.name.toLowerCase()}';
            if (seenGroups.contains(key)) return false;
            seenGroups.add(key);
            return true;
          }),
        ),
      );

      final seenChannels = <int>{};
      _globalChannels = sortChannels(
        allChannels.where((c) {
          if (seenChannels.contains(c.id)) return false;
          seenChannels.add(c.id);
          return true;
        }),
        channelSortOrder,
      );
    } finally {
      loadingGlobalSearch = false;
      notifyListeners();
    }
  }

  Future<void> bootstrap() async {
    await Future.wait([
      fetchPlaylists(),
      fetchFavoriteChannels(),
      fetchFavoriteGroups(),
    ]);
  }

  Future<void> fetchPlaylists() async {
    loadingPlaylists = true;
    notifyListeners();
    try {
      final list = (await api.get('/playlists') as List<dynamic>)
          .map((e) => Playlist.fromJson(e as Map<String, dynamic>))
          .toList();
      playlists = list;

      if (selectedPlaylistId == null && playlists.isNotEmpty) {
        await selectPlaylist(playlists.first.id);
      } else if (selectedPlaylistId != null &&
          !playlists.any((p) => p.id == selectedPlaylistId)) {
        selectedPlaylistId = null;
        groups = const [];
        channels = const [];
      }
    } finally {
      loadingPlaylists = false;
      notifyListeners();
    }
  }

  Future<void> selectPlaylist(int playlistId) async {
    selectedPlaylistId = playlistId;
    selectedGroup = null;
    epgEntries = const [];
    epgSourceMissing = false;
    nowPlaying = null;
    notifyListeners();

    await Future.wait([
      fetchGroups(playlistId),
      fetchChannels(playlistId, null),
    ]);
  }

  Future<void> fetchGroups(int playlistId) async {
    if (!_favoriteGroupsLoaded && !loadingFavoriteGroups) {
      await fetchFavoriteGroups();
    }

    loadingGroups = true;
    notifyListeners();
    try {
      final playlistChannels = await _getOrLoadPlaylistChannels(playlistId);
      final counts = <String, int>{};
      for (final channel in playlistChannels) {
        final groupName = channel.groupName.trim().isEmpty
            ? 'Uncategorized'
            : channel.groupName;
        counts[groupName] = (counts[groupName] ?? 0) + 1;
      }

      groups = sortGroups(
        _mergeFavoriteFlagsIntoGroups(
          counts.entries.map(
            (e) => Group(
              name: e.key,
              playlistId: playlistId,
              channelCount: e.value,
              isFavorite: false,
            ),
          ),
        ),
      );
    } catch (e) {
      groups = const [];
      debugPrint('Failed to fetch groups for playlist $playlistId: $e');
    } finally {
      loadingGroups = false;
      notifyListeners();
    }
  }

  Future<void> selectGroup(String? group) async {
    selectedGroup = group;
    notifyListeners();
    if (selectedPlaylistId == null) return;
    await fetchChannels(selectedPlaylistId!, group);
  }

  Future<void> fetchChannels(int playlistId, String? group) async {
    loadingChannels = true;
    notifyListeners();
    try {
      final playlistChannels = await _getOrLoadPlaylistChannels(playlistId);
      final selected = (group ?? '').trim();
      final filtered = selected.isEmpty
          ? playlistChannels
          : playlistChannels.where((c) => c.groupName == selected).toList();
      channels = sortChannels(filtered, channelSortOrder);
    } catch (e) {
      channels = const [];
      debugPrint('Failed to fetch channels for playlist $playlistId: $e');
    } finally {
      loadingChannels = false;
      notifyListeners();
    }
  }

  Future<void> play(Channel channel) async {
    nowPlaying = channel;
    epgEntries = const [];
    epgSourceMissing = false;
    notifyListeners();

    final effectiveEpgChannelId = channel.epgChannelId.isNotEmpty
        ? channel.epgChannelId
        : channel.streamId;

    if (effectiveEpgChannelId.isEmpty) {
      epgSourceMissing = true;
      notifyListeners();
      return;
    }

    final playlist = _playlistById(channel.playlistId);
    final isVuplusRecording =
        playlist.type == 'vuplus' &&
        channel.groupName.trim().toLowerCase() == 'aufnahmen';

    if (isVuplusRecording) {
      loadingEpg = true;
      notifyListeners();
      try {
        epgEntries = const [];
        epgSourceMissing = true;
        // Fetch timers so isChannelActivelyRecording() can match this recording.
        await fetchTimersFromVuplus();
      } finally {
        loadingEpg = false;
        notifyListeners();
      }
      return;
    }

    loadingEpg = true;
    notifyListeners();
    try {
      if (playlist.type == 'vuplus') {
        final vuplusApi = _vuplusApiForPlaylist(playlist);
        final epgXml = await vuplusApi.fetchEpg(effectiveEpgChannelId);
        epgEntries = _parseVuplusEpg(epgXml, effectiveEpgChannelId);

        try {
          final timersXml = await vuplusApi.fetchTimers();
          _vuplusTimerList = _parseVuplusTimers(timersXml);
          _timerKeys = _parseVuplusTimerKeys(timersXml);
        } catch (_) {
          _vuplusTimerList = const [];
          _timerKeys = {};
        }
      } else {
        epgEntries = await _loadXmltvEpgForChannel(playlist, channel);
        _timerKeys = {};
      }

      epgSourceMissing = epgEntries.isEmpty;
    } finally {
      loadingEpg = false;
      notifyListeners();
    }
  }

  void stopPlayback() {
    if (nowPlaying == null && epgEntries.isEmpty) {
      return;
    }

    nowPlaying = null;
    epgEntries = const [];
    epgSourceMissing = false;
    loadingEpg = false;
    notifyListeners();
  }

  Future<void> refreshSelectedPlaylist() async {
    final id = selectedPlaylistId;
    if (id == null) return;
    await refreshPlaylist(id);
  }

  Future<int?> refreshPlaylist(int id) async {
    if (_refreshingPlaylistIds.contains(id)) {
      return null;
    }

    _refreshingPlaylistIds.add(id);
    notifyListeners();
    try {
      final loaded = await _getOrLoadPlaylistChannels(id, force: true);
      final refreshedCount = loaded.length;

      if (selectedPlaylistId == id) {
        await fetchGroups(id);
        await fetchChannels(id, selectedGroup);
      }
      _globalGroups = const [];
      _globalChannels = const [];
      return refreshedCount;
    } finally {
      _refreshingPlaylistIds.remove(id);
      notifyListeners();
    }
  }

  // --- Favorites ---

  Future<void> toggleFavorite(Channel channel) async {
    final key = _favoriteSourceKeyForChannel(channel);
    if (channel.isFavorite) {
      await api.delete(
        '/favorites/channels?playlist_id=${channel.playlistId}&stream_id=${Uri.encodeQueryComponent(channel.streamId)}',
      );
    } else {
      await api.post('/favorites/channels', {
        'playlist_id': channel.playlistId,
        'stream_id': channel.streamId,
        'name': channel.name,
        'group_name': channel.groupName,
        'stream_url': channel.streamUrl,
        'logo_url': channel.logoUrl,
        'epg_channel_id': channel.epgChannelId,
        'sort_order': channel.sortOrder ?? 0,
      });
    }

    final nextIsFavorite = !channel.isFavorite;
    final nextFavoriteKeys = Set<String>.from(_favoriteSourceKeys);
    if (nextIsFavorite) {
      nextFavoriteKeys.add(key);
    } else {
      nextFavoriteKeys.remove(key);
    }
    _favoriteSourceKeys = nextFavoriteKeys;

    channels = sortChannels(
      channels.map(
        (c) => _favoriteSourceKeyForChannel(c) == key
            ? c.copyWith(isFavorite: nextIsFavorite)
            : c,
      ),
      channelSortOrder,
    );

    _globalChannels = sortChannels(
      _globalChannels.map(
        (c) => _favoriteSourceKeyForChannel(c) == key
            ? c.copyWith(isFavorite: nextIsFavorite)
            : c,
      ),
      channelSortOrder,
    );

    if (nowPlaying != null &&
        _favoriteSourceKeyForChannel(nowPlaying!) == key) {
      nowPlaying = nowPlaying!.copyWith(isFavorite: nextIsFavorite);
    }

    final updatedCache = <int, List<Channel>>{};
    for (final entry in _playlistChannelsCache.entries) {
      updatedCache[entry.key] = sortChannels(
        entry.value.map(
          (c) => _favoriteSourceKeyForChannel(c) == key
              ? c.copyWith(isFavorite: nextIsFavorite)
              : c,
        ),
        channelSortOrder,
      );
    }
    _playlistChannelsCache
      ..clear()
      ..addAll(updatedCache);

    if (nextIsFavorite) {
      if (!favoriteChannels.any(
        (c) => _favoriteSourceKeyForChannel(c) == key,
      )) {
        favoriteChannels = sortChannels([
          channel.copyWith(isFavorite: true),
          ...favoriteChannels,
        ], channelSortOrder);
      }
    } else {
      favoriteChannels = favoriteChannels
          .where((c) => _favoriteSourceKeyForChannel(c) != key)
          .toList();
    }

    notifyListeners();
  }

  Future<void> toggleFavoriteGroup(Group group) async {
    final groupName = group.name.trim();
    final normalizedGroupName = groupName.toLowerCase();
    final initialPlaylistId = group.playlistId > 0
        ? group.playlistId
        : selectedPlaylistId;
    if (initialPlaylistId == null || groupName.isEmpty) {
      return;
    }
    var playlistId = initialPlaylistId;

    final currentlyFavorite = isGroupFavorite(playlistId, groupName);
    final affectedPlaylistIds = <int>{playlistId};

    if (currentlyFavorite) {
      final candidatePlaylistIds = favoriteGroups
          .where((g) => g.name.trim().toLowerCase() == normalizedGroupName)
          .map((g) => g.playlistId)
          .toSet();
      if (candidatePlaylistIds.isEmpty) {
        candidatePlaylistIds.add(playlistId);
      }
      affectedPlaylistIds
        ..clear()
        ..addAll(candidatePlaylistIds);

      ApiException? lastError;
      var removedAny = false;
      for (final candidateId in candidatePlaylistIds) {
        try {
          await api.delete(_favoriteGroupDeletePath(candidateId, groupName));
          removedAny = true;
        } on ApiException catch (e) {
          lastError = e;
        }
      }

      if (!removedAny && lastError != null) {
        throw lastError;
      }
    } else {
      final candidatePlaylistIds = <int>{
        playlistId,
        ...?(selectedPlaylistId == null ? null : [selectedPlaylistId!]),
      };

      int? resolvedPlaylistId;
      try {
        resolvedPlaylistId = await resolveGroupPlaylistId(
          Group(
            name: groupName,
            playlistId: playlistId,
            channelCount: group.channelCount,
            isFavorite: group.isFavorite,
          ),
        );
      } catch (_) {
        // Keep existing candidates if resolution fails.
      }
      candidatePlaylistIds.addAll(
        resolvedPlaylistId == null ? const <int>[] : <int>[resolvedPlaylistId],
      );

      ApiException? lastError;
      var added = false;
      for (final candidateId in candidatePlaylistIds) {
        try {
          await api.post('/favorites/groups', {
            'playlist_id': candidateId,
            'group_name': groupName,
          });
          playlistId = candidateId;
          affectedPlaylistIds
            ..clear()
            ..add(candidateId);
          added = true;
          break;
        } on ApiException catch (e) {
          lastError = e;
        }
      }

      if (!added) {
        throw lastError ?? const ApiException('Could not add favorite group');
      }
    }

    final nextIsFavorite = !currentlyFavorite;

    groups = sortGroups(
      groups.map(
        (g) =>
            affectedPlaylistIds.contains(g.playlistId) &&
                g.name.trim().toLowerCase() == normalizedGroupName
            ? g.copyWith(isFavorite: nextIsFavorite)
            : g,
      ),
    );

    _globalGroups = sortGroups(
      _globalGroups.map(
        (g) =>
            affectedPlaylistIds.contains(g.playlistId) &&
                g.name.trim().toLowerCase() == normalizedGroupName
            ? g.copyWith(isFavorite: nextIsFavorite)
            : g,
      ),
    );

    if (nextIsFavorite) {
      if (!favoriteGroups.any(
        (g) =>
            g.playlistId == playlistId &&
            g.name.trim().toLowerCase() == normalizedGroupName,
      )) {
        favoriteGroups = sortGroups([
          Group(
            name: groupName,
            playlistId: playlistId,
            channelCount: group.channelCount,
            isFavorite: true,
          ),
          ...favoriteGroups,
        ]);
      }
    } else {
      favoriteGroups = sortGroups(
        favoriteGroups.where(
          (g) =>
              !(affectedPlaylistIds.contains(g.playlistId) &&
                  g.name.trim().toLowerCase() == normalizedGroupName),
        ),
      );
    }

    // Ensure frontend and backend stay in sync even if local flags were stale.
    await fetchFavoriteGroups();

    notifyListeners();
  }

  void toggleChannelSortOrder() {
    channelSortOrder = channelSortOrder == ChannelSortOrder.byName
        ? ChannelSortOrder.byIndex
        : ChannelSortOrder.byName;

    channels = sortChannels(channels, channelSortOrder);
    _globalChannels = sortChannels(_globalChannels, channelSortOrder);
    favoriteChannels = sortChannels(favoriteChannels, channelSortOrder);

    notifyListeners();
  }

  Future<void> fetchFavoriteChannels() async {
    loadingFavoriteChannels = true;
    notifyListeners();
    try {
      final fetched = (await api.get('/favorites/channels') as List<dynamic>)
          .map((e) => Channel.fromJson(e as Map<String, dynamic>))
          .toList();
      favoriteChannels = sortChannels(fetched, channelSortOrder);
      _favoriteSourceKeys = fetched
          .map((c) => _favoriteSourceKeyForChannel(c))
          .toSet();
      _reconcileFavoriteChannelFlags();
    } finally {
      loadingFavoriteChannels = false;
      notifyListeners();
    }
  }

  Future<void> fetchFavoriteGroups() async {
    loadingFavoriteGroups = true;
    notifyListeners();
    try {
      favoriteGroups = sortGroups(
        (await api.get('/favorites/groups') as List<dynamic>).map(
          (e) => Group.fromJson(e as Map<String, dynamic>),
        ),
      );
      _favoriteGroupsLoaded = true;
      _reconcileFavoriteFlags();
    } finally {
      loadingFavoriteGroups = false;
      notifyListeners();
    }
  }

  Future<int?> resolveGroupPlaylistId(Group group) async {
    if (playlists.isEmpty) {
      await fetchPlaylists();
    }

    final normalizedName = group.name.trim().toLowerCase();
    if (normalizedName.isEmpty) return null;

    Future<bool> playlistContainsGroup(int playlistId) async {
      try {
        final loadedChannels = await _getOrLoadPlaylistChannels(playlistId);
        return loadedChannels.any(
          (c) => c.groupName.trim().toLowerCase() == normalizedName,
        );
      } catch (_) {
        // Ignore per-playlist failures so one bad source cannot block favoriting.
        return false;
      }
    }

    if (group.playlistId > 0 &&
        playlists.any((p) => p.id == group.playlistId)) {
      if (await playlistContainsGroup(group.playlistId)) {
        return group.playlistId;
      }
    }

    for (final playlist in playlists) {
      if (group.playlistId == playlist.id) continue;
      if (await playlistContainsGroup(playlist.id)) {
        return playlist.id;
      }
    }

    return null;
  }

  Future<Group> normalizeFavoriteGroupPlaylist(Group group) async {
    final resolvedPlaylistId = await resolveGroupPlaylistId(group);
    if (resolvedPlaylistId == null) return group;
    if (resolvedPlaylistId == group.playlistId) return group;

    if (group.playlistId > 0) {
      try {
        await api.delete(
          _favoriteGroupDeletePath(group.playlistId, group.name),
        );
      } catch (_) {
        // Best effort cleanup for stale mapping.
      }
    }

    await api.post('/favorites/groups', {
      'playlist_id': resolvedPlaylistId,
      'group_name': group.name,
    });

    final updated = Group(
      name: group.name,
      playlistId: resolvedPlaylistId,
      channelCount: group.channelCount,
      isFavorite: true,
    );

    favoriteGroups = sortGroups(
      favoriteGroups.map(
        (g) => g.playlistId == group.playlistId && g.name == group.name
            ? updated
            : g,
      ),
    );
    notifyListeners();

    return updated;
  }

  void setSearchQuery(String query) {
    searchQuery = query;
    notifyListeners();
  }

  // --- Playlist CRUD ---

  Future<void> createM3uPlaylist({
    required String name,
    String? m3uUrl,
    String? m3uContent,
    String? epgUrl,
  }) async {
    final trimmedEpgUrl = epgUrl?.trim() ?? '';
    final body = <String, dynamic>{
      'name': name,
      'type': 'm3u',
      if (m3uUrl != null && m3uUrl.isNotEmpty) 'm3u_url': m3uUrl,
      if (m3uContent != null && m3uContent.isNotEmpty)
        'm3u_content': m3uContent,
      if (trimmedEpgUrl.isNotEmpty) 'epg_url': trimmedEpgUrl,
    };

    final result = await api.post('/playlists', body) as Map<String, dynamic>;

    final id = (result['id'] as num).toInt();
    _playlistChannelsCache.remove(id);
    await fetchPlaylists();
    await refreshPlaylist(id);
    await selectPlaylist(id);
  }

  Future<void> deletePlaylist(int id) async {
    await api.delete('/playlists/$id');
    if (selectedPlaylistId == id) {
      selectedPlaylistId = null;
      selectedGroup = null;
      channels = const [];
      groups = const [];
      nowPlaying = null;
      epgEntries = const [];
    }
    await fetchPlaylists();
    await fetchFavoriteChannels();
    await fetchFavoriteGroups();
    _globalGroups = const [];
    _globalChannels = const [];
  }

  Future<void> updatePlaylist({
    required int id,
    required String type,
    required String name,
    String? m3uUrl,
    String? m3uContent,
    String? xtreamServer,
    String? xtreamUsername,
    String? xtreamPassword,
    String? vuplusIp,
    String? vuplusPort,
    String? epgUrl,
  }) async {
    final body = <String, dynamic>{'name': name, 'type': type};
    if (epgUrl != null) {
      body['epg_url'] = epgUrl.trim();
    }

    if (type == 'm3u') {
      if (m3uUrl != null && m3uUrl.isNotEmpty) {
        body['m3u_url'] = m3uUrl;
      }
      if (m3uContent != null && m3uContent.isNotEmpty) {
        body['m3u_content'] = m3uContent;
      }
    } else if (type == 'xtream') {
      body['xtream_server'] = xtreamServer;
      body['xtream_username'] = xtreamUsername;
      if (xtreamPassword != null && xtreamPassword.isNotEmpty) {
        body['xtream_password'] = xtreamPassword;
      }
    } else if (type == 'vuplus') {
      body['vuplus_ip'] = vuplusIp;
      body['vuplus_port'] = vuplusPort;
    }

    await api.put('/playlists/$id', body);
    _playlistChannelsCache.remove(id);
    await fetchPlaylists();
    await selectPlaylist(id);
    _globalGroups = const [];
    _globalChannels = const [];
  }

  Future<void> createXtreamPlaylist({
    required String name,
    required String server,
    required String username,
    required String password,
    String? epgUrl,
  }) async {
    final trimmedEpgUrl = epgUrl?.trim() ?? '';
    final result =
        await api.post('/playlists', {
              'name': name,
              'type': 'xtream',
              'xtream_server': server,
              'xtream_username': username,
              'xtream_password': password,
              if (trimmedEpgUrl.isNotEmpty) 'epg_url': trimmedEpgUrl,
            })
            as Map<String, dynamic>;

    final id = (result['id'] as num).toInt();
    _playlistChannelsCache.remove(id);
    await fetchPlaylists();
    await refreshPlaylist(id);
    await selectPlaylist(id);
  }

  Future<void> createVuplusPlaylist({
    required String name,
    required String ip,
    required String port,
    String? epgUrl,
  }) async {
    final trimmedEpgUrl = epgUrl?.trim() ?? '';
    final result =
        await api.post('/playlists', {
              'name': name,
              'type': 'vuplus',
              'vuplus_ip': ip,
              'vuplus_port': port,
              if (trimmedEpgUrl.isNotEmpty) 'epg_url': trimmedEpgUrl,
            })
            as Map<String, dynamic>;

    final id = (result['id'] as num).toInt();
    _playlistChannelsCache.remove(id);
    await fetchPlaylists();
    await refreshPlaylist(id);
    await selectPlaylist(id);
  }
}
