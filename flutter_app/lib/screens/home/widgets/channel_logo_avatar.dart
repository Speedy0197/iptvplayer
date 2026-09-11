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

    // Bound decoded memory to the on-screen size, including high-DPI displays.
    // Fit both dimensions so wide/tall provider logos retain their aspect ratio.
    final decodeSize = (radius * 2 * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(1, 4096);

    return ClipOval(
      child: SizedBox(
        width: radius * 2,
        height: radius * 2,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Image(
            image: ResizeImage(
              NetworkImage(effectiveLogoUrl),
              width: decodeSize,
              height: decodeSize,
              policy: ResizeImagePolicy.fit,
            ),
            fit: BoxFit.contain,
            alignment: Alignment.center,
            errorBuilder: (context, error, stackTrace) => fallback,
          ),
        ),
      ),
    );
  }
}
