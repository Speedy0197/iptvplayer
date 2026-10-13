import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_store.dart';
import '../widgets/account_page.dart';
import 'home/dialogs/confirm_dialog.dart';
import 'tv_pairing_screen.dart';

class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthStore>();
    return AccountPage(
      title: 'Account',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Your account',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(auth.username ?? 'Signed in'),
          const SizedBox(height: 24),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.tv),
            title: const Text('Sign in on a TV'),
            subtitle: const Text('Enter a code or scan the TV’s QR link'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const TvPairingScreen()),
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
            onPressed: () async {
              final confirmed = await showConfirmDialog(
                context,
                title: 'Sign out',
                message: 'Sign out of StreamPilot on this device?',
                confirmLabel: 'Sign out',
                confirmIcon: Icons.logout,
              );
              if (confirmed != true || !context.mounted) return;
              await auth.logout();
              if (context.mounted) {
                Navigator.of(context).popUntil((route) => route.isFirst);
              }
            },
          ),
        ],
      ),
    );
  }
}
