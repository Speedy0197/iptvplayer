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

    if (logoUrl.isEmpty) {
      return fallback;
    }

    return ClipOval(
      child: SizedBox(
        width: radius * 2,
        height: radius * 2,
        child: Image.network(
          logoUrl,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => fallback,
        ),
      ),
    );
  }
}
