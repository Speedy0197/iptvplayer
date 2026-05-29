import 'package:flutter/material.dart';

class AdaptiveSingleLineText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final double minFontSize;
  final double stepGranularity;
  final TextOverflow overflow;

  const AdaptiveSingleLineText({
    super.key,
    required this.text,
    this.style,
    required this.minFontSize,
    this.stepGranularity = 0.5,
    this.overflow = TextOverflow.ellipsis,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final resolvedStyle = DefaultTextStyle.of(context).style.merge(style);
        final baseFontSize = resolvedStyle.fontSize ?? 14;

        if (!constraints.maxWidth.isFinite || constraints.maxWidth <= 0) {
          return Text(
            text,
            style: resolvedStyle,
            maxLines: 1,
            overflow: overflow,
            softWrap: false,
          );
        }

        final textDirection = Directionality.of(context);
        final scaler = MediaQuery.textScalerOf(context);
        var currentFontSize = baseFontSize;

        bool exceeds(double fontSize) {
          final painter = TextPainter(
            text: TextSpan(
              text: text,
              style: resolvedStyle.copyWith(fontSize: fontSize),
            ),
            maxLines: 1,
            textDirection: textDirection,
            textScaler: scaler,
            ellipsis: overflow == TextOverflow.ellipsis ? '…' : null,
          )..layout(maxWidth: constraints.maxWidth);
          return painter.didExceedMaxLines ||
              painter.width > constraints.maxWidth;
        }

        while (currentFontSize - stepGranularity >= minFontSize &&
            exceeds(currentFontSize)) {
          currentFontSize -= stepGranularity;
        }

        return Text(
          text,
          style: resolvedStyle.copyWith(fontSize: currentFontSize),
          maxLines: 1,
          overflow: overflow,
          softWrap: false,
        );
      },
    );
  }
}
