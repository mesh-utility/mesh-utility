import 'dart:math';

import 'package:flutter/material.dart';
import 'package:mesh_utility/src/widgets/map_page_widgets.dart';

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
  static const double _tipSlotHeight = 18;
  static const double _iconSlotWidth = 40;
  static const double _spinnerSlotWidth = 34;
  static const double _contentPaddingX = 6;
  static const List<String> _usageTips = [
    'Tip: Tap Play To Start The Automatic Scan Loop.',
    'Tip: Tap Pause Anytime; The Current Scan Still Finishes Cleanly.',
    'Tip: Use The Bolt Icon To Trigger An Immediate Scan.',
    'Tip: Tap A Hex To View RSSI, SNR, Scans, And Last-Seen Details.',
    'Tip: Use The Top-Right Filter Button To Focus On Selected Repeaters.',
    'Tip: Auto-Center Keeps The Map On Your Current GPS Position.',
    'Tip: Dragging The Map Disables Auto-Center Until You Re-Enable It.',
    'Tip: Smart Scan Can Skip Recently Covered Zones To Reduce Network Congestion.',
    'Tip: Open Nodes To Review Discovered Repeaters And Short IDs.',
    'Tip: Use Sync To Upload Local Scans And Refresh Worker Data.',
  ];

  @override
  Widget build(BuildContext context) {
    final title = (connectionLabel ?? '').trim();
    final showTitle = title.isNotEmpty;
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
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
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
              SizedBox(
                width: rowWidth,
                height: _tipSlotHeight,
                child: bleUiEnabled
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(4, 0, 4, 2),
                        child: _TipsMarquee(
                          tips: _usageTips,
                          enabled: true,
                          pixelsPerSecond: 34,
                          gapPixels: 72,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: Colors.white70),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TipsMarquee extends StatefulWidget {
  const _TipsMarquee({
    required this.tips,
    required this.enabled,
    required this.pixelsPerSecond,
    required this.gapPixels,
    this.style,
  });

  final List<String> tips;
  final bool enabled;
  final double pixelsPerSecond;
  final double gapPixels;
  final TextStyle? style;

  @override
  State<_TipsMarquee> createState() => _TipsMarqueeState();
}

class _TipsMarqueeState extends State<_TipsMarquee> {
  static const String _tipSeparator = '        ';
  final Random _random = Random();
  String _cycleText = '';

  @override
  void initState() {
    super.initState();
    _rebuildCycleText();
  }

  @override
  void didUpdateWidget(covariant _TipsMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled ||
        oldWidget.tips.length != widget.tips.length) {
      _rebuildCycleText();
    }
  }

  void _rebuildCycleText() {
    if (!widget.enabled || widget.tips.isEmpty) {
      _cycleText = '';
      return;
    }
    final segments = <String>[];
    String? previousTail;
    const rounds = 4;
    for (var i = 0; i < rounds; i++) {
      final shuffled = List<String>.from(widget.tips);
      shuffled.shuffle(_random);
      if (previousTail != null &&
          shuffled.length > 1 &&
          shuffled.first == previousTail) {
        final swap = shuffled.first;
        shuffled[0] = shuffled[1];
        shuffled[1] = swap;
      }
      segments.addAll(shuffled);
      previousTail = shuffled.isEmpty ? previousTail : shuffled.last;
    }
    _cycleText = segments.join(_tipSeparator);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || _cycleText.isEmpty) {
      return const SizedBox.shrink();
    }
    return OverflowMarqueeText(
      text: _cycleText,
      pixelsPerSecond: widget.pixelsPerSecond,
      gapPixels: widget.gapPixels,
      style: widget.style,
    );
  }
}
