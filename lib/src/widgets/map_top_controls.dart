import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

/// How long one map tip stays on screen before the next one replaces it.
///
/// A per-frame marquee schedules a raster frame for the whole map surface.
/// This interval is a single [Timer] tick, then one instant text swap.
const Duration mapUsageTipInterval = Duration(seconds: 10);

class MapTopControls extends StatelessWidget {
  const MapTopControls({
    super.key,
    required this.autoCenter,
    required this.onToggleAutoCenter,
    required this.bleConnected,
    required this.bleBusy,
    required this.bleScanning,
    required this.bleUiEnabled,
    required this.onToggleScan,
    required this.onForceScan,
    required this.syncing,
    required this.forceOffline,
    required this.onSync,
    this.connectionLabel,
  });

  final bool autoCenter;
  final VoidCallback onToggleAutoCenter;
  final bool bleConnected;
  final bool bleBusy;
  final bool bleScanning;
  final bool bleUiEnabled;
  final VoidCallback onToggleScan;
  final VoidCallback onForceScan;
  final bool syncing;
  final bool forceOffline;
  final VoidCallback onSync;
  final String? connectionLabel;
  static const double _iconSlotWidth = 40;
  static const double _spinnerSlotWidth = 34;
  static const double _contentPaddingX = 6;
  static const List<String> _usageTips = [
    'Tip: Tap Play To Start The Automatic Scan Loop.',
    'Tip: Tap Pause Anytime; The Current Scan Still Finishes Cleanly.',
    'Tip: Use The Bolt Icon To Trigger An Immediate Scan.',
    'Tip: Tap A Hex To View RSSI, SNR, Scans, And Last-Seen Details.',
    'Tip: Use The Top-Right Filter Button To Focus On Selected Repeaters.',
    'Tip: Node Filter Focus Zooms To Matching Coverage And Pauses Auto-Center.',
    'Tip: Auto-Center Keeps The Map On Your Current GPS Position.',
    'Tip: Dragging The Map Disables Auto-Center Until You Re-Enable It.',
    'Tip: Smart Scan Can Skip Recently Covered Zones To Reduce Network Congestion.',
    'Tip: Open Nodes To Review Discovered Repeaters And Short IDs.',
    'Tip: In Scan History, tap the download icon to export filtered data to CSV.',
    'Tip: Use Sync To Upload Local Scans Manually And Refresh Cloud Data.',
  ];

