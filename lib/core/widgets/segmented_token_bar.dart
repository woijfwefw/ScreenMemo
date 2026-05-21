import 'package:flutter/material.dart';

class SegmentedTokenBarSegment {
  const SegmentedTokenBarSegment({required this.tokens, required this.color});

  final int tokens;
  final Color color;
}

/// A "storage usage" style horizontal segmented bar.
///
/// - `totalTokens` is the full capacity (e.g., model context window).
/// - Segments are sized by `tokens / totalTokens`.
class SegmentedTokenBar extends StatelessWidget {
  const SegmentedTokenBar({
    super.key,
    required this.totalTokens,
    required this.segments,
    this.height = 10,
    this.radius = 999,
    this.backgroundColor,
    this.borderColor,
  });

  final int totalTokens;
  final List<SegmentedTokenBarSegment> segments;
  final double height;
  final double radius;
  final Color? backgroundColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color bg =
        backgroundColor ?? theme.colorScheme.surfaceContainerHighest;
    final Color bd =
        borderColor ?? theme.colorScheme.outline.withValues(alpha: 0.35);

    final int denom = totalTokens <= 0 ? 1 : totalTokens;
    final List<SegmentedTokenBarSegment> visible = segments
        .where((s) => s.tokens > 0)
        .toList(growable: false);

    return LayoutBuilder(
      builder: (context, constraints) {
        final double? width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : null;
        return SizedBox(
          width: width,
          height: height,
          child: CustomPaint(
            size: Size(width ?? 0, height),
            painter: _SegmentedTokenBarPainter(
              totalTokens: denom,
              segments: visible,
              radius: radius,
              backgroundColor: bg,
              borderColor: bd,
            ),
          ),
        );
      },
    );
  }
}

class _SegmentedTokenBarPainter extends CustomPainter {
  const _SegmentedTokenBarPainter({
    required this.totalTokens,
    required this.segments,
    required this.radius,
    required this.backgroundColor,
    required this.borderColor,
  });

  final int totalTokens;
  final List<SegmentedTokenBarSegment> segments;
  final double radius;
  final Color backgroundColor;
  final Color borderColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final Radius corner = Radius.circular(radius);
    final RRect clip = RRect.fromRectAndRadius(Offset.zero & size, corner);
    final Paint paint = Paint()..isAntiAlias = true;

    paint.color = backgroundColor;
    canvas.drawRRect(clip, paint);

    canvas.save();
    canvas.clipRRect(clip, doAntiAlias: true);
    double x = 0;
    for (final SegmentedTokenBarSegment segment in segments) {
      final double width = (size.width * (segment.tokens / totalTokens)).clamp(
        0.0,
        size.width - x,
      );
      if (width <= 0) continue;
      paint.color = segment.color;
      canvas.drawRect(Rect.fromLTWH(x, 0, width, size.height), paint);
      x += width;
      if (x >= size.width) break;
    }
    canvas.restore();

    if ((borderColor.a * 255.0).round() > 0) {
      paint
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      final RRect border = clip.deflate(0.5);
      canvas.drawRRect(border, paint);
      paint.style = PaintingStyle.fill;
    }
  }

  @override
  bool shouldRepaint(covariant _SegmentedTokenBarPainter oldDelegate) {
    return oldDelegate.totalTokens != totalTokens ||
        oldDelegate.segments != segments ||
        oldDelegate.radius != radius ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.borderColor != borderColor;
  }
}
