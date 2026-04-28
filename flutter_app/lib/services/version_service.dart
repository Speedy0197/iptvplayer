import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import 'update_service.dart';

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
      // iOS has a separate field so the force-update only triggers once
      // TestFlight has approved the build, not immediately on release.
      final versionKey = Platform.isIOS ? 'ios_available_version' : 'latest_version';
      final rawLatestVersion =
          (data[versionKey] as String?) ?? (data['latest_version'] as String?);
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
Future<void> showForceUpdateDialog(BuildContext context, String latestVersion) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ForceUpdateDialog(latestVersion: latestVersion),
  );
}

enum _UpdateState { idle, downloading, installing, error }

class _ForceUpdateDialog extends StatefulWidget {
  final String latestVersion;
  const _ForceUpdateDialog({required this.latestVersion});

  @override
  State<_ForceUpdateDialog> createState() => _ForceUpdateDialogState();
}

class _ForceUpdateDialogState extends State<_ForceUpdateDialog> {
  _UpdateState _state = _UpdateState.idle;
  double _progress = 0;
  String _statusText = 'Waiting to start update';
  String? _errorText;

  Future<void> _startUpdate() async {
    // iOS: just open TestFlight — no download needed.
    if (Platform.isIOS) {
      await UpdateService.openDownloadPage();
      return;
    }

    setState(() {
      _state = _UpdateState.downloading;
      _progress = 0;
      _errorText = null;
      _statusText = 'Starting update';
    });

    final path = await UpdateService.download(
      UpdateService.platformDownloadUrl,
      onProgress: (p) => setState(() => _progress = p),
      onStatus: (status) {
        if (!mounted) return;
        setState(() => _statusText = status);
      },
    );

    if (path == null) {
      setState(() {
        _state = _UpdateState.error;
        _errorText ??= _statusText;
      });
      return;
    }

    setState(() {
      _state = _UpdateState.installing;
      _statusText = 'Starting installer';
    });

    try {
      await UpdateService.install(
        path,
        onStatus: (status) {
          if (!mounted) return;
          setState(() => _statusText = status);
        },
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _state = _UpdateState.error;
        _errorText = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isIOS = Platform.isIOS;
    final isMacOS = Platform.isMacOS;

    String buttonLabel;
    if (isIOS) {
      buttonLabel = 'Open TestFlight';
    } else if (isMacOS) {
      buttonLabel = 'Download Update';
    } else {
      buttonLabel = 'Update Now';
    }

    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Update Required'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Version ${widget.latestVersion} is required to continue '
              'using StreamPilot. Please update your app.',
            ),
            if (_state == _UpdateState.downloading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress > 0 ? _progress : null),
              const SizedBox(height: 8),
              Text(
                _progress > 0
                    ? 'Downloading… ${(_progress * 100).toStringAsFixed(0)}%'
                    : 'Connecting…',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            Text(
              _statusText,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_state == _UpdateState.installing) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(
                isMacOS ? 'Opening DMG…' : 'Installing…',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (_state == _UpdateState.error) ...[
              const SizedBox(height: 12),
              Text(
                _errorText ?? 'Update failed. Please try again.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 13,
                ),
              ),
            ],
          ],
        ),
        actions: [
          if (_state == _UpdateState.idle || _state == _UpdateState.error)
            FilledButton(
              onPressed: _startUpdate,
              child: Text(
                _state == _UpdateState.error ? 'Retry' : buttonLabel,
              ),
            ),
          if (_state == _UpdateState.downloading ||
              _state == _UpdateState.installing)
            FilledButton(
              onPressed: null,
              child: Text(
                _state == _UpdateState.downloading
                    ? 'Downloading…'
                    : 'Installing…',
              ),
            ),
        ],
      ),
    );
  }
}
