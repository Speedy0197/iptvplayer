import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import '../services/auth_store.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({
    super.key,
    this.initialEmail,
    this.startInVerification = false,
  });

  final String? initialEmail;
  final bool startInVerification;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _registerFormKey = GlobalKey<FormState>();
  final _verifyFormKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();

  String? _error;
  String? _info;
  bool _awaitingVerification = false;

  @override
  void initState() {
    super.initState();
    _awaitingVerification = widget.startInVerification;
    if ((widget.initialEmail ?? '').trim().isNotEmpty) {
      _emailCtrl.text = widget.initialEmail!.trim();
    }
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _editField({
    required String title,
    required TextEditingController controller,
    bool obscure = false,
    TextInputType? keyboardType,
  }) async {
    final tempController = TextEditingController(text: controller.text);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: tempController,
            autofocus: true,
            obscureText: obscure,
            keyboardType: keyboardType,
            decoration: InputDecoration(labelText: title),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(
                tempController.text,
              ),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    tempController.dispose();
    if (value == null || !mounted) return;
    setState(() {
      controller.text = value.trimRight();
    });
  }

  Future<void> _submitRegister() async {
    final auth = context.read<AuthStore>();
    final directionalNavigation =
        MediaQuery.maybeNavigationModeOf(context) == NavigationMode.directional;
    if (!directionalNavigation) {
      if (!_registerFormKey.currentState!.validate()) return;
    } else {
      final email = _emailCtrl.text.trim();
      final password = _passwordCtrl.text;
      final confirm = _confirmCtrl.text;
      if (email.isEmpty || !email.contains('@')) {
        setState(() => _error = 'Enter a valid email');
        return;
      }
      if (password.length < 8) {
        setState(() => _error = 'Password must be at least 8 characters');
        return;
      }
      if (confirm != password) {
        setState(() => _error = 'Passwords do not match');
        return;
      }
    }

    setState(() {
      _error = null;
      _info = null;
    });
    try {
      await auth.register(_emailCtrl.text.trim(), _passwordCtrl.text);
      if (mounted) {
        setState(() {
          _awaitingVerification = true;
          _info = 'A 4-digit verification code has been sent to your email.';
        });
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Registration failed');
    }
  }

  Future<void> _verifyCode() async {
    final auth = context.read<AuthStore>();
    final directionalNavigation =
        MediaQuery.maybeNavigationModeOf(context) == NavigationMode.directional;
    if (!directionalNavigation) {
      if (!_verifyFormKey.currentState!.validate()) return;
    } else {
      final code = _codeCtrl.text.trim();
      if (!RegExp(r'^\d{4}$').hasMatch(code)) {
        setState(() => _error = 'Enter the 4-digit code');
        return;
      }
    }

    setState(() {
      _error = null;
      _info = null;
    });

    try {
      await auth.verifyEmail(_emailCtrl.text.trim(), _codeCtrl.text.trim());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Email verified. You can now sign in.')),
      );
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Verification failed');
    }
  }

  Future<void> _resendCode() async {
    final auth = context.read<AuthStore>();

    setState(() {
      _error = null;
      _info = null;
    });

    try {
      await auth.resendVerification(_emailCtrl.text.trim());
      setState(() {
        _info = 'A new verification code has been sent.';
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Unable to resend code');
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthStore>();
    final theme = Theme.of(context);
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final directionalNavigation =
        MediaQuery.maybeNavigationModeOf(context) == NavigationMode.directional;

    return Scaffold(
      appBar: AppBar(title: const Text('Create account')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + viewInsets.bottom),
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
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              _awaitingVerification
                                  ? 'Verify your email'
                                  : 'Create your profile',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _awaitingVerification
                                  ? 'Enter the 4-digit code we emailed to continue.'
                                  : 'Set up your email and password to get started.',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: Colors.white70,
                              ),
                            ),
                            const SizedBox(height: 20),
                            if (!_awaitingVerification)
                              Form(
                                key: _registerFormKey,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (!directionalNavigation)
                                      TextFormField(
                                        controller: _emailCtrl,
                                        decoration: const InputDecoration(
                                          labelText: 'Email',
                                          prefixIcon: Icon(
                                            Icons.alternate_email,
                                          ),
                                        ),
                                        keyboardType:
                                            TextInputType.emailAddress,
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
                                      )
                                    else
                                      OutlinedButton.icon(
                                        onPressed: auth.busy
                                            ? null
                                            : () => _editField(
                                                title: 'Email',
                                                controller: _emailCtrl,
                                                keyboardType:
                                                    TextInputType.emailAddress,
                                              ),
                                        icon: const Icon(Icons.alternate_email),
                                        label: Text(
                                          _emailCtrl.text.trim().isEmpty
                                              ? 'Set email'
                                              : _emailCtrl.text.trim(),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    const SizedBox(height: 12),
                                    if (!directionalNavigation)
                                      TextFormField(
                                        controller: _passwordCtrl,
                                        decoration: const InputDecoration(
                                          labelText: 'Password',
                                          prefixIcon: Icon(Icons.lock_outline),
                                        ),
                                        obscureText: true,
                                        validator: (value) {
                                          final v = value ?? '';
                                          if (v.isEmpty) {
                                            return 'Required';
                                          }
                                          if (v.length < 8) {
                                            return 'At least 8 characters';
                                          }
                                          return null;
                                        },
                                      )
                                    else
                                      OutlinedButton.icon(
                                        onPressed: auth.busy
                                            ? null
                                            : () => _editField(
                                                title: 'Password',
                                                controller: _passwordCtrl,
                                                obscure: true,
                                              ),
                                        icon: const Icon(Icons.lock_outline),
                                        label: Text(
                                          _passwordCtrl.text.isEmpty
                                              ? 'Set password'
                                              : 'Password set',
                                        ),
                                      ),
                                    const SizedBox(height: 12),
                                    if (!directionalNavigation)
                                      TextFormField(
                                        controller: _confirmCtrl,
                                        decoration: const InputDecoration(
                                          labelText: 'Confirm password',
                                          prefixIcon: Icon(
                                            Icons.verified_user_outlined,
                                          ),
                                        ),
                                        obscureText: true,
                                        validator: (value) {
                                          if (value == null || value.isEmpty) {
                                            return 'Required';
                                          }
                                          if (value != _passwordCtrl.text) {
                                            return 'Passwords do not match';
                                          }
                                          return null;
                                        },
                                      )
                                    else
                                      OutlinedButton.icon(
                                        onPressed: auth.busy
                                            ? null
                                            : () => _editField(
                                                title: 'Confirm password',
                                                controller: _confirmCtrl,
                                                obscure: true,
                                              ),
                                        icon: const Icon(
                                          Icons.verified_user_outlined,
                                        ),
                                        label: Text(
                                          _confirmCtrl.text.isEmpty
                                              ? 'Confirm password'
                                              : 'Confirmation set',
                                        ),
                                      ),
                                    const SizedBox(height: 18),
                                    FilledButton(
                                      onPressed: auth.busy
                                          ? null
                                          : _submitRegister,
                                      child: auth.busy
                                          ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : const Text('Register'),
                                    ),
                                  ],
                                ),
                              ),
                            if (_awaitingVerification)
                              Form(
                                key: _verifyFormKey,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    TextFormField(
                                      controller: _emailCtrl,
                                      enabled: false,
                                      decoration: const InputDecoration(
                                        labelText: 'Email',
                                        prefixIcon: Icon(Icons.alternate_email),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    if (!directionalNavigation)
                                      TextFormField(
                                        controller: _codeCtrl,
                                        decoration: const InputDecoration(
                                          labelText: '4-digit code',
                                          prefixIcon: Icon(
                                            Icons.verified_user_outlined,
                                          ),
                                        ),
                                        keyboardType: TextInputType.number,
                                        validator: (value) {
                                          final v = (value ?? '').trim();
                                          if (!RegExp(
                                            r'^\d{4}$',
                                          ).hasMatch(v)) {
                                            return 'Enter the 4-digit code';
                                          }
                                          return null;
                                        },
                                      )
                                    else
                                      OutlinedButton.icon(
                                        onPressed: auth.busy
                                            ? null
                                            : () => _editField(
                                                title: '4-digit code',
                                                controller: _codeCtrl,
                                                keyboardType:
                                                    TextInputType.number,
                                              ),
                                        icon: const Icon(
                                          Icons.verified_user_outlined,
                                        ),
                                        label: Text(
                                          _codeCtrl.text.trim().isEmpty
                                              ? 'Enter 4-digit code'
                                              : _codeCtrl.text.trim(),
                                        ),
                                      ),
                                    const SizedBox(height: 18),
                                    FilledButton(
                                      onPressed: auth.busy ? null : _verifyCode,
                                      child: auth.busy
                                          ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : const Text('Verify email'),
                                    ),
                                    const SizedBox(height: 8),
                                    TextButton(
                                      onPressed: auth.busy ? null : _resendCode,
                                      child: const Text('Resend code'),
                                    ),
                                  ],
                                ),
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
                            ],
                            if (_info != null) ...[
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF14243A),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: const Color(0xFF1F3E66),
                                  ),
                                ),
                                child: Text(
                                  _info!,
                                  style: const TextStyle(
                                    color: Color(0xFFBFDBFE),
                                  ),
                                ),
                              ),
                            ],
                          ],
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
    );
  }
}
