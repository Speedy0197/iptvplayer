import 'package:flutter/material.dart';

class ChannelLogoAvatar extends StatelessWidget {
  final String logoUrl;
  final double radius;
  final double iconSize;

  const ChannelLogoAvatar({
    super.key,
    required this.logoUrl,
    this.radius = 20,
    this.iconSize = 20,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = CircleAvatar(
      radius: radius,
      child: Icon(Icons.tv, size: iconSize),
    );

    final effectiveLogoUrl = logoUrl.trim();

    if (effectiveLogoUrl.isEmpty) {
      return fallback;
    }

    return ClipOval(
      child: SizedBox(
        width: radius * 2,
        height: radius * 2,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Image.network(
            effectiveLogoUrl,
            fit: BoxFit.contain,
            alignment: Alignment.center,
            errorBuilder: (context, error, stackTrace) => fallback,
          ),
        ),
      ),
    );
  }
}
