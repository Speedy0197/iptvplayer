import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';

typedef ProgressCallback = void Function(double progress);
typedef StatusCallback = void Function(String status);

class UpdateService {
  static const Duration _downloadChunkTimeout = Duration(seconds: 30);
  static const Duration _downloadOverallTimeout = Duration(minutes: 10);

  /// The platform-appropriate action when tapping "Update Now".
  /// iOS opens TestFlight; others download + install the binary.
  static bool get isDirectInstall =>
      Platform.isAndroid || Platform.isWindows || Platform.isMacOS;

  static String get platformDownloadUrl {
    if (Platform.isAndroid) return AppConfig.androidDownloadUrl;
    if (Platform.isWindows) return AppConfig.windowsDownloadUrl;
    if (Platform.isMacOS) return AppConfig.macosDownloadUrl;
    return AppConfig.iosTestFlightSchemeUrl; // iOS
  }

  /// Downloads the binary and reports progress (0.0–1.0) via [onProgress].
  /// Returns the local file path on success, null on failure.
  static Future<String?> download(
    String url, {
    required ProgressCallback onProgress,
    StatusCallback? onStatus,
  }) async {
    return _downloadInternal(
      url,
      onProgress: onProgress,
      onStatus: onStatus,
    ).timeout(
      _downloadOverallTimeout,
      onTimeout: () {
        onStatus?.call('Download timed out after ${_downloadOverallTimeout.inMinutes} minutes');
        return null;
      },
    );
  }

  static Future<String?> _downloadInternal(
    String url, {
    required ProgressCallback onProgress,
    StatusCallback? onStatus,
  }) async {
    final client = http.Client();
    try {
      onStatus?.call('Requesting update package');
      final response =
          await client.send(http.Request('GET', Uri.parse(url)));
      if (response.statusCode != 200) {
        onStatus?.call('Download failed: HTTP ${response.statusCode}');
        return null;
      }

      final total = response.contentLength ?? 0;
      var received = 0;
      onStatus?.call(
        total > 0 ? 'Downloading package (${_formatBytes(total)})' : 'Downloading package',
      );

      final dir = await getTemporaryDirectory();
      final fileName = url.split('/').last;
      final file = File('${dir.path}/$fileName');
      await file.parent.create(recursive: true);
      if (await file.exists()) {
        await file.delete();
      }
      final output = await file.open(mode: FileMode.writeOnly);

      try {
        await for (final chunk in response.stream.timeout(_downloadChunkTimeout)) {
          await output.writeFrom(chunk);
          received += chunk.length;
          if (total > 0) {
            final progress = (received / total).clamp(0.0, 1.0).toDouble();
            onProgress(progress);
            onStatus?.call(
              'Received ${_formatBytes(received)} of ${_formatBytes(total)}',
            );
            if (received >= total) {
              break;
            }
          } else {
            onStatus?.call('Received ${_formatBytes(received)}');
          }
        }

        onStatus?.call('Flushing downloaded file');
        await output.flush();
      } finally {
        onStatus?.call('Closing downloaded file');
        await output.close();
      }

      onProgress(1.0);
      onStatus?.call('Download complete: ${file.path}');
      return file.path;
    } on TimeoutException {
      onStatus?.call('Download stalled waiting for the next chunk');
      return null;
    } catch (error) {
      onStatus?.call('Download failed: $error');
      return null;
    } finally {
      client.close();
    }
  }

  /// Triggers the platform-native install flow for a downloaded file.
  static Future<void> install(String filePath, {StatusCallback? onStatus}) async {
    if (Platform.isAndroid) {
      onStatus?.call('Opening Android installer');
      await OpenFilex.open(filePath);
    } else if (Platform.isMacOS) {
      // Mount the DMG and close the app so the user can replace it cleanly.
      onStatus?.call('Opening downloaded DMG');
      final result = await Process.run('open', [filePath]);
      if (result.exitCode != 0) {
        onStatus?.call('Failed to open DMG: ${(result.stderr ?? result.stdout).toString()}');
        throw ProcessException(
          'open',
          [filePath],
          (result.stderr ?? result.stdout).toString(),
          result.exitCode,
        );
      }
      onStatus?.call('DMG opened successfully, closing app');
      exit(0);
    } else if (Platform.isWindows) {
      // Launch the installer visibly so users can confirm/update via the wizard.
      onStatus?.call('Opening Windows installer');
      await OpenFilex.open(filePath);
      exit(0);
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Opens the TestFlight app directly (iOS), falling back to Safari if not installed.
  static Future<void> openDownloadPage() async {
    if (Platform.isIOS) {
      final scheme = Uri.parse(AppConfig.iosTestFlightSchemeUrl);
      if (await canLaunchUrl(scheme)) {
        await launchUrl(scheme);
        return;
      }
      await launchUrl(
        Uri.parse(AppConfig.iosTestFlightFallbackUrl),
        mode: LaunchMode.externalApplication,
      );
      return;
    }
    await launchUrl(
      Uri.parse(platformDownloadUrl),
      mode: LaunchMode.externalApplication,
    );
  }
}
