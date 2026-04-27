import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../config/app_config.dart';
import '../services/api_client.dart';
import '../services/auth_store.dart';
import 'forgot_password_screen.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  String? _error;
  bool _showVerifyAction = false;
  bool _startingTvLogin = false;
  bool _pollingTvLogin = false;
  String? _tvLoginError;
  String? _tvDeviceCode;
  String? _tvUserCode;
  String? _tvLoginUrl;
  DateTime? _tvExpiresAt;
  Timer? _tvPollTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_startTvLogin());
  }

  @override
  void dispose() {
    _tvPollTimer?.cancel();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final auth = context.read<AuthStore>();
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _error = null;
      _showVerifyAction = false;
    });
    try {
      await auth.login(_emailCtrl.text.trim(), _passwordCtrl.text);
    } on ApiException catch (e) {
      final msg = e.message;
      setState(() {
        _error = msg;
        _showVerifyAction = msg.toLowerCase().contains('email not verified');
      });
    } catch (_) {
      setState(() {
        _error = 'Login failed';
        _showVerifyAction = false;
      });
    }
  }

  Future<void> _startTvLogin() async {
    if (_startingTvLogin) return;
    final auth = context.read<AuthStore>();

    setState(() {
      _startingTvLogin = true;
      _tvLoginError = null;
      _tvDeviceCode = null;
      _tvUserCode = null;
      _tvLoginUrl = null;
      _tvExpiresAt = null;
    });

    try {
      final data =
          await auth.api.post('/auth/tv/start') as Map<String, dynamic>;
      final deviceCode = (data['device_code'] as String?)?.trim();
      final userCode = (data['user_code'] as String?)?.trim();
      final expiresRaw = (data['expires_at'] as String?)?.trim();
      final expiresAt = expiresRaw != null && expiresRaw.isNotEmpty
          ? DateTime.tryParse(expiresRaw)?.toLocal()
          : null;
      if (deviceCode == null ||
          deviceCode.isEmpty ||
          userCode == null ||
          userCode.isEmpty) {
        throw const ApiException('Invalid TV login response');
      }

      final pageBase = AppConfig.downloadPageUrl.endsWith('/')
          ? AppConfig.downloadPageUrl
          : '${AppConfig.downloadPageUrl}/';
      final loginUrl =
          '${pageBase}tv-login.html?device_code=${Uri.encodeQueryComponent(deviceCode)}&api_base=${Uri.encodeQueryComponent(auth.api.baseUrl)}';

      if (!mounted) return;
      setState(() {
        _tvDeviceCode = deviceCode;
        _tvUserCode = userCode;
        _tvLoginUrl = loginUrl;
        _tvExpiresAt = expiresAt;
      });

      _tvPollTimer?.cancel();
      _tvPollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        unawaited(_pollTvLogin());
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _tvLoginError = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _tvLoginError = 'Unable to start TV login right now.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _startingTvLogin = false;
        });
      }
    }
  }

  Future<void> _pollTvLogin() async {
    final deviceCode = _tvDeviceCode;
    if (_pollingTvLogin || deviceCode == null || deviceCode.isEmpty) {
      return;
    }

    _pollingTvLogin = true;
    final auth = context.read<AuthStore>();
    try {
      final response = await auth.api.get(
        '/auth/tv/poll?device_code=${Uri.encodeQueryComponent(deviceCode)}',
      );
      if (response is! Map<String, dynamic>) {
        return;
      }

      final status = (response['status'] as String?)?.toLowerCase();
      if (status != 'approved') {
        return;
      }

      final authJson = response['auth'];
      if (authJson is! Map<String, dynamic>) {
        return;
      }

      _tvPollTimer?.cancel();
      await auth.completeLoginFromJson(authJson);
    } on ApiException catch (e) {
      final message = e.message.toLowerCase();
      if (message.contains('expired') || message.contains('used')) {
        _tvPollTimer?.cancel();
        if (mounted) {
          setState(() {
            _tvLoginError = 'QR code expired. Generate a new one.';
          });
        }
      }
    } finally {
      _pollingTvLogin = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthStore>();
    final theme = Theme.of(context);
    final viewInsets = MediaQuery.viewInsetsOf(context);

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0A1020), Color(0xFF0D1117)],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  16,
                  16,
                  16,
                  16 + viewInsets.bottom,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - 32,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Card(
                        margin: const EdgeInsets.all(8),
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Form(
                            key: _formKey,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Icon(
                                  Icons.live_tv_rounded,
                                  size: 36,
                                  color: theme.colorScheme.primary,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Welcome back',
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Sign in to continue watching.',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: Colors.white70,
                                  ),
                                ),
                                const SizedBox(height: 20),
                                TextFormField(
                                  controller: _emailCtrl,
                                  decoration: const InputDecoration(
                                    labelText: 'Email',
                                    prefixIcon: Icon(Icons.alternate_email),
                                  ),
                                  keyboardType: TextInputType.emailAddress,
                                  validator: (value) {
                                    final v = value?.trim() ?? '';
                                    if (v.isEmpty) {
                                      return 'Required';
                                    }
                                    if (!v.contains('@')) {
                                      return 'Enter a valid email';
                                    }
                                    return null;
                                  },
                                ),
                                const SizedBox(height: 12),
                                TextFormField(
                                  controller: _passwordCtrl,
                                  decoration: const InputDecoration(
                                    labelText: 'Password',
                                    prefixIcon: Icon(Icons.lock_outline),
                                  ),
                                  obscureText: true,
                                  validator: (value) =>
                                      value == null || value.isEmpty
                                      ? 'Required'
                                      : null,
                                ),
                                if (_error != null) ...[
                                  const SizedBox(height: 12),
                                  Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF3A1518),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: const Color(0xFF7F1D1D),
                                      ),
                                    ),
                                    child: Text(
                                      _error!,
                                      style: const TextStyle(
                                        color: Color(0xFFFCA5A5),
                                      ),
                                    ),
                                  ),
                                  if (_showVerifyAction) ...[
                                    const SizedBox(height: 8),
                                    TextButton(
                                      onPressed: auth.busy
                                          ? null
                                          : () {
                                              Navigator.of(context).push(
                                                MaterialPageRoute<void>(
                                                  builder: (_) =>
                                                      RegisterScreen(
                                                        initialEmail: _emailCtrl
                                                            .text
                                                            .trim(),
                                                        startInVerification:
                                                            true,
                                                      ),
                                                ),
                                              );
                                            },
                                      child: const Text(
                                        'Enter verification code',
                                      ),
                                    ),
                                  ],
                                ],
                                const SizedBox(height: 18),
                                FilledButton(
                                  onPressed: auth.busy ? null : _submit,
                                  child: auth.busy
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Text('Sign In'),
                                ),
                                const SizedBox(height: 16),
                                Row(
                                  children: [
                                    const Expanded(child: Divider()),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                      ),
                                      child: Text(
                                        'TV quick login',
                                        style: theme.textTheme.labelMedium,
                                      ),
                                    ),
                                    const Expanded(child: Divider()),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'Scan this QR code with your phone, sign in there, and this TV signs in automatically.',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: Colors.white70,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF111827),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: const Color(0xFF374151),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (_startingTvLogin)
                                        const Center(
                                          child: Padding(
                                            padding: EdgeInsets.symmetric(
                                              vertical: 24,
                                            ),
                                            child: CircularProgressIndicator(),
                                          ),
                                        )
                                      else if (_tvLoginUrl != null) ...[
                                        Center(
                                          child: Container(
                                            color: Colors.white,
                                            padding: const EdgeInsets.all(10),
                                            child: QrImageView(
                                              data: _tvLoginUrl!,
                                              size: 170,
                                              backgroundColor: Colors.white,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                        Text(
                                          'Enter code ${_tvUserCode ?? '-'} on your phone',
                                          textAlign: TextAlign.center,
                                          style: theme.textTheme.titleSmall
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                        if (_tvExpiresAt != null) ...[
                                          const SizedBox(height: 6),
                                          Text(
                                            'Expires at ${TimeOfDay.fromDateTime(_tvExpiresAt!).format(context)}',
                                            textAlign: TextAlign.center,
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                                  color: Colors.white70,
                                                ),
                                          ),
                                        ],
                                      ],
                                      if (_tvLoginError != null) ...[
                                        const SizedBox(height: 8),
                                        Text(
                                          _tvLoginError!,
                                          style: const TextStyle(
                                            color: Color(0xFFFCA5A5),
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                      ],
                                      const SizedBox(height: 10),
                                      OutlinedButton.icon(
                                        onPressed: _startingTvLogin
                                            ? null
                                            : _startTvLogin,
                                        icon: const Icon(Icons.qr_code_2),
                                        label: const Text(
                                          'Generate new QR code',
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton(
                                    onPressed: auth.busy
                                        ? null
                                        : () {
                                            Navigator.of(context).push(
                                              MaterialPageRoute<void>(
                                                builder: (_) =>
                                                    const ForgotPasswordScreen(),
                                              ),
                                            );
                                          },
                                    child: const Text('Forgot password?'),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                TextButton(
                                  onPressed: auth.busy
                                      ? null
                                      : () {
                                          Navigator.of(context).push(
                                            MaterialPageRoute<void>(
                                              builder: (_) =>
                                                  const RegisterScreen(),
                                            ),
                                          );
                                        },
                                  child: const Text('Create account'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
