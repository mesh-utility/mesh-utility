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
        if (_queuedText != null) {
          _displayText = _queuedText!;
          _queuedText = null;
          _restartRequested = true;
        }
        widget.onLoopComplete?.call();
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

  double _measureTextWidth(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: ui.TextDirection.ltr,
    )..layout(minWidth: 0, maxWidth: double.infinity);
    return painter.width;
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
        final textWidth = _measureTextWidth(
          _displayText,
          style ?? const TextStyle(),
        );
        final configuredGap = widget.gapPixels ?? 28;
        final gap = configuredGap < 0 ? 0.0 : configuredGap;
        final shouldScroll =
            widget.alwaysScroll || textWidth > (constraints.maxWidth + 0.5);
        // Travel one full viewport width in addition to text width so the
        // line fully exits left before looping back from the right.
        final loopDistance = constraints.maxWidth + textWidth + gap;
        _updateOverflow(
          shouldScroll ? max(1.0, textWidth - constraints.maxWidth) : 0,
          loopDistance,
        );
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
        return SizedBox(
          height: lineHeight,
          width: constraints.maxWidth,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _controller!,
              builder: (context, child) {
                final dx =
                    constraints.maxWidth - (loopDistance * _controller!.value);
                return Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    Positioned(
                      left: dx,
                      top: 0,
                      child: Text(
                        _displayText,
                        maxLines: 1,
                        softWrap: false,
                        style: style,
                      ),
                    ),
                    Positioned(
                      left: dx + loopDistance,
                      top: 0,
                      child: Text(
                        _displayText,
                        maxLines: 1,
                        softWrap: false,
                        style: style,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
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
