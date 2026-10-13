import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/api_client.dart';
import '../services/auth_store.dart';
import '../widgets/account_page.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});
  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  int _step = 0;
  bool _busy = false;
  bool _showPassword = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _editField(
    String label,
    TextEditingController controller,
    bool obscure,
    TextInputType keyboard,
  ) async {
    final edit = TextEditingController(text: controller.text);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: TextField(
          controller: edit,
          autofocus: true,
          obscureText: obscure,
          keyboardType: keyboard,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, edit.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    edit.dispose();
    if (mounted && value != null) setState(() => controller.text = value);
  }

  Future<void> _perform(
    Future<void> Function(AuthStore auth) action, {
    required int nextStep,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(context.read<AuthStore>());
      if (mounted) setState(() => _step = nextStep);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Unable to continue right now. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _emailError(String? value) {
    final v = (value ?? '').trim();
    return v.isEmpty || !v.contains('@') ? 'Enter a valid email' : null;
  }

  Future<void> _requestCode() async {
    final error = _emailError(_email.text);
    if (error != null) {
      setState(() => _error = error);
      _formKey.currentState?.validate();
      return;
    }
    await _perform(
      (auth) => auth.requestPasswordReset(_email.text.trim()),
      nextStep: 1,
    );
  }

  Future<void> _verifyCode() async {
    if (!RegExp(r'^\d{4}$').hasMatch(_code.text.trim())) {
      setState(() => _error = 'Enter the 4-digit code');
      _formKey.currentState?.validate();
      return;
    }
    await _perform(
      (auth) => auth.verifyResetToken(_email.text.trim(), _code.text.trim()),
      nextStep: 2,
    );
  }

  Future<void> _updatePassword() async {
    if (_password.text.length < 8 || _confirm.text != _password.text) {
      setState(
        () => _error = _password.text.length < 8
            ? 'At least 8 characters'
            : 'Passwords do not match',
      );
      _formKey.currentState?.validate();
      return;
    }
    await _perform((auth) async {
      await auth.resetPassword(
        _email.text.trim(),
        _code.text.trim(),
        _password.text,
      );
      if (!mounted) return;
      TextInput.finishAutofillContext();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password updated. Please sign in.')),
      );
      Navigator.of(context).maybePop();
    }, nextStep: 2);
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    TextInputType keyboard = TextInputType.text,
    bool password = false,
    Iterable<String>? autofill,
    String? Function(String?)? validator,
  }) {
    if (MediaQuery.maybeNavigationModeOf(context) ==
        NavigationMode.directional) {
      return OutlinedButton.icon(
        onPressed: _busy
            ? null
            : () => _editField(label, controller, password, keyboard),
        icon: Icon(password ? Icons.lock_outline : Icons.edit_outlined),
        label: Text(
          controller.text.isEmpty || password ? label : controller.text,
        ),
      );
    }
    return TextFormField(
      key: ValueKey(label),
      controller: controller,
      enabled: !_busy,
      keyboardType: keyboard,
      obscureText: password && !_showPassword,
      autofillHints: autofill,
      autocorrect: !password,
      enableSuggestions: !password,
      textInputAction: TextInputAction.next,
      validator: validator,
      inputFormatters: keyboard == TextInputType.number
          ? [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(4),
            ]
          : null,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: password
            ? IconButton(
                tooltip: _showPassword ? 'Hide password' : 'Show password',
                onPressed: () => setState(() => _showPassword = !_showPassword),
                icon: Icon(
                  _showPassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              )
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final titles = [
      'Reset your password',
      'Check your email',
      'Choose a new password',
    ];
    final descriptions = [
      'We’ll email you a 4-digit reset code.',
      'If an account exists for ${_email.text.trim()}, a code has been sent.',
      'Use at least 8 characters.',
    ];
    return AccountPage(
      title: 'Reset password',
      child: AutofillGroup(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Step ${_step + 1} of 3',
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              ),
              const SizedBox(height: 8),
              Text(
                titles[_step],
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(descriptions[_step]),
              const SizedBox(height: 24),
              if (_step == 0)
                _field(
                  'Email',
                  _email,
                  keyboard: TextInputType.emailAddress,
                  autofill: const [AutofillHints.email],
                  validator: _emailError,
                ),
              if (_step == 1)
                _field(
                  '4-digit reset code',
                  _code,
                  keyboard: TextInputType.number,
                  autofill: const [AutofillHints.oneTimeCode],
                  validator: (v) =>
                      RegExp(r'^\d{4}$').hasMatch((v ?? '').trim())
                      ? null
                      : 'Enter the 4-digit code',
                ),
              if (_step == 2) ...[
                _field(
                  'New password',
                  _password,
                  password: true,
                  autofill: const [AutofillHints.newPassword],
                  validator: (v) =>
                      (v ?? '').length < 8 ? 'At least 8 characters' : null,
                ),
                const SizedBox(height: 14),
                _field(
                  'Confirm new password',
                  _confirm,
                  password: true,
                  autofill: const [AutofillHints.newPassword],
                  validator: (v) =>
                      v != _password.text ? 'Passwords do not match' : null,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy
                    ? null
                    : [_requestCode, _verifyCode, _updatePassword][_step],
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        [
                          'Send reset code',
                          'Verify code',
                          'Update password',
                        ][_step],
                      ),
              ),
              if (_step == 1) ...[
                TextButton(
                  onPressed: _busy ? null : _requestCode,
                  child: const Text('Resend code'),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _step = 0;
                          _error = null;
                          _code.clear();
                        }),
                  child: const Text('Change email'),
                ),
              ],
              if (_step == 2)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _step = 1;
                          _error = null;
                          _code.clear();
                        }),
                  child: const Text('Use another code'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
