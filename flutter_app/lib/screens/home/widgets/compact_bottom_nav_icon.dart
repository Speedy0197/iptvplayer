import 'package:flutter/material.dart';

class CompactBottomNavActiveIcon extends StatelessWidget {
  final IconData icon;

  const CompactBottomNavActiveIcon({super.key, required this.icon});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.35)),
      ),
      child: Icon(icon, color: colorScheme.primary),
    );
  }
}
