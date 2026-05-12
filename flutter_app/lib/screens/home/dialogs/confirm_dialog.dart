import 'package:flutter/material.dart';

import '../../../config/device_utils.dart';

/// Shows a confirmation dialog.
///
/// On Android TV the dialog is presented as a modal bottom sheet with large,
/// D-pad-navigable buttons (matching the focus-highlight style used in the
/// watch and favorites action sheets). On all other platforms a standard
/// [AlertDialog] is shown instead.
///
/// Returns `true` when the user confirms, `false` / `null` when they cancel.
Future<bool?> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  required IconData confirmIcon,
  Color? confirmIconColor,
  String cancelLabel = 'Cancel',
}) {
  if (isAndroidTv(context)) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _TvConfirmSheet(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        confirmIcon: confirmIcon,
        confirmIconColor: confirmIconColor,
        cancelLabel: cancelLabel,
      ),
    );
  }

  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
}

class _TvConfirmSheet extends StatelessWidget {
  final String title;
  final String message;
  final String confirmLabel;
  final IconData confirmIcon;
  final Color? confirmIconColor;
  final String cancelLabel;

  const _TvConfirmSheet({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.confirmIcon,
    this.confirmIconColor,
    required this.cancelLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
              child: Text(title, style: theme.textTheme.titleLarge),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
              child: Text(message, style: theme.textTheme.bodyMedium),
            ),
            _TvButton(
              icon: confirmIcon,
              iconColor: confirmIconColor,
              label: confirmLabel,
              autofocus: true,
              onPressed: () => Navigator.of(context).pop(true),
            ),
            const SizedBox(height: 8),
            _TvButton(
              icon: Icons.close,
              label: cancelLabel,
              onPressed: () => Navigator.of(context).pop(false),
            ),
          ],
        ),
      ),
    );
  }
}

class _TvButton extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String label;
  final VoidCallback onPressed;
  final bool autofocus;

  const _TvButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.iconColor,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: FilledButton.tonalIcon(
        autofocus: autofocus,
        onPressed: onPressed,
        icon: Icon(icon, color: iconColor),
        label: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            label,
            style: const TextStyle(fontSize: 20),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        style: FilledButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 20),
        ),
      ),
    );
  }
}
