import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class LegendRow extends StatelessWidget {
  const LegendRow({
    super.key,
    required this.color,
    required this.text,
    required this.range,
  });

  final Color color;
  final String text;
  final String range;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 12,
            height: 10,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text, style: const TextStyle(fontSize: 12)),
              Text(
                range,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(fontSize: 10),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class PopupVPointerPainter extends CustomPainter {
  const PopupVPointerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = const Color(0xFF9AA5A3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    final topLeft = const Offset(1, 1);
    final tip = Offset(size.width / 2, size.height - 1);
    final topRight = Offset(size.width - 1, 1);
    canvas.drawLine(topLeft, tip, stroke);
    canvas.drawLine(tip, topRight, stroke);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class OverflowMarqueeText extends StatefulWidget {
  const OverflowMarqueeText({
    super.key,
    required this.text,
    this.style,
    this.pixelsPerSecond = 30,
    this.gapPixels = 28,
    this.alwaysScroll = false,
    this.deferTextUpdatesUntilLoopEnd = false,
    this.onLoopComplete,
  });

  final String text;
  final TextStyle? style;
  final double pixelsPerSecond;
  final double? gapPixels;
  final bool alwaysScroll;
  final bool deferTextUpdatesUntilLoopEnd;
  final VoidCallback? onLoopComplete;

  @override
  State<OverflowMarqueeText> createState() => _OverflowMarqueeTextState();
}

class _OverflowMarqueeTextState extends State<OverflowMarqueeText>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  late String _displayText;
  String? _queuedText;
  double _overflow = 0;
  bool _restartRequested = false;
  late final VoidCallback _tickListener;
  double _lastControllerValue = 0;
  TextPainter? _textPainter;
  bool _applyingOverflow = false;

  @override
  void initState() {
    super.initState();
    _displayText = widget.text;
    _controller = AnimationController(vsync: this);
    _tickListener = () {
      final controller = _controller;
      if (controller == null) return;
      final current = controller.value;
      if (_overflow > 0 && current < _lastControllerValue && mounted) {
        var textChanged = false;
        if (_queuedText != null) {
          _displayText = _queuedText!;
          _queuedText = null;
          _restartRequested = true;
          textChanged = true;
        }
        widget.onLoopComplete?.call();
        // A loop is seconds apart. Rebuilding here picks up deferred text.
        // The per-frame scroll must not setState: this state owns a
        // LayoutBuilder, and any descendant rebuild marks that builder dirty
        // and repaints the page layer that holds the map.
        if (textChanged && !_applyingOverflow) {
          setState(() {});
        }
      }
      _lastControllerValue = current;
    };
    _controller?.addListener(_tickListener);
  }

  @override
  void dispose() {
    _controller?.removeListener(_tickListener);
    _controller?.dispose();
    _controller = null;
    _textPainter?.dispose();
    _textPainter = null;
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant OverflowMarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      final canDefer =
          widget.deferTextUpdatesUntilLoopEnd &&
          _overflow > 0 &&
          (_controller?.isAnimating ?? false);
      if (canDefer) {
        _queuedText = widget.text;
      } else {
        _displayText = widget.text;
        _queuedText = null;
        _restartRequested = true;
      }
    }
    if (oldWidget.pixelsPerSecond != widget.pixelsPerSecond ||
        (oldWidget.gapPixels ?? 28) != (widget.gapPixels ?? 28) ||
        oldWidget.alwaysScroll != widget.alwaysScroll) {
      _restartRequested = true;
    }
  }

  void _updateOverflow(double overflow, double loopDistance) {
    _applyingOverflow = true;
    try {
      _applyOverflow(overflow, loopDistance);
    } finally {
      _applyingOverflow = false;
    }
  }

  void _applyOverflow(double overflow, double loopDistance) {
    final next = overflow < 0 ? 0.0 : overflow;
    final overflowChanged = (next - _overflow).abs() >= 0.5;
    if (!overflowChanged &&
        !_restartRequested &&
        (_overflow <= 0 || (_controller?.isAnimating ?? false))) {
      return;
    }
    _overflow = next;
    if (_overflow <= 0) {
      _controller?.stop();
      _controller?.value = 0;
      _lastControllerValue = 0;
      _restartRequested = false;
      return;
    }
    final speed = widget.pixelsPerSecond <= 0 ? 30.0 : widget.pixelsPerSecond;
    final durationMs = max(1200, ((loopDistance / speed) * 1000).round());
    final controller = _controller;
    if (controller == null) return;
    controller.duration = Duration(milliseconds: durationMs);
    if (_restartRequested || overflowChanged || !controller.isAnimating) {
      controller.stop();
      controller.value = 0;
      _lastControllerValue = 0;
      controller.repeat();
    }
    _restartRequested = false;
  }

  TextPainter _syncTextPainter(TextStyle style) {
    final painter = _textPainter ??= TextPainter(
      maxLines: 1,
      textDirection: ui.TextDirection.ltr,
    );
    final current = painter.text;
    if (current?.toPlainText() != _displayText || current?.style != style) {
      painter.text = TextSpan(text: _displayText, style: style);
      painter.layout(minWidth: 0, maxWidth: double.infinity);
    }
    return painter;
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style ?? Theme.of(context).textTheme.bodyMedium;
    final resolvedStyle = style ?? const TextStyle(fontSize: 14, height: 1.4);
    final lineHeight =
        (resolvedStyle.fontSize ?? 14) * (resolvedStyle.height ?? 1.4);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || constraints.maxWidth <= 0) {
          return Text(
            _displayText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          );
        }
        final paintStyle = style ?? const TextStyle();
        var textPainter = _syncTextPainter(paintStyle);
        var textWidth = textPainter.width;
        final configuredGap = widget.gapPixels ?? 28;
        final gap = configuredGap < 0 ? 0.0 : configuredGap;
        var shouldScroll =
            widget.alwaysScroll || textWidth > (constraints.maxWidth + 0.5);
        // Travel one full viewport width in addition to text width so the
        // line fully exits left before looping back from the right.
        var loopDistance = constraints.maxWidth + textWidth + gap;
        _updateOverflow(
          shouldScroll ? max(1.0, textWidth - constraints.maxWidth) : 0,
          loopDistance,
        );
        if (textPainter.text?.toPlainText() != _displayText) {
          textPainter = _syncTextPainter(paintStyle);
          textWidth = textPainter.width;
          shouldScroll =
              widget.alwaysScroll || textWidth > (constraints.maxWidth + 0.5);
          loopDistance = constraints.maxWidth + textWidth + gap;
          _updateOverflow(
            shouldScroll ? max(1.0, textWidth - constraints.maxWidth) : 0,
            loopDistance,
          );
        }
        if (!shouldScroll || _overflow <= 0) {
          if (_queuedText != null && _queuedText != _displayText) {
            _displayText = _queuedText!;
            _queuedText = null;
            _restartRequested = true;
            return Text(
              _displayText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            );
          }
          return Text(
            _displayText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          );
        }
        final controller = _controller;
        if (controller == null) {
          return Text(
            _displayText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          );
        }
        // LayoutBuilder rebuilds every descendant that setStates, then marks
        // itself needs-paint. That walk hits the page layer and re-rasters the
        // static map on every tick. Paint from the ticker instead, and keep
        // that picture in its own layer.
        return RepaintBoundary(
          child: SizedBox(
            height: lineHeight,
            width: constraints.maxWidth,
            child: Semantics(
              label: _displayText,
              child: CustomPaint(
                painter: _OverflowMarqueePainter(
                  animation: controller,
                  textPainter: textPainter,
                  loopDistance: loopDistance,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _OverflowMarqueePainter extends CustomPainter {
  _OverflowMarqueePainter({
    required this.animation,
    required this.textPainter,
    required this.loopDistance,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final TextPainter textPainter;
  final double loopDistance;

  @override
  void paint(Canvas canvas, Size size) {
    if ((textPainter.text?.toPlainText() ?? '').isEmpty) return;
    final dx = size.width - (loopDistance * animation.value);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    _paintCopy(canvas, size, dx);
    _paintCopy(canvas, size, dx + loopDistance);
    canvas.restore();
  }

  void _paintCopy(Canvas canvas, Size size, double originX) {
    final text = textPainter.text?.toPlainText() ?? '';
    final textWidth = textPainter.width;
    if (text.isEmpty || originX >= size.width || originX + textWidth <= 0) {
      return;
    }
    final localLeft = max(0.0, -originX);
    final localRight = min(textWidth, size.width - originX);
    if (localRight <= localLeft) return;

    final probeY = textPainter.height / 2;
    var start = textPainter
        .getPositionForOffset(Offset(localLeft, probeY))
        .offset;
    var end = textPainter
        .getPositionForOffset(Offset(max(localLeft, localRight - 0.1), probeY))
        .offset;
    if (start > 0) start -= 1;
    if (end < text.length) end += 1;
    if (end <= start) return;

    final slicePainter = TextPainter(
      text: TextSpan(
        text: text.substring(start, end),
        style: textPainter.text?.style,
      ),
      maxLines: 1,
      textDirection: ui.TextDirection.ltr,
    )..layout(minWidth: 0, maxWidth: double.infinity);
    final sliceX = textPainter
        .getOffsetForCaret(TextPosition(offset: start), Rect.zero)
        .dx;
    slicePainter.paint(canvas, Offset(originX + sliceX, 0));
    slicePainter.dispose();
  }

  @override
  bool shouldRepaint(covariant _OverflowMarqueePainter oldDelegate) {
    return animation != oldDelegate.animation ||
        textPainter != oldDelegate.textPainter ||
        loopDistance != oldDelegate.loopDistance ||
        textPainter.text?.toPlainText() !=
            oldDelegate.textPainter.text?.toPlainText() ||
        textPainter.text?.style != oldDelegate.textPainter.text?.style;
  }
}

class LegendSwatch extends StatelessWidget {
  const LegendSwatch({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

class ScanStatsPanel extends StatelessWidget {
  const ScanStatsPanel({
    super.key,
    required this.nodesCount,
    required this.isConnected,
    required this.activeZones,
    required this.deadZones,
    required this.avgRssi,
    required this.avgSnr,
    required this.statsRadiusMiles,
    required this.unitSystem,
    required this.hasObserver,
    this.onTapNodes,
    this.onTapScans,
  });

  final int nodesCount;
  final bool isConnected;
  final int activeZones;
  final int deadZones;
  final double avgRssi;
  final double avgSnr;
  final int statsRadiusMiles;
  final String unitSystem;
  final bool hasObserver;
  final VoidCallback? onTapNodes;
  final VoidCallback? onTapScans;

  @override
  Widget build(BuildContext context) {
    final showRadius = statsRadiusMiles > 0 && hasObserver;
    final radiusLabel = unitSystem == 'metric'
        ? 'Within ${(statsRadiusMiles * 1.60934).round()} km'
        : 'Within $statsRadiusMiles mi';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showRadius)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              radiusLabel,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontSize: 10),
              textAlign: TextAlign.center,
            ),
          ),
        GridView.count(
          crossAxisCount: 4,
          shrinkWrap: true,
          crossAxisSpacing: 6,
          mainAxisSpacing: 6,
          childAspectRatio: 1.15,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            _MiniStatCard(
              icon: Icons.settings_input_antenna,
              value: '$nodesCount',
              label: 'Nodes',
              sub: isConnected ? 'Active' : 'Offline',
              onTap: onTapNodes,
            ),
            _MiniStatCard(
              icon: Icons.place_outlined,
              value: '$activeZones',
              label: 'Zones',
              sub: '$deadZones dead',
              onTap: onTapScans,
            ),
            _MiniStatCard(
              icon: Icons.network_cell,
              value: avgRssi == 0 ? '--' : avgRssi.toStringAsFixed(0),
              label: 'Avg RSSI',
              sub: 'dBm',
            ),
            _MiniStatCard(
              icon: Icons.show_chart,
              value: avgSnr == 0 ? '--' : avgSnr.toStringAsFixed(1),
              label: 'Avg SNR',
              sub: 'dB',
            ),
          ],
        ),
      ],
    );
  }
}

class _MiniStatCard extends StatelessWidget {
  const _MiniStatCard({
    required this.icon,
    required this.value,
    required this.label,
    required this.sub,
    this.onTap,
  });

  final IconData icon;
  final String value;
  final String label;
  final String sub;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final h = constraints.maxHeight;
            final tiny = h < 58;
            final compact = h < 66;
            final showSub = h >= 62;
            final iconSize = tiny ? 10.0 : (compact ? 11.0 : 12.0);
            final valueSize = tiny ? 12.0 : (compact ? 13.0 : 14.0);
            final labelSize = tiny ? 8.0 : (compact ? 9.0 : 10.0);
            final subSize = tiny ? 8.0 : 9.0;
            final topGap = tiny ? 0.0 : (compact ? 1.0 : 3.0);

            return Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 4,
                vertical: tiny ? 2 : (compact ? 4 : 6),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: iconSize,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  SizedBox(height: topGap),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: valueSize,
                      fontWeight: FontWeight.w700,
                      height: 1.0,
                    ),
                  ),
                  SizedBox(height: tiny ? 0 : 1),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontSize: labelSize,
                      height: 1.0,
                    ),
                  ),
                  if (showSub)
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: subSize,
                        height: 1.0,
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
