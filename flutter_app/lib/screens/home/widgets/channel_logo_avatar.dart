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
      assert(() {
        debugPrint('[channel-logo] empty logoUrl, using fallback icon');
        return true;
      }());
      return fallback;
    }

    return ClipOval(
      child: SizedBox(
        width: radius * 2,
        height: radius * 2,
        child: Image.network(
          logoUrl,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            assert(() {
              debugPrint(
                '[channel-logo] failed loading logo url=$logoUrl error=$error',
              );
              return true;
            }());
            return fallback;
          },
        ),
      ),
    );
  }
}
