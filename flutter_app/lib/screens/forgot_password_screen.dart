import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import '../services/auth_store.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _requestFormKey = GlobalKey<FormState>();
  final _resetFormKey = GlobalKey<FormState>();

  final _emailCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  final _newPasswordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _requestBusy = false;
  bool _resetBusy = false;
  String? _requestMessage;
  String? _resetError;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _tokenCtrl.dispose();
    _newPasswordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _requestReset() async {
    if (!_requestFormKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _requestBusy = true;
      _requestMessage = null;
      _resetError = null;
    });

    final auth = context.read<AuthStore>();
    try {
      await auth.requestPasswordReset(_emailCtrl.text.trim());
      if (!mounted) {
        return;
      }
      setState(() {
        _requestMessage =
            'If an account exists for this email, a 4-digit reset code has been sent.';
      });
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _requestMessage = e.message;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _requestMessage = 'Unable to send reset request right now.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _requestBusy = false;
        });
      }
    }
  }

  Future<void> _submitNewPassword() async {
    if (!_resetFormKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _resetBusy = true;
      _resetError = null;
    });

    final auth = context.read<AuthStore>();
    final email = _emailCtrl.text.trim();
    final code = _tokenCtrl.text.trim();
    try {
      await auth.verifyResetToken(email, code);
      await auth.resetPassword(email, code, _newPasswordCtrl.text);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password updated. Please sign in.')),
      );
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _resetError = e.message;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _resetError = 'Password reset failed.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _resetBusy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reset password')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Form(
                      key: _requestFormKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'Step 1: Request reset code',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 12),
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
                          FilledButton(
                            onPressed: _requestBusy ? null : _requestReset,
                            child: _requestBusy
                                ? const SizedBox(
                                    height: 18,
                                    width: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text('Send reset token'),
                          ),
                          if (_requestMessage != null) ...[
                            const SizedBox(height: 8),
                            Text(_requestMessage!),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Form(
                      key: _resetFormKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'Step 2: Set new password',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _tokenCtrl,
                            decoration: const InputDecoration(
                              labelText: '4-digit reset code',
                              prefixIcon: Icon(Icons.key_outlined),
                            ),
                            keyboardType: TextInputType.number,
                            validator: (value) {
                              final v = (value ?? '').trim();
                              final is4Digits = RegExp(r'^\d{4}$').hasMatch(v);
                              if (!is4Digits) {
                                return 'Enter the 4-digit code';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _newPasswordCtrl,
                            decoration: const InputDecoration(
                              labelText: 'New password',
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
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _confirmCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Confirm new password',
                              prefixIcon: Icon(Icons.verified_user_outlined),
                            ),
                            obscureText: true,
                            validator: (value) {
                              if (value == null || value.isEmpty) {
                                return 'Required';
                              }
                              if (value != _newPasswordCtrl.text) {
                                return 'Passwords do not match';
                              }
                              return null;
                            },
                          ),
                          if (_resetError != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              _resetError!,
                              style: const TextStyle(color: Colors.redAccent),
                            ),
                          ],
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _resetBusy ? null : _submitNewPassword,
                            child: _resetBusy
                                ? const SizedBox(
                                    height: 18,
                                    width: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text('Update password'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
