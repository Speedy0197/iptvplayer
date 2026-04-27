import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'api_client.dart';
import 'channel_sort.dart';
import 'playlist_search.dart';

export 'channel_sort.dart' show ChannelSortOrder;
export 'playlist_search.dart' show SearchResultItem, SearchResultType;

class PlaylistStore extends ChangeNotifier {
  final ApiClient api;

  PlaylistStore({required this.api});

  List<Playlist> playlists = const [];
  List<Group> groups = const [];
  List<Channel> channels = const [];
  List<Group> _globalGroups = const [];
  List<Channel> _globalChannels = const [];
  List<Channel> favoriteChannels = const [];
  List<Group> favoriteGroups = const [];
  List<EpgEntry> epgEntries = const [];

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
        final rawGroups =
            await api.get('/playlists/${p.id}/groups') as List<dynamic>;
        allGroups.addAll(
          rawGroups.map((e) => Group.fromJson(e as Map<String, dynamic>)),
        );

        final rawChannels =
            await api.get('/playlists/${p.id}/channels') as List<dynamic>;
        allChannels.addAll(
          rawChannels.map((e) => Channel.fromJson(e as Map<String, dynamic>)),
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
      groups = sortGroups(
        _mergeFavoriteFlagsIntoGroups(
          (await api.get('/playlists/$playlistId/groups') as List<dynamic>).map(
            (e) => Group.fromJson(e as Map<String, dynamic>),
          ),
        ),
      );
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
      final params = <String, String>{};
      if (group != null && group.isNotEmpty) {
        params['group'] = group;
      }
      final query = params.isEmpty
          ? ''
          : '?${Uri(queryParameters: params).query}';
      channels = sortChannels(
        (await api.get('/playlists/$playlistId/channels$query')
                as List<dynamic>)
            .map((e) => Channel.fromJson(e as Map<String, dynamic>)),
        channelSortOrder,
      );
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

    final epgPlaylistId = channel.playlistId;

    loadingEpg = true;
    notifyListeners();
    try {
      epgEntries =
          (await api.get(
                    '/playlists/$epgPlaylistId/epg/${Uri.encodeComponent(effectiveEpgChannelId)}',
                  )
                  as List<dynamic>)
              .map((e) => EpgEntry.fromJson(e as Map<String, dynamic>))
              .toList();
    } finally {
      loadingEpg = false;
      notifyListeners();
    }
  }

  Future<void> recordEpgEntry(EpgEntry entry) async {
    final playlist = selectedPlaylist;
    if (playlist == null) {
      throw const ApiException('No selected playlist');
    }
    if (playlist.type != 'vuplus') {
      throw const ApiException('Recording is only supported for VU+ playlists');
    }

    await api.post('/playlists/${playlist.id}/epg/record', {
      'channel_epg_id': entry.channelEpgId,
      'start_time': entry.startTime.toUtc().toIso8601String(),
      'end_time': entry.endTime.toUtc().toIso8601String(),
      'title': entry.title,
      'description': entry.description,
    });
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
      final response = await api.post('/playlists/$id/refresh');
      int? refreshedCount;
      if (response is Map<String, dynamic>) {
        final count = response['count'];
        if (count is int) {
          refreshedCount = count;
        } else if (count is num) {
          refreshedCount = count.toInt();
        }
      }

      await selectPlaylist(id);
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
    if (channel.isFavorite) {
      await api.delete('/favorites/channels/${channel.id}');
    } else {
      await api.post('/favorites/channels', {'channel_id': channel.id});
    }

    final nextIsFavorite = !channel.isFavorite;

    channels = sortChannels(
      channels.map(
        (c) => c.id == channel.id ? c.copyWith(isFavorite: nextIsFavorite) : c,
      ),
      channelSortOrder,
    );

    _globalChannels = sortChannels(
      _globalChannels.map(
        (c) => c.id == channel.id ? c.copyWith(isFavorite: nextIsFavorite) : c,
      ),
      channelSortOrder,
    );

    if (nowPlaying?.id == channel.id) {
      nowPlaying = nowPlaying!.copyWith(isFavorite: nextIsFavorite);
    }

    if (nextIsFavorite) {
      if (!favoriteChannels.any((c) => c.id == channel.id)) {
        favoriteChannels = sortChannels([
          channel.copyWith(isFavorite: true),
          ...favoriteChannels,
        ], channelSortOrder);
      }
    } else {
      favoriteChannels = favoriteChannels
          .where((c) => c.id != channel.id)
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
      favoriteChannels = sortChannels(
        (await api.get('/favorites/channels') as List<dynamic>).map(
          (e) => Channel.fromJson(e as Map<String, dynamic>),
        ),
        channelSortOrder,
      );
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
        final rawGroups =
            await api.get('/playlists/$playlistId/groups') as List<dynamic>;
        return rawGroups
            .map((e) => Group.fromJson(e as Map<String, dynamic>))
            .any((g) => g.name.trim().toLowerCase() == normalizedName);
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
    await api.post('/playlists/$id/refresh');
    await fetchPlaylists();
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
    await api.post('/playlists/$id/refresh');
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
    await api.post('/playlists/$id/refresh');
    await fetchPlaylists();
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
    await api.post('/playlists/$id/refresh');
    await fetchPlaylists();
    await selectPlaylist(id);
  }
}
