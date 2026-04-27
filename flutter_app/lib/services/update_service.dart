import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';

typedef ProgressCallback = void Function(double progress);

class UpdateService {
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
  }) async {
    final client = http.Client();
    try {
      final response =
          await client.send(http.Request('GET', Uri.parse(url)));
      if (response.statusCode != 200) return null;

      final total = response.contentLength ?? 0;
      var received = 0;

      final dir = await getTemporaryDirectory();
      final fileName = url.split('/').last;
      final file = File('${dir.path}/$fileName');
      final sink = file.openWrite();

      await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          // Avoid showing 100% before the stream is fully written and closed.
          final progress = (received / total).clamp(0.0, 0.99).toDouble();
          onProgress(progress);
        }
      }

      await sink.flush();
      await sink.close();
      onProgress(1.0);
      return file.path;
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Triggers the platform-native install flow for a downloaded file.
  static Future<void> install(String filePath) async {
    if (Platform.isAndroid) {
      await OpenFilex.open(filePath);
    } else if (Platform.isMacOS) {
      // Mount the DMG; user drags to Applications.
      await Process.run('open', [filePath]);
    } else if (Platform.isWindows) {
      // Launch the installer visibly so users can confirm/update via the wizard.
      await OpenFilex.open(filePath);
      exit(0);
    }
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
