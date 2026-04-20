bool _jsonBool(dynamic value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final v = value.trim().toLowerCase();
    return v == '1' || v == 'true' || v == 'yes';
  }
  return false;
}

class AuthResponse {
  final String token;
  final int userId;
  final String username;

  const AuthResponse({
    required this.token,
    required this.userId,
    required this.username,
  });

  factory AuthResponse.fromJson(Map<String, dynamic> json) {
    return AuthResponse(
      token: json['token'] as String,
      userId: (json['user_id'] as num).toInt(),
      username: json['username'] as String,
    );
  }
}

class Playlist {
  final int id;
  final String name;
  final String type;
  final String? m3uUrl;
  final String? xtreamServer;
  final String? xtreamUsername;
  final String? xtreamPassword;
  final String? vuplusIp;
  final String? vuplusPort;
  final String? lastRefreshed;

  const Playlist({
    required this.id,
    required this.name,
    required this.type,
    this.m3uUrl,
    this.xtreamServer,
    this.xtreamUsername,
    this.xtreamPassword,
    this.vuplusIp,
    this.vuplusPort,
    this.lastRefreshed,
  });

  factory Playlist.fromJson(Map<String, dynamic> json) {
    return Playlist(
      id: (json['id'] as num).toInt(),
      name: (json['name'] as String?) ?? 'Untitled',
      type: (json['type'] as String?) ?? 'm3u',
      m3uUrl: json['m3u_url'] as String?,
      xtreamServer: json['xtream_server'] as String?,
      xtreamUsername: json['xtream_username'] as String?,
      xtreamPassword: json['xtream_password'] as String?,
      vuplusIp: json['vuplus_ip'] as String?,
      vuplusPort: json['vuplus_port'] as String?,
      lastRefreshed: json['last_refreshed'] as String?,
    );
  }
}

class Group {
  final String name;
  final int playlistId;
  final int channelCount;
  final bool isFavorite;

  const Group({
    required this.name,
    required this.playlistId,
    required this.channelCount,
    required this.isFavorite,
  });

  factory Group.fromJson(Map<String, dynamic> json) {
    return Group(
      name: (json['name'] as String?) ?? 'Uncategorized',
      playlistId: (json['playlist_id'] as num?)?.toInt() ?? 0,
      channelCount: (json['channel_count'] as num?)?.toInt() ?? 0,
      isFavorite: _jsonBool(json['is_favorite']),
    );
  }

  Group copyWith({bool? isFavorite}) {
    return Group(
      name: name,
      playlistId: playlistId,
      channelCount: channelCount,
      isFavorite: isFavorite ?? this.isFavorite,
    );
  }
}

class Channel {
  final int id;
  final int playlistId;
  final String streamId;
  final String name;
  final String groupName;
  final String streamUrl;
  final String logoUrl;
  final String epgChannelId;
  final int? sortOrder;
  final bool isFavorite;

  const Channel({
    required this.id,
    required this.playlistId,
    required this.streamId,
    required this.name,
    required this.groupName,
    required this.streamUrl,
    required this.logoUrl,
    required this.epgChannelId,
    this.sortOrder,
    required this.isFavorite,
  });

  factory Channel.fromJson(Map<String, dynamic> json) {
    return Channel(
      id: (json['id'] as num).toInt(),
      playlistId: (json['playlist_id'] as num).toInt(),
      streamId: (json['stream_id'] as String?) ?? '',
      name: (json['name'] as String?) ?? 'Unknown channel',
      groupName: (json['group_name'] as String?) ?? 'Uncategorized',
      streamUrl: (json['stream_url'] as String?) ?? '',
      logoUrl: (json['logo_url'] as String?) ?? '',
      epgChannelId: (json['epg_channel_id'] as String?) ?? '',
      sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      isFavorite: _jsonBool(json['is_favorite']),
    );
  }

  Channel copyWith({bool? isFavorite}) {
    return Channel(
      id: id,
      playlistId: playlistId,
      streamId: streamId,
      name: name,
      groupName: groupName,
      streamUrl: streamUrl,
      logoUrl: logoUrl,
      epgChannelId: epgChannelId,
      sortOrder: sortOrder,
      isFavorite: isFavorite ?? this.isFavorite,
    );
  }
}

class EpgEntry {
  final String channelEpgId;
  final DateTime startTime;
  final DateTime endTime;
  final String title;
  final String description;

  const EpgEntry({
    required this.channelEpgId,
    required this.startTime,
    required this.endTime,
    required this.title,
    required this.description,
  });

  factory EpgEntry.fromJson(Map<String, dynamic> json) {
    return EpgEntry(
      channelEpgId: (json['channel_epg_id'] as String?) ?? '',
      startTime: DateTime.parse(json['start_time'] as String).toLocal(),
      endTime: DateTime.parse(json['end_time'] as String).toLocal(),
      title: (json['title'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
    );
  }
}
