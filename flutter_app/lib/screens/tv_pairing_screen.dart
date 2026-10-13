import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import '../services/auth_store.dart';
import '../services/tv_pairing.dart';
import '../widgets/account_page.dart';
import 'login_screen.dart';

class TvPairingScreen extends StatefulWidget {
  const TvPairingScreen({super.key, this.pairingToken});
  final String? pairingToken;
  @override
  State<TvPairingScreen> createState() => _TvPairingScreenState();
}

class _TvPairingScreenState extends State<TvPairingScreen> {
  final _code = TextEditingController();
  String? _token;
  TvPairingSession? _session;
  Timer? _expiryTimer;
  bool _loading = false;
  bool _submitting = false;
  String? _error;
  String? _completed;
  bool _expired = false;

  TvPairingService get _service =>
      TvPairingService(context.read<AuthStore>().api);

  @override
  void initState() {
    super.initState();
    _token = widget.pairingToken;
    if (_token != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    _code.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final token = _token ?? await _service.lookup(_code.text.trim());
      final session = await _service.load(token);
      if (!mounted) return;
      _expiryTimer?.cancel();
      setState(() {
        _token = token;
        _session = session;
        _expired = !session.expiresAt.isAfter(DateTime.now());
        _completed = session.status == 'approved'
            ? 'TV connected'
            : session.status == 'declined'
            ? 'Request declined'
            : null;
      });
      if (!_expired && _completed == null) {
        _expiryTimer = Timer(session.expiresAt.difference(DateTime.now()), () {
          if (mounted) setState(() => _expired = true);
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = _message(e.message));
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Unable to read this request. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _message(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('expired') ||
        lower.contains('already used') ||
        lower.contains('http 410')) {
      _expired = true;
      return 'Generate a new QR code on the TV and scan it again.';
    }
    // Endpoint failures cannot turn opaque link or provider values into UI copy.
    if (lower.contains('http') ||
        lower.contains('token') ||
        message.length > 160) {
      return 'This request is unavailable. Generate a new QR code on the TV.';
    }
    return message;
  }

  Future<void> _respond(bool approve) async {
    if (_submitting || _expired || _token == null || _completed != null) return;
    if (_session?.expiresAt.isAfter(DateTime.now()) != true) {
      setState(() => _expired = true);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      if (approve) {
        await _service.approve(_token!);
      } else {
        await _service.decline(_token!);
      }
      if (!mounted) return;
      _expiryTimer?.cancel();
      setState(
        () => _completed = approve ? 'TV connected' : 'Request declined',
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.message == 'HTTP 401' ||
          e.message.toLowerCase() == 'unauthorized') {
        await context.read<AuthStore>().logout();
      } else {
        setState(() => _error = _message(e.message));
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Unable to respond right now. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthStore>();
    if (auth.initializing) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!auth.isLoggedIn && !_expired && _completed == null) {
      return const LoginScreen(intentText: 'Sign in to approve your TV.');
    }
    final theme = Theme.of(context);
    final title =
        _completed ??
        (_expired ? 'Pairing request expired' : 'Sign in on your TV');
    return AccountPage(
      title: 'TV pairing',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_completed != null) ...[
            Icon(
              _completed == 'TV connected'
                  ? Icons.check_circle_outline
                  : Icons.cancel_outlined,
              size: 48,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 18),
          ],
          Text(
            title,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          if (_completed != null || _expired) ...[
            Text(
              _expired
                  ? 'Generate a new QR code on the TV and scan it again.'
                  : _completed == 'TV connected'
                  ? 'Your TV can now finish signing in. You can return to watching.'
                  : 'This TV has not been signed in to your account.',
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Done'),
            ),
          ] else if (_loading) ...[
            const SizedBox(height: 20),
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 12),
            const Text('Reading the TV request…', textAlign: TextAlign.center),
          ] else if (_session != null) ...[
            Text(
              'Approve this TV using ${auth.username ?? 'your signed-in account'}.',
            ),
            const SizedBox(height: 24),
            Text(_session!.deviceName, style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            Semantics(
              label: 'Matching TV code ${_session!.userCode}',
              child: Text(
                _session!.userCode,
                style: theme.textTheme.headlineMedium?.copyWith(
                  letterSpacing: 5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text('Check that this code matches the one on your TV.'),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _submitting ? null : () => _respond(true),
              icon: _submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.tv),
              label: Text(_submitting ? 'Approving…' : 'Approve TV'),
            ),
            TextButton(
              onPressed: _submitting ? null : () => _respond(false),
              child: const Text('Decline'),
            ),
          ] else if (_token == null) ...[
            const Text(
              'Enter the 6-digit code displayed by StreamPilot on your TV, or scan its QR code.',
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              autofillHints: const [AutofillHints.oneTimeCode],
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'TV code',
                hintText: '123456',
              ),
              onSubmitted: (_) => _load(),
            ),
            const SizedBox(height: 18),
            FilledButton(onPressed: _load, child: const Text('Find TV')),
          ],
          if (_error != null && !_expired) ...[
            const SizedBox(height: 16),
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
            if (_session == null && _token != null)
              TextButton(onPressed: _load, child: const Text('Try again')),
          ],
        ],
      ),
    );
  }
}
