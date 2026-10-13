import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:window_manager/window_manager.dart';

import 'config/app_config.dart';
import 'config/app_theme.dart';
import 'services/tv_pairing.dart';
import 'screens/tv_pairing_screen.dart';
import 'config/device_utils.dart';
import 'config/ui_constants.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/api_client.dart';
import 'services/auth_store.dart';
import 'services/playlist_store.dart';
import 'services/version_service.dart';

Future<void> main() async {
  WidgetsBinding widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  try {
    await initializeDeviceType();
    if (Platform.isMacOS || Platform.isWindows) {
      const minimumWindowSize = Size(kCompactBreakpoint + 1, 640);
      await windowManager.ensureInitialized();
      await windowManager.waitUntilReadyToShow(
        const WindowOptions(minimumSize: minimumWindowSize),
        () async {
          await windowManager.setMinimumSize(minimumWindowSize);
          if (Platform.isMacOS) {
            await windowManager.maximize();
          } else if (Platform.isWindows) {
            await windowManager.maximize();
          }
          // show()/focus() are deferred to a post-frame callback below so
          // the window only becomes visible after Flutter completes its first
          // layout pass — calling show() here lets mouse events arrive before
          // any RenderBox has been laid out, triggering hit-test assertions.
        },
      );
    }

    // Configure audio session in background — errors must not block startup.
    if (Platform.isIOS) {
      AudioSession.instance
          .then(
            (session) => session
                .configure(
                  AudioSessionConfiguration(
                    avAudioSessionCategory: AVAudioSessionCategory.playback,
                    avAudioSessionCategoryOptions:
                        AVAudioSessionCategoryOptions.allowBluetooth |
                        AVAudioSessionCategoryOptions.allowBluetoothA2dp,
                    avAudioSessionMode: AVAudioSessionMode.moviePlayback,
                  ),
                )
                .then((_) => session.setActive(true)),
          )
          .ignore();
    }

    MediaKit.ensureInitialized();
  } catch (e, st) {
    debugPrint('StreamPilot startup error: $e\n$st');
  } finally {
    FlutterNativeSplash.remove();
  }

  runApp(IptvFlutterApp(api: ApiClient(baseUrl: AppConfig.apiBase)));

  if (Platform.isMacOS || Platform.isWindows) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await windowManager.show();
        await windowManager.focus();
      } catch (e) {
        debugPrint('Failed to show/focus window: $e');
      }
    });
  }
}

class IptvFlutterApp extends StatefulWidget {
  final ApiClient api;

  const IptvFlutterApp({super.key, required this.api});

  @override
  State<IptvFlutterApp> createState() => _IptvFlutterAppState();
}

class _IptvFlutterAppState extends State<IptvFlutterApp>
    with WidgetsBindingObserver {
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // Register before WidgetsApp: it normalizes URLs and discards authority.
    // Validate the original native URL before that loses host information.
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Future<bool> didPushRouteInformation(RouteInformation information) async {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return false;
    final uri = information.uri;
    final pairing = TvPairingLink.tryParse(uri.toString());
    if (pairing != null) {
      navigator.push(_pairingRoute(pairing.token));
      return true;
    }
    if (uri.hasScheme || uri.hasAuthority) {
      navigator.push(_unsupportedRoute());
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthStore>(
          create: (_) => AuthStore(api: widget.api)..init(),
        ),
        ChangeNotifierProvider<PlaylistStore>(
          create: (_) => PlaylistStore(api: widget.api),
        ),
      ],
      child: MaterialApp(
        navigatorKey: _navigatorKey,
        title: 'StreamPilot',
        theme: createStreamPilotTheme(),
        onGenerateInitialRoutes: (initialRoute) {
          final pairing = TvPairingLink.tryParse(initialRoute);
          return [
            MaterialPageRoute<void>(
              settings: const RouteSettings(name: '/'),
              builder: (_) => const _AuthGate(),
            ),
            if (pairing != null) _pairingRoute(pairing.token),
          ];
        },
        onGenerateRoute: (settings) {
          if (settings.name == '/') {
            return MaterialPageRoute<void>(
              settings: const RouteSettings(name: '/'),
              builder: (_) => const _AuthGate(),
            );
          }
          final pairing = TvPairingLink.tryParse(settings.name);
          if (pairing != null) return _pairingRoute(pairing.token);
          return _unsupportedRoute();
        },
      ),
    );
  }
}

Route<void> _unsupportedRoute() => MaterialPageRoute<void>(
  settings: const RouteSettings(name: '/unsupported-link'),
  builder: (_) => Scaffold(
    appBar: AppBar(title: const Text('StreamPilot')),
    body: const Center(child: Text('This link is not supported.')),
  ),
);

Route<void> _pairingRoute(String? token) => MaterialPageRoute<void>(
  // Route names are visible to observers; keep opaque pairing values out.
  settings: const RouteSettings(name: '/tv/activate'),
  builder: (_) => TvPairingScreen(pairingToken: token),
);

class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> with WidgetsBindingObserver {
  bool _versionChecked = false;
  bool _checkingVersion = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkVersion();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkVersion();
    }
  }

  Future<void> _checkVersion() async {
    if (_checkingVersion) return;
    _checkingVersion = true;
    try {
      final result = await VersionService(
        latestVersionUrl: AppConfig.latestVersionUrl,
      ).check();
      if (!mounted) return;
      if (result != null && result.updateRequired) {
        await showForceUpdateDialog(context, result.latestVersion);
      }
      if (!_versionChecked) setState(() => _versionChecked = true);
    } finally {
      _checkingVersion = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthStore>();

    if (!_versionChecked || auth.initializing) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (auth.isLoggedIn) {
      return const HomeScreen();
    }

    return const LoginScreen();
  }
}
