import 'package:flutter/material.dart';

import '../../core/theme.dart';

class ChartPoint {
  const ChartPoint({required this.value, this.tip});

  final num value;
  final String? tip;
}

/// Legacy chartBox: titled box of custom-painted vertical bars. Bar height is
/// relative to the series max with a 3% floor so zero days stay visible.
class BarChart extends StatelessWidget {
  const BarChart({
    super.key,
    required this.title,
    required this.points,
    this.height = 90,
  });

  final String title;
  final List<ChartPoint> points;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return Container(
      padding: const EdgeInsets.all(AriaSpace.s4),
      decoration: BoxDecoration(
        color: c.bgRaised,
        borderRadius: BorderRadius.circular(AriaRadius.md),
        border: Border.all(color: c.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: AriaSpace.s3),
          SizedBox(
            height: height,
            width: double.infinity,
            child: CustomPaint(
              painter: _BarsPainter(
                points: points,
                barColor: c.fgDim,
                zeroColor: c.bgHover,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter({
    required this.points,
    required this.barColor,
    required this.zeroColor,
  });

  final List<ChartPoint> points;
  final Color barColor;
  final Color zeroColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final max = points.fold<num>(1, (m, p) => p.value > m ? p.value : m);
    const gap = 2.0;
    final barW = (size.width - gap * (points.length - 1)) / points.length;
    final paint = Paint();
    for (var i = 0; i < points.length; i++) {
      final v = points[i].value;
      // Legacy: Math.max(3, round(v / max * 100)) percent.
      final frac = (v / max).clamp(0.03, 1.0);
      final h = size.height * frac;
      paint.color = v > 0 ? barColor : zeroColor;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * (barW + gap), size.height - h, barW, h),
          const Radius.circular(1.5),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.points != points ||
      old.barColor != barColor ||
      old.zeroColor != zeroColor;
}

class MiniListRow {
  const MiniListRow({
    required this.label,
    this.sub,
    required this.n,
    this.onTap,
  });

  final String label;
  final String? sub;
  final int n;
  final VoidCallback? onTap;
}

/// Legacy miniList: numbered top-5 with a right-aligned count column.
class MiniList extends StatelessWidget {
  const MiniList({super.key, required this.title, required this.rows});

  final String title;
  final List<MiniListRow> rows;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return Container(
      padding: const EdgeInsets.all(AriaSpace.s4),
      decoration: BoxDecoration(
        color: c.bgRaised,
        borderRadius: BorderRadius.circular(AriaRadius.md),
        border: Border.all(color: c.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: AriaSpace.s2),
          for (var i = 0; i < rows.length; i++)
            InkWell(
              onTap: rows[i].onTap,
              borderRadius: BorderRadius.circular(AriaRadius.sm),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    SizedBox(
                      width: 22,
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(color: c.fgDim, fontSize: 12.5),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            rows[i].label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (rows[i].sub != null && rows[i].sub!.isNotEmpty)
                            Text(
                              rows[i].sub!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: c.fgDim),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AriaSpace.s2),
                    Text(
                      '${rows[i].n}',
                      style: TextStyle(color: c.fgDim, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
