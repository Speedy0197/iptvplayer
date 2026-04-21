import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

import 'config/app_config.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/api_client.dart';
import 'services/auth_store.dart';
import 'services/playlist_store.dart';
import 'services/version_service.dart';

void main() {
  WidgetsBinding widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);
  
  MediaKit.ensureInitialized();
  final api = ApiClient(baseUrl: AppConfig.apiBase);
  
  FlutterNativeSplash.remove();
  runApp(IptvFlutterApp(api: api));
}

class IptvFlutterApp extends StatelessWidget {
  final ApiClient api;

  const IptvFlutterApp({super.key, required this.api});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthStore>(
          create: (_) => AuthStore(api: api)..init(),
        ),
        ChangeNotifierProvider<PlaylistStore>(
          create: (_) => PlaylistStore(api: api),
        ),
      ],
      child: MaterialApp(
        title: 'StreamPilot',
        theme: ThemeData(
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1E88E5),
            brightness: Brightness.dark,
          ),
          scaffoldBackgroundColor: const Color(0xFF0D1117),
          cardTheme: CardThemeData(
            color: const Color(0xFF111826),
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: Color(0xFF22304A), width: 1),
            ),
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF0B1220),
            foregroundColor: Colors.white,
            elevation: 0,
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFF0E1726),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF273857)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF273857)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(
                color: Color(0xFF3EA6FF),
                width: 1.2,
              ),
            ),
          ),
          dividerColor: const Color(0xFF243147),
          useMaterial3: true,
        ),
        home: const _AuthGate(),
      ),
    );
  }
}

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
      final result =
          await VersionService(
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
