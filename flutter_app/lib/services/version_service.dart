import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class VersionCheckResult {
  final bool updateRequired;
  final String latestVersion;

  const VersionCheckResult({
    required this.updateRequired,
    required this.latestVersion,
  });
}

class VersionService {
  final String latestVersionUrl;

  const VersionService({required this.latestVersionUrl});

  Future<VersionCheckResult?> check() async {
    try {
      final uri = Uri.parse(latestVersionUrl);
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final rawLatestVersion = data['latest_version'] as String?;
      if (rawLatestVersion == null || rawLatestVersion.isEmpty) return null;
      final latestVersion = _normalizeVersion(rawLatestVersion);
      if (latestVersion.isEmpty) return null;

      final info = await PackageInfo.fromPlatform();
      final current = info.version;

      return VersionCheckResult(
        updateRequired: _compareVersions(current, latestVersion) < 0,
        latestVersion: latestVersion,
      );
    } catch (_) {
      return null;
    }
  }

  String _normalizeVersion(String input) {
    return input.trim().replaceFirst(RegExp(r'^[vV]'), '');
  }

  /// Returns negative if a < b, 0 if equal, positive if a > b.
  int _compareVersions(String a, String b) {
    final aParts = a.split('.').map(int.tryParse).toList();
    final bParts = b.split('.').map(int.tryParse).toList();
    for (var i = 0; i < 3; i++) {
      final av = (i < aParts.length ? aParts[i] : null) ?? 0;
      final bv = (i < bParts.length ? bParts[i] : null) ?? 0;
      if (av != bv) return av - bv;
    }
    return 0;
  }
}

/// Shows a non-dismissable dialog that blocks the UI when a forced update is required.
Future<void> showForceUpdateDialog(
  BuildContext context,
  String latestVersion,
  String downloadUrl,
) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Update Required'),
        content: Text(
          'Version $latestVersion is required to continue using StreamPilot. '
          'Please update your app to the latest version.',
        ),
        actions: [
          FilledButton(
            onPressed: () => launchUrl(
              Uri.parse(downloadUrl),
              mode: LaunchMode.externalApplication,
            ),
            child: const Text('Download Update'),
          ),
        ],
      ),
    ),
  );
}