  @override
  Widget build(BuildContext context) {
    final title = (connectionLabel ?? '').trim();
    final showTitle = title.isNotEmpty;
    final tipStyle = _mapUsageTipStyle(
      Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.white70),
    );
    final tipStrut = _mapUsageTipStrut(tipStyle);
    final tipHeight = _threeLineTipHeight(context, tipStyle, tipStrut);
    final canForceScan =
        bleUiEnabled && bleConnected && !bleBusy && bleScanning;
    final canToggleScan = bleUiEnabled && bleConnected;
    final iconCount = bleUiEnabled ? 4 : 2;
    final rowWidth =
        (_iconSlotWidth * (iconCount - 1)) +
        (syncing ? _spinnerSlotWidth : _iconSlotWidth);
    final cardWidth = rowWidth + (_contentPaddingX * 2);
    return Card(
      elevation: 1,
      child: SizedBox(
        width: cardWidth,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: _contentPaddingX,
            vertical: 4,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showTitle)
                SizedBox(
                  width: rowWidth,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              SizedBox(
                width: rowWidth,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: onToggleAutoCenter,
                      icon: Icon(
                        autoCenter
                            ? Icons.location_pin
                            : Icons.location_searching,
                        size: 18,
                      ),
                      tooltip: autoCenter
                          ? 'Auto-center on'
                          : 'Auto-center off',
                    ),
                    if (bleUiEnabled)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: canToggleScan ? onToggleScan : null,
                        icon: Icon(
                          bleScanning ? Icons.pause : Icons.play_arrow,
                          size: 18,
                        ),
                        tooltip: bleScanning
                            ? (bleBusy
                                  ? 'Pause loop (current scan will still finish)'
                                  : 'Pause scan loop')
                            : 'Start scan loop',
                      ),
                    if (bleUiEnabled)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: canForceScan ? onForceScan : null,
                        icon: const Icon(Icons.flash_on, size: 18),
                        tooltip: 'Force scan now',
                      ),
                    if (syncing)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: RepaintBoundary(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      )
                    else
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: forceOffline ? null : onSync,
                        icon: const Icon(Icons.sync, size: 18),
                        tooltip: forceOffline ? 'Offline mode enabled' : 'Sync',
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: SizedBox(
                  width: rowWidth,
                  height: tipHeight,
                  child: _RotatingUsageTip(
                    key: const ValueKey<String>('map-usage-tips'),
                    tips: _usageTips,
                    enabled: bleUiEnabled,
                    style: tipStyle,
                    strutStyle: tipStrut,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One point smaller than [style], never under 11.
///
/// [TextTheme.labelSmall] adds 0.5px of tracking for all-caps labels. These
/// tips are title case, and that tracking pushes the longest ones past three
/// lines inside the icon row. Clear it so the full tip fits the card's width.
TextStyle _mapUsageTipStyle(TextStyle? style) {
  final base = style ?? const TextStyle(fontSize: 12);
  final current = base.fontSize ?? 12;
  final reduced = current - 1;
  return base.copyWith(
    fontSize: reduced < 11 ? 11.0 : reduced,
    letterSpacing: 0,
  );
}

double _threeLineTipHeight(
  BuildContext context,
  TextStyle style,
  StrutStyle strut,
) {
  final painter = TextPainter(
    text: TextSpan(text: '\n\n', style: style),
    strutStyle: strut,
    maxLines: 3,
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    locale: Localizations.maybeLocaleOf(context),
  )..layout();
  final height = painter.height;
  painter.dispose();
  return height;
}

StrutStyle _mapUsageTipStrut(TextStyle style) {
  return StrutStyle(
    fontFamily: style.fontFamily,
    fontFamilyFallback: style.fontFamilyFallback,
    fontSize: style.fontSize,
    height: style.height,
    leadingDistribution: style.leadingDistribution,
    fontWeight: style.fontWeight,
    fontStyle: style.fontStyle,
    forceStrutHeight: true,
  );
}

class _RotatingUsageTip extends StatefulWidget {
  const _RotatingUsageTip({
    super.key,
    required this.tips,
    required this.enabled,
    this.style,
    this.strutStyle,
  });

  final List<String> tips;
  final bool enabled;
  final TextStyle? style;
  final StrutStyle? strutStyle;

  @override
  State<_RotatingUsageTip> createState() => _RotatingUsageTipState();
}

class _RotatingUsageTipState extends State<_RotatingUsageTip>
    with WidgetsBindingObserver {
  final Random _random = Random();
  Timer? _timer;
  List<String> _order = const [];
  int _index = 0;
  bool _active = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resetOrder();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _RotatingUsageTip oldWidget) {
    super.didUpdateWidget(oldWidget);
    final tipsChanged = !_sameTips(oldWidget.tips, widget.tips);
    if (tipsChanged) {
      _resetOrder();
    }
    if (tipsChanged || oldWidget.enabled != widget.enabled) {
      _syncTimer();
    }
  }

  @override
  void activate() {
    super.activate();
    _active = true;
    _syncTimer();
  }

  @override
  void deactivate() {
    _active = false;
    _cancelTimer();
    super.deactivate();
  }

  @override
  void dispose() {
    _active = false;
    _cancelTimer();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _syncTimer();
  }

  bool get _appInForeground {
    final state = WidgetsBinding.instance.lifecycleState;
    // Null is the binding default before the first lifecycle event.
    return state == null || state == AppLifecycleState.resumed;
  }

  bool get _shouldRotate {
    return _active &&
        mounted &&
        widget.enabled &&
        _order.length > 1 &&
        _appInForeground;
  }

  bool _sameTips(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _resetOrder() {
    _order = List<String>.from(widget.tips);
    if (_order.length > 1) {
      _order.shuffle(_random);
    }
    _index = 0;
  }

  void _syncTimer() {
    if (!_shouldRotate) {
      _cancelTimer();
      return;
    }
    _timer ??= Timer.periodic(mapUsageTipInterval, _onTick);
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _onTick(Timer timer) {
    if (!identical(timer, _timer)) return;
    if (!_shouldRotate || _order.isEmpty) {
      _cancelTimer();
      return;
    }
    setState(() {
      _index = (_index + 1) % _order.length;
    });
  }

  bool _tipTruncated(BuildContext context, String tip, double maxWidth) {
    final painter = TextPainter(
      text: TextSpan(text: tip, style: widget.style),
      strutStyle: widget.strutStyle,
      maxLines: 3,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    )..layout(maxWidth: maxWidth);
    final truncated = painter.didExceedMaxLines;
    painter.dispose();
    return truncated;
  }

  void _showFullTip(String tip) {
    if (!mounted) return;
    unawaited(
      showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            key: const ValueKey<String>('map-usage-tip-dialog'),
            scrollable: true,
            content: Text(tip),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || _order.isEmpty) {
      return const SizedBox.shrink();
    }
    final tip = _order[_index % _order.length];
    return RepaintBoundary(
      key: const ValueKey<String>('map-usage-tip'),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxWidth = constraints.maxWidth;
          final truncated =
              maxWidth.isFinite &&
              maxWidth > 0 &&
              _tipTruncated(context, tip, maxWidth);
          final line = Text(
            tip,
            softWrap: true,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
            strutStyle: widget.strutStyle,
          );
          final child = truncated
              ? GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _showFullTip(tip),
                  child: line,
                )
              : line;
          return SizedBox(
            width: maxWidth.isFinite ? maxWidth : null,
            height: constraints.hasBoundedHeight ? constraints.maxHeight : null,
            child: Align(alignment: Alignment.topLeft, child: child),
          );
        },
      ),
    );
  }
}
