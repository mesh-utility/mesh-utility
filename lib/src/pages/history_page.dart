import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mesh_utility/src/models/scan_result.dart';
import 'package:mesh_utility/src/services/app_debug_log_service.dart';
import 'package:mesh_utility/src/services/grid.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({
    super.key,
    required this.scans,
    required this.unitSystem,
    required this.resolvedNodeNames,
    required this.onOpenMapFromHex,
    this.connectedRadioName,
    this.connectedRadioMeshId,
    this.initialHexId,
  });

  final List<ScanResult> scans;
  final String unitSystem;
  final Map<String, String> resolvedNodeNames;
  final ValueChanged<String> onOpenMapFromHex;
  final String? connectedRadioName;
  final String? connectedRadioMeshId;
  final String? initialHexId;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final AppDebugLogService _debugLog = AppDebugLogService.instance;
  String? _selectedNodeId;
  String? _selectedHexId;
  DateTimeRange? _selectedDateRange;
  int? _startHour;
  int? _endHour;

  @override
  void initState() {
    super.initState();
    _selectedHexId = widget.initialHexId;
  }

  @override
  void didUpdateWidget(covariant HistoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialHexId != oldWidget.initialHexId &&
        widget.initialHexId != null) {
      _selectedHexId = widget.initialHexId;
    }
  }

  @override
  Widget build(BuildContext context) {
    final nodes = <String, String>{};
    final observerByRadio = <String, String>{};
    for (final scan in widget.scans) {
      nodes.putIfAbsent(
        scan.nodeId,
        () => _displayNodeLabel(
          scan.senderName,
          scan.nodeId,
          widget.resolvedNodeNames[scan.nodeId],
        ),
      );
      final radio = _normalizedRadioId(scan.radioId);
      final observer = scan.receiverName?.trim();
      if (radio != null &&
          radio.isNotEmpty &&
          observer != null &&
          observer.isNotEmpty) {
        final existing = observerByRadio[radio];
        if (existing == null ||
            (_looksLikeObserverId(existing) &&
                !_looksLikeObserverId(observer))) {
          observerByRadio[radio] = observer;
        }
      }
    }

    final filtered = widget.scans.where((s) {
      if (_selectedNodeId != null && s.nodeId != _selectedNodeId) {
        return false;
      }
      final localTs = s.timestamp.toLocal();
      if (_selectedDateRange != null) {
        final start = DateTime(
          _selectedDateRange!.start.year,
          _selectedDateRange!.start.month,
          _selectedDateRange!.start.day,
        );
        final end = DateTime(
          _selectedDateRange!.end.year,
          _selectedDateRange!.end.month,
          _selectedDateRange!.end.day,
          23,
          59,
          59,
          999,
        );
        if (localTs.isBefore(start) || localTs.isAfter(end)) {
          return false;
        }
      }
      if (_startHour != null || _endHour != null) {
        final hour = localTs.hour;
        final start = _startHour ?? 0;
        final end = _endHour ?? 23;
        final inRange = start <= end
            ? (hour >= start && hour <= end)
            : (hour >= start || hour <= end);
        if (!inRange) {
          return false;
        }
      }
      if (_selectedHexId != null &&
          hexKey(s.latitude, s.longitude) != _selectedHexId) {
        return false;
      }
      return true;
    }).toList();

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1024),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 340;
                      final titleBlock = Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Scan History',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Recent recorded scans across all nodes',
                            maxLines: compact ? 2 : 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      );
                      if (compact) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            titleBlock,
                            const SizedBox(height: 8),
                            Chip(label: Text('${filtered.length} Scans')),
                          ],
                        );
                      }
                      return Row(
                        children: [
                          Expanded(child: titleBlock),
                          Chip(label: Text('${filtered.length} Scans')),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String?>(
                    isExpanded: true,
                    initialValue: _selectedNodeId,
                    decoration: const InputDecoration(
                      labelText: 'Filter by node',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('All nodes'),
                      ),
                      ...nodes.entries.map(
                        (entry) => DropdownMenuItem<String?>(
                          value: entry.key,
                          child: Text('${entry.value} (${entry.key})'),
                        ),
                      ),
                    ],
                    onChanged: (value) =>
                        setState(() => _selectedNodeId = value),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final now = DateTime.now();
                            final initialRange =
                                _selectedDateRange ??
                                DateTimeRange(
                                  start: now.subtract(const Duration(days: 7)),
                                  end: now,
                                );
                            final picked = await showDateRangePicker(
                              context: context,
                              firstDate: DateTime(2020, 1, 1),
                              lastDate: DateTime.now().add(
                                const Duration(days: 365),
                              ),
                              initialDateRange: initialRange,
                            );
                            if (picked == null) return;
                            setState(() => _selectedDateRange = picked);
                          },
                          icon: const Icon(Icons.event, size: 16),
                          label: Text(
                            _selectedDateRange == null
                                ? 'Filter by date range'
                                : '${DateFormat.yMd().format(_selectedDateRange!.start)} - ${DateFormat.yMd().format(_selectedDateRange!.end)}',
                          ),
                        ),
                      ),
                      if (_selectedDateRange != null) ...[
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'Clear date range',
                          onPressed: () =>
                              setState(() => _selectedDateRange = null),
                          icon: const Icon(Icons.clear),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<int?>(
                          isExpanded: true,
                          initialValue: _startHour,
                          decoration: const InputDecoration(
                            labelText: 'From hour',
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            const DropdownMenuItem<int?>(
                              value: null,
                              child: Text('Any'),
                            ),
                            for (var h = 0; h < 24; h++)
                              DropdownMenuItem<int?>(
                                value: h,
                                child: Text(
                                  '${h.toString().padLeft(2, '0')}:00',
                                ),
                              ),
                          ],
                          onChanged: (value) =>
                              setState(() => _startHour = value),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<int?>(
                          isExpanded: true,
                          initialValue: _endHour,
                          decoration: const InputDecoration(
                            labelText: 'To hour',
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            const DropdownMenuItem<int?>(
                              value: null,
                              child: Text('Any'),
                            ),
                            for (var h = 0; h < 24; h++)
                              DropdownMenuItem<int?>(
                                value: h,
                                child: Text(
                                  '${h.toString().padLeft(2, '0')}:00',
                                ),
                              ),
                          ],
                          onChanged: (value) =>
                              setState(() => _endHour = value),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (_selectedHexId != null)
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Map focus filter is active',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          onPressed: () =>
                              setState(() => _selectedHexId = null),
                          child: const Text('Clear'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('No scan history available yet'))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final scan = filtered[index];
                        final locationHex = hexKey(
                          scan.latitude,
                          scan.longitude,
                        );
                        final signalClass = _signalClassForScan(scan);
                        return Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () {
                              _debugLog.info(
                                'ui_click',
                                'History card click hex=$locationHex nodeId=${scan.nodeId}',
                              );
                              widget.onOpenMapFromHex(locationHex);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final metricWidth = constraints.maxWidth < 280
                                      ? 66.0
                                      : 74.0;
                                  final bodySmall = Theme.of(
                                    context,
                                  ).textTheme.bodySmall;
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        DateFormat.yMd().add_jm().format(
                                          scan.timestamp.toLocal(),
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          const Icon(Icons.radio, size: 14),
                                          const SizedBox(width: 4),
                                          Expanded(
                                            child: Text(
                                              _observerName(
                                                scan,
                                                observerByRadio,
                                                resolvedNodeNames:
                                                    widget.resolvedNodeNames,
                                                connectedRadioName:
                                                    widget.connectedRadioName,
                                                connectedRadioMeshId:
                                                    widget.connectedRadioMeshId,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          SizedBox(
                                            width: metricWidth,
                                            child: Align(
                                              alignment: Alignment.centerRight,
                                              child: FittedBox(
                                                fit: BoxFit.scaleDown,
                                                alignment:
                                                    Alignment.centerRight,
                                                child: Text(
                                                  'SNR ${scan.snrIn?.toStringAsFixed(1) ?? 'N/A'} dB',
                                                  textAlign: TextAlign.right,
                                                  maxLines: 1,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const Divider(height: 8, thickness: 0.6),
                                      Row(
                                        children: [
                                          const Icon(
                                            Icons.settings_input_antenna,
                                            size: 14,
                                          ),
                                          const SizedBox(width: 4),
                                          Expanded(
                                            child: Text(
                                              _displayNodeLabel(
                                                scan.senderName,
                                                scan.nodeId,
                                                widget.resolvedNodeNames[scan
                                                    .nodeId],
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          SizedBox(
                                            width: metricWidth,
                                            child: Align(
                                              alignment: Alignment.centerRight,
                                              child: FittedBox(
                                                fit: BoxFit.scaleDown,
                                                alignment:
                                                    Alignment.centerRight,
                                                child: Text(
                                                  'SNR ${scan.snr?.toStringAsFixed(1) ?? 'N/A'} dB',
                                                  textAlign: TextAlign.right,
                                                  maxLines: 1,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Row(
                                        children: [
                                          const Icon(Icons.schedule, size: 14),
                                          const SizedBox(width: 4),
                                          Expanded(
                                            child: Text(
                                              'Scanned ${DateFormat.yMd().add_jm().format(scan.timestamp.toLocal())}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(
                                                context,
                                              ).textTheme.bodySmall,
                                            ),
                                          ),
                                        ],
                                      ),
                                      Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                              gradient: const LinearGradient(
                                                begin: Alignment.topCenter,
                                                end: Alignment.bottomCenter,
                                                colors: [
                                                  Color(0xFF1B2329),
                                                  Color(0xFF0A0E12),
                                                ],
                                              ),
                                              border: Border.all(
                                                color: Colors.white24,
                                                width: 0.6,
                                              ),
                                              boxShadow: const [
                                                BoxShadow(
                                                  color: Colors.black54,
                                                  blurRadius: 5,
                                                  offset: Offset(0, 1),
                                                ),
                                              ],
                                            ),
                                            child: Text(
                                              signalClass.label,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: bodySmall?.copyWith(
                                                color: signalClass.color,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                          const Spacer(),
                                          SizedBox(
                                            width: metricWidth,
                                            child: Align(
                                              alignment: Alignment.centerRight,
                                              child: FittedBox(
                                                fit: BoxFit.scaleDown,
                                                alignment:
                                                    Alignment.centerRight,
                                                child: Text(
                                                  'RSSI ${scan.rssi.toStringAsFixed(1)} dBm',
                                                  textAlign: TextAlign.right,
                                                  maxLines: 1,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const Divider(height: 8, thickness: 0.6),
                                      Row(
                                        children: [
                                          const Icon(Icons.terrain, size: 14),
                                          const SizedBox(width: 4),
                                          Expanded(
                                            child: Text(
                                              _formatAltitude(
                                                scan.altitude,
                                                widget.unitSystem,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const Divider(height: 8, thickness: 0.6),
                                      Row(
                                        children: [
                                          const Icon(
                                            Icons.location_on,
                                            size: 14,
                                          ),
                                          const SizedBox(width: 4),
                                          Expanded(
                                            child: Text(
                                              locationHex,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

String _displayNodeLabel(
  String? senderName,
  String nodeId,
  String? resolvedName,
) {
  if (senderName == null || senderName.trim().isEmpty) {
    if (resolvedName != null && resolvedName.trim().isNotEmpty) {
      return resolvedName.trim();
    }
    return nodeId;
  }
  final trimmed = senderName.trim();
  if (trimmed == nodeId &&
      resolvedName != null &&
      resolvedName.trim().isNotEmpty) {
    return resolvedName.trim();
  }
  if (trimmed.toLowerCase() == 'unknown' &&
      resolvedName != null &&
      resolvedName.trim().isNotEmpty) {
    return resolvedName.trim();
  }
  if (trimmed == 'Unknown ($nodeId)') {
    if (resolvedName != null && resolvedName.trim().isNotEmpty) {
      return resolvedName.trim();
    }
    return nodeId;
  }
  if (trimmed.startsWith('Unknown (') && trimmed.endsWith(')')) {
    if (resolvedName != null && resolvedName.trim().isNotEmpty) {
      return resolvedName.trim();
    }
    return nodeId;
  }
  return trimmed;
}

String _observerName(
  ScanResult scan,
  Map<String, String> observerByRadio, {
  Map<String, String> resolvedNodeNames = const {},
  String? connectedRadioName,
  String? connectedRadioMeshId,
}) {
  final preferredName = connectedRadioName?.trim();
  final preferredMesh = _normalizedRadioId(connectedRadioMeshId);
  if (preferredName != null && preferredName.isNotEmpty) {
    final radioNorm = (scan.radioId ?? '').trim();
    final matchesPreferred =
        preferredMesh != null &&
        preferredMesh.isNotEmpty &&
        _idsLikelySameDevice(radioNorm, preferredMesh);
    if (matchesPreferred) {
      return preferredName;
    }
  }
  final observerName = scan.receiverName?.trim();
  if (observerName != null && observerName.isNotEmpty) {
    if (_looksLikeObserverId(observerName)) {
      final resolved = _bestResolvedNameForNode(
        nodeId: observerName,
        resolvedNodeNames: resolvedNodeNames,
      );
      if (resolved != null && resolved.isNotEmpty) {
        return resolved;
      }
    }
    final radio = _normalizedRadioId(scan.radioId);
    if (_looksLikeObserverId(observerName) &&
        radio != null &&
        radio.isNotEmpty) {
      final mapped = observerByRadio[radio];
      if (mapped != null &&
          mapped.isNotEmpty &&
          !_looksLikeObserverId(mapped)) {
        return mapped;
      }
    }
    return _formatObserverDisplay(observerName);
  }
  final radio = _normalizedRadioId(scan.radioId);
  if (radio != null && radio.isNotEmpty) {
    final resolved = _bestResolvedNameForNode(
      nodeId: radio,
      resolvedNodeNames: resolvedNodeNames,
    );
    if (resolved != null && resolved.isNotEmpty) {
      return resolved;
    }
    final mapped = observerByRadio[radio];
    if (mapped != null && mapped.isNotEmpty) {
      return _formatObserverDisplay(mapped);
    }
    return _formatObserverDisplay(radio);
  }
  final observerRaw = scan.observerId.trim();
  if (observerRaw.isNotEmpty) {
    final resolved = _bestResolvedNameForNode(
      nodeId: observerRaw,
      resolvedNodeNames: resolvedNodeNames,
    );
    if (resolved != null && resolved.isNotEmpty) {
      return resolved;
    }
  }
  return 'unknown';
}

String? _bestResolvedNameForNode({
  required String nodeId,
  required Map<String, String> resolvedNodeNames,
}) {
  final exact = (resolvedNodeNames[nodeId] ?? '').trim();
  if (exact.isNotEmpty) return exact;
  final target = _normalizeHexId(nodeId);
  if (target.isEmpty) return null;
  for (final entry in resolvedNodeNames.entries) {
    final key = _normalizeHexId(entry.key);
    if (key.isEmpty) continue;
    if (key == target || key.startsWith(target) || target.startsWith(key)) {
      final name = entry.value.trim();
      if (name.isNotEmpty) return name;
    }
  }
  return null;
}

String? _normalizedRadioId(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final hex = _normalizeHexId(trimmed);
  if (hex.length >= 8) return hex.substring(0, 8);
  return trimmed.toUpperCase();
}

bool _idsLikelySameDevice(String a, String b) {
  final an = _normalizeHexId(a);
  final bn = _normalizeHexId(b);
  if (an.isEmpty || bn.isEmpty) return false;
  if (an == bn) return true;
  if (an.length >= 8 && bn.length >= 8) {
    if (an.substring(0, 8) == bn.substring(0, 8)) return true;
  }
  return an.startsWith(bn) || bn.startsWith(an);
}

String _normalizeHexId(String value) {
  return value.trim().toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');
}

String _formatObserverDisplay(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return trimmed;
  final hex = _normalizeHexId(trimmed);
  if (hex.length >= 8) {
    final looksLikeId =
        trimmed.contains(':') ||
        RegExp(r'^[0-9A-F]{8,}$').hasMatch(trimmed.toUpperCase()) ||
        hex.length == trimmed.length;
    if (looksLikeId) return hex.substring(0, 8);
  }
  return trimmed;
}

bool _looksLikeObserverId(String value) {
  final normalized = value.trim().toUpperCase();
  if (normalized.isEmpty) return false;
  if (normalized.contains(':')) return true;
  final hexOnly = normalized.replaceAll(RegExp(r'[^0-9A-F]'), '');
  return hexOnly.length == 8 || hexOnly.length == 12 || hexOnly.length == 16;
}

String _formatAltitude(double? altitudeMeters, String unitSystem) {
  if (altitudeMeters == null || !altitudeMeters.isFinite) {
    return '--';
  }
  if (unitSystem == 'metric') {
    return '${altitudeMeters.toStringAsFixed(0)} m';
  }
  final feet = altitudeMeters * 3.28084;
  return '${feet.toStringAsFixed(0)} ft';
}

class _SignalLegendClass {
  const _SignalLegendClass(this.label, this.color);

  final String label;
  final Color color;
}

_SignalLegendClass _signalClassForScan(ScanResult scan) {
  final rssi = scan.rssi;
  final snr = scan.snr;

  int rssiLevel() {
    if (rssi > -90) return 5;
    if (rssi > -100) return 4;
    if (rssi > -110) return 3;
    if (rssi > -115) return 2;
    if (rssi > -120) return 1;
    return 0;
  }

  int snrLevel() {
    if (snr == null) return 3;
    if (snr > 10) return 5;
    if (snr > 0) return 4;
    if (snr > -7) return 3;
    if (snr > -13) return 2;
    return 0;
  }

  final level = rssiLevel() < snrLevel() ? rssiLevel() : snrLevel();
  switch (level) {
    case 5:
      return const _SignalLegendClass('Excellent', Color(0xFF22C55E));
    case 4:
      return const _SignalLegendClass('Good', Color(0xFF4ADE80));
    case 3:
      return const _SignalLegendClass('Fair', Color(0xFFFACC15));
    case 2:
      return const _SignalLegendClass('Marginal', Color(0xFFF97316));
    case 1:
      return const _SignalLegendClass('Poor', Color(0xFFEF4444));
    default:
      return const _SignalLegendClass('Dead Zone', Color(0xFF991B1B));
  }
}
