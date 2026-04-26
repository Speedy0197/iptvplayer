import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/auth_store.dart';

class ChannelLogoAvatar extends StatelessWidget {
  final String logoUrl;
  final double radius;
  final double iconSize;

  const ChannelLogoAvatar({
    super.key,
    required this.logoUrl,
    this.radius = 20,
    this.iconSize = 20,
  });

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthStore>();
    final fallback = CircleAvatar(
      radius: radius,
      child: Icon(Icons.tv, size: iconSize),
    );

    final effectiveLogoUrl = _resolveEffectiveLogoUrl(
      rawLogoUrl: logoUrl,
      apiBaseUrl: auth.api.baseUrl,
      token: auth.token,
    );

    if (effectiveLogoUrl.isEmpty) {
      return fallback;
    }

    return ClipOval(
      child: SizedBox(
        width: radius * 2,
        height: radius * 2,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Image.network(
            effectiveLogoUrl,
            fit: BoxFit.contain,
            alignment: Alignment.center,
            errorBuilder: (context, error, stackTrace) {
              assert(() {
                debugPrint(
                  '[channel-logo] failed loading logo url=$effectiveLogoUrl (raw=$logoUrl) error=$error',
                );
                return true;
              }());
              return fallback;
            },
          ),
        ),
      ),
    );
  }

  static String _resolveEffectiveLogoUrl({
    required String rawLogoUrl,
    required String apiBaseUrl,
    required String? token,
  }) {
    final trimmed = rawLogoUrl.trim();
    if (trimmed.isEmpty) {
      return '';
    }

    final rawUri = Uri.tryParse(trimmed);
    if (rawUri == null || !rawUri.hasScheme) {
      return trimmed;
    }

    final needsProxy = _looksLikeVuplusOrPrivateSource(rawUri);
    if (!needsProxy) {
      return trimmed;
    }

    final baseUri = Uri.tryParse(apiBaseUrl);
    if (baseUri == null || !baseUri.hasScheme) {
      return trimmed;
    }

    final tokenValue = token?.trim() ?? '';
    if (tokenValue.isEmpty) {
      return trimmed;
    }

    final proxyUri = baseUri.replace(
      path: '${baseUri.path}/proxy',
      queryParameters: {'url': trimmed, 'token': tokenValue},
    );

    assert(() {
      debugPrint('[channel-logo] proxy logo raw=$trimmed proxied=$proxyUri');
      return true;
    }());

    return proxyUri.toString();
  }

  static bool _looksLikeVuplusOrPrivateSource(Uri uri) {
    if (uri.path.contains('/web/getpicon') || uri.path.contains('/picon/')) {
      return true;
    }

    final host = uri.host.trim().toLowerCase();
    if (host.isEmpty) {
      return false;
    }

    if (host == 'localhost' || host == '127.0.0.1') {
      return true;
    }

    if (host.startsWith('10.') || host.startsWith('192.168.')) {
      return true;
    }

    if (host.startsWith('172.')) {
      final parts = host.split('.');
      if (parts.length >= 2) {
        final second = int.tryParse(parts[1]);
        if (second != null && second >= 16 && second <= 31) {
          return true;
        }
      }
    }

    return false;
  }
}
