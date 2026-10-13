import 'api_client.dart';

/// Identifies an approval request, never a TV polling or account credential.
class TvPairingLink {
  const TvPairingLink._(this.token);

  final String? token;
  static const host = 'iptv.florian-zug.de';
  static const path = '/tv/activate';
  static final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{32,128}$');

  static bool isValidToken(String value) => _tokenPattern.hasMatch(value);

  static String qrUrl(String token) {
    if (!isValidToken(token)) {
      throw const FormatException('Invalid pairing request');
    }
    return Uri(
      scheme: 'https',
      host: host,
      path: path,
      fragment: Uri(queryParameters: {'pairing_token': token}).query,
    ).toString();
  }

  static TvPairingLink? tryParse(String? location) {
    if (location == null) return null;
    try {
      final uri = Uri.parse(location);
      final canonical =
          uri.scheme == 'https' &&
          uri.host == host &&
          (!uri.hasPort || uri.port == 443) &&
          uri.userInfo.isEmpty &&
          uri.path == path;
      final custom =
          uri.scheme == 'streampilot' &&
          uri.host == 'tv' &&
          uri.path == '/activate' &&
          uri.userInfo.isEmpty &&
          !uri.hasPort;
      final normalized =
          !uri.hasScheme && !uri.hasAuthority && uri.path == path;
      if (!canonical && !custom && !normalized) return null;
      final query = uri.queryParametersAll;
      final fragment = Uri(query: uri.fragment).queryParametersAll;
      if (query.containsKey('api_base') || fragment.containsKey('api_base')) {
        return null;
      }
      final tokens = [
        ...?query['pairing_token'],
        ...?fragment['pairing_token'],
      ];
      if (tokens.isEmpty) return const TvPairingLink._(null);
      if (tokens.length != 1 || !isValidToken(tokens.single)) return null;
      return TvPairingLink._(tokens.single);
    } on FormatException {
      return null;
    }
  }
}

class TvPairingSession {
  const TvPairingSession({
    required this.userCode,
    required this.expiresAt,
    required this.status,
    required this.deviceName,
  });

  final String userCode;
  final DateTime expiresAt;
  final String status;
  final String deviceName;

  factory TvPairingSession.fromJson(Map<String, dynamic> json) {
    final code = json['user_code'];
    final expiry = json['expires_at'];
    final status = json['status'];
    final expiresAt = expiry is String ? DateTime.tryParse(expiry) : null;
    if (code is! String ||
        !RegExp(r'^\d{6}$').hasMatch(code) ||
        expiresAt == null ||
        !const ['pending', 'approved', 'declined'].contains(status)) {
      throw const ApiException(
        'This pairing request could not be read. Scan the TV again.',
      );
    }
    final name = json['device_name'];
    return TvPairingSession(
      userCode: code,
      expiresAt: expiresAt,
      status: status as String,
      deviceName: name is String && name.trim().isNotEmpty
          ? name
          : 'StreamPilot TV',
    );
  }
}

class TvPairingService {
  const TvPairingService(this.api);
  final ApiClient api;

  Future<TvPairingSession> load(String token) async {
    if (!TvPairingLink.isValidToken(token)) {
      throw const ApiException('Invalid pairing request');
    }
    final json = await api.get(
      '/auth/tv/session?pairing_token=${Uri.encodeQueryComponent(token)}',
    );
    if (json is! Map<String, dynamic>) {
      throw const ApiException('Unable to read this pairing request');
    }
    return TvPairingSession.fromJson(json);
  }

  Future<String> lookup(String code) async {
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      throw const ApiException('Enter the 6-digit TV code');
    }
    final json = await api.post('/auth/tv/lookup', {'user_code': code});
    final token = json is Map<String, dynamic> ? json['pairing_token'] : null;
    if (token is! String || !TvPairingLink.isValidToken(token)) {
      throw const ApiException(
        'This TV code is unavailable. Generate a new QR code on the TV.',
      );
    }
    return token;
  }

  Future<void> approve(String token) => _act('/auth/tv/approve-session', token);
  Future<void> decline(String token) => _act('/auth/tv/decline-session', token);
  Future<void> _act(String path, String token) async {
    if (!TvPairingLink.isValidToken(token)) {
      throw const ApiException('Invalid pairing request');
    }
    await api.post(path, {'pairing_token': token});
  }
}
