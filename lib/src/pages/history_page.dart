import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:mesh_utility/src/models/scan_result.dart';
import 'package:mesh_utility/src/services/app_debug_log_service.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/services/history_csv_exporter.dart'
    as csv_export;
import 'package:mesh_utility/src/services/signal_class.dart';

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
    this.statsRadiusMiles = 0,
    this.observerLat,
    this.observerLng,
  });

  final List<ScanResult> scans;
  final String unitSystem;
  final Map<String, String> resolvedNodeNames;
  final ValueChanged<String> onOpenMapFromHex;
  final String? connectedRadioName;
  final String? connectedRadioMeshId;
  final String? initialHexId;
  final int statsRadiusMiles;
  final double? observerLat;
  final double? observerLng;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final AppDebugLogService _debugLog = AppDebugLogService.instance;
  Set<String> _selectedNodeIds = <String>{};
  String? _selectedHexId;
  DateTimeRange? _selectedDateRange;
  int? _startHour;
  int? _endHour;
  bool _filtersExpanded = false;
  late Map<String, String> _nodeLabels;
  late Map<String, String> _observerByRadio;
  List<ScanResult> _filteredScans = [];
  bool _filteringInProgress = false;
  bool _exportingCsv = false;

  @override
  void initState() {
    super.initState();
    _selectedHexId = widget.initialHexId;
    _processScans();
    _updateFilteredList();
  }

  @override
  void didUpdateWidget(covariant HistoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    bool shouldRefilter = false;
    if (widget.initialHexId != oldWidget.initialHexId &&
        widget.initialHexId != null) {
      _selectedHexId = widget.initialHexId;
      shouldRefilter = true;
    }
    final radiusChanged =
        widget.statsRadiusMiles != oldWidget.statsRadiusMiles ||
        widget.observerLat != oldWidget.observerLat ||
        widget.observerLng != oldWidget.observerLng;
    if (widget.scans != oldWidget.scans ||
        widget.resolvedNodeNames != oldWidget.resolvedNodeNames ||
        radiusChanged) {
      _processScans();
    }
    if (widget.scans != oldWidget.scans || shouldRefilter || radiusChanged) {
      _updateFilteredList();
    }
  }

  List<ScanResult> get _radiusFilteredScans {
    if (widget.statsRadiusMiles == 0 ||
        widget.observerLat == null ||
        widget.observerLng == null) {
      return widget.scans;
    }
    return widget.scans.where((s) {
      final d = distanceMiles(
        widget.observerLat!,
        widget.observerLng!,
        s.latitude,
        s.longitude,
      );
      return d <= widget.statsRadiusMiles;
    }).toList();
  }

  void _processScans() {
    _nodeLabels = {};
    _observerByRadio = {};
    for (final scan in _radiusFilteredScans) {
      _nodeLabels.putIfAbsent(
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
        final existing = _observerByRadio[radio];
        if (existing == null ||
            (_looksLikeObserverId(existing) &&
                !_looksLikeObserverId(observer))) {
          _observerByRadio[radio] = observer;
        }
      }
    }
  }

  void _updateFilteredList() async {
    if (_filteringInProgress) return;
    setState(() => _filteringInProgress = true);

    final filtered = await compute(_filterScansIsolate, {
      'scans': _radiusFilteredScans,
      'selectedNodeIds': _selectedNodeIds.toList(growable: false),
      'selectedDateRange': _selectedDateRange,
      'startHour': _startHour,
      'endHour': _endHour,
      'selectedHexId': _selectedHexId,
    });

    if (!mounted) return;
    setState(() {
      _filteredScans = filtered;
      _filteringInProgress = false;
    });
  }

  String _selectedNodeSummary() {
    final count = _selectedNodeIds.length;
    if (count == 0) return 'All nodes';
    if (count == 1) {
      final only = _selectedNodeIds.first;
      return _nodeLabels[only] ?? only;
    }
    return '$count nodes selected';
  }

  Future<void> _openNodeFilterDialog() async {
    final options =
        _nodeLabels.entries
            .map((entry) => _HistoryNodeFilterOption(entry.key, entry.value))
            .toList(growable: false)
          ..sort(
            (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
          );
    if (!mounted) return;
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (context) => _HistoryNodeFilterDialog(
        options: options,
        initiallySelected: _selectedNodeIds,
      ),
    );
    if (!mounted || result == null) return;
    final before = _selectedNodeIds.toList()..sort();
    final after = result.toList()..sort();
    if (before.join(',') == after.join(',')) return;
    setState(() => _selectedNodeIds = result);
    _updateFilteredList();
  }

  Future<void> _exportFilteredCsv() async {
    if (_filteredScans.isEmpty || _exportingCsv) return;
    setState(() => _exportingCsv = true);
    final count = _filteredScans.length;
    _debugLog.info(
      'history_export',
      'Starting filtered CSV export rows=$count',
    );
    try {
      final rows = <List<String>>[
        <String>[
          'timestamp_utc',
          'timestamp_local',
          'node_id',
          'node_label',
          'observer_name',
          'radio_id',
          'rssi_dbm',
          'snr_db',
          'snr_in_db',
          'latitude',
          'longitude',
          'hex_id',
          'altitude_m',
          'signal_class',
        ],
      ];
      for (final scan in _filteredScans) {
        final nodeLabel = _displayNodeLabel(
          scan.senderName,
          scan.nodeId,
          widget.resolvedNodeNames[scan.nodeId],
        );
        final observerName = _observerName(
          scan,
          _observerByRadio,
          resolvedNodeNames: widget.resolvedNodeNames,
          connectedRadioName: widget.connectedRadioName,
          connectedRadioMeshId: widget.connectedRadioMeshId,
        );
        rows.add(<String>[
          scan.timestamp.toUtc().toIso8601String(),
          DateFormat('yyyy-MM-dd HH:mm:ss').format(scan.timestamp.toLocal()),
          scan.nodeId,
          nodeLabel,
          observerName,
          scan.radioId ?? '',
          scan.rssi.toStringAsFixed(1),
          scan.snr?.toStringAsFixed(1) ?? '',
          scan.snrIn?.toStringAsFixed(1) ?? '',
          scan.latitude.toStringAsFixed(7),
          scan.longitude.toStringAsFixed(7),
          hexKey(scan.latitude, scan.longitude),
          scan.altitude?.toStringAsFixed(1) ?? '',
          signalClassForValues(rssi: scan.rssi, snr: scan.snr).label,
        ]);
      }
      final csv = rows.map(_csvRow).join('\n');
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final fileName = 'mesh_utility_history_$stamp.csv';
      final savedTo = await csv_export.exportCsvFile(
        fileName: fileName,
        csvContent: csv,
      );
      _debugLog.info(
        'history_export',
        'CSV export completed rows=$count target=$savedTo',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('CSV exported: $savedTo')));
    } catch (e) {
      _debugLog.error('history_export', 'CSV export failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('CSV export failed: $e')));
    } finally {
      if (mounted) {
        setState(() => _exportingCsv = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'All Scans',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                      IconButton(
                        tooltip: _filtersExpanded
                            ? 'Collapse filters'
                            : 'Expand filters',
                        onPressed: () => setState(
                          () => _filtersExpanded = !_filtersExpanded,
                        ),
                        icon: Icon(
                          _filtersExpanded
                              ? Icons.filter_alt
                              : Icons.filter_alt_outlined,
                        ),
                      ),
                      if (_filtersExpanded)
                        IconButton(
                          tooltip: 'Export filtered CSV',
                          onPressed:
                              (_filteringInProgress ||
                                  _exportingCsv ||
                                  _filteredScans.isEmpty)
                              ? null
                              : _exportFilteredCsv,
                          icon: _exportingCsv
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.0,
                                  ),
                                )
                              : const Icon(Icons.download_outlined),
                        ),
                      Chip(
                        label: Text(
                          '${_filteredScans.length} scans',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                    ],
                  ),
                  AnimatedCrossFade(
                    firstChild: const SizedBox.shrink(),
                    secondChild: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _openNodeFilterDialog,
                                icon: const Icon(Icons.filter_list, size: 16),
                                label: Text(
                                  'Filter nodes: ${_selectedNodeSummary()}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            if (_selectedNodeIds.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              IconButton(
                                tooltip: 'Clear node filter',
                                onPressed: () => setState(() {
                                  _selectedNodeIds = <String>{};
                                  _updateFilteredList();
                                }),
                                icon: const Icon(Icons.clear),
                              ),
                            ],
                          ],
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
                                        start: now.subtract(
                                          const Duration(days: 7),
                                        ),
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
                                  setState(() {
                                    _selectedDateRange = picked;
                                    _updateFilteredList();
                                  });
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
                                onPressed: () => setState(() {
                                  _selectedDateRange = null;
                                  _updateFilteredList();
                                }),
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
                                onChanged: (value) => setState(() {
                                  _startHour = value;
                                  _updateFilteredList();
                                }),
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
                                onChanged: (value) => setState(() {
                                  _endHour = value;
                                  _updateFilteredList();
                                }),
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
                                onPressed: () => setState(() {
                                  _selectedHexId = null;
                                  _updateFilteredList();
                                }),
                                child: const Text('Clear'),
                              ),
                            ],
                          ),
                      ],
                    ),
                    crossFadeState: _filtersExpanded
                        ? CrossFadeState.showSecond
                        : CrossFadeState.showFirst,
                    duration: const Duration(milliseconds: 180),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _filteringInProgress
                  ? const Center(child: CircularProgressIndicator())
                  : _filteredScans.isEmpty
                  ? const Center(child: Text('No scan history available yet'))
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        // List padding (16*2) + Card content padding (12*2) = 56.
                        final availableWidth = constraints.maxWidth - 56;
                        final metricWidth = availableWidth < 280 ? 66.0 : 74.0;

                        return ListView.builder(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          itemCount: _filteredScans.length,
                          itemBuilder: (context, index) {
                            final scan = _filteredScans[index];
                            final locationHex = hexKey(
                              scan.latitude,
                              scan.longitude,
                            );
                            return _HistoryScanItem(
                              scan: scan,
                              unitSystem: widget.unitSystem,
                              metricWidth: metricWidth,
                              locationHex: locationHex,
                              observerName: _observerName(
                                scan,
                                _observerByRadio,
                                resolvedNodeNames: widget.resolvedNodeNames,
                                connectedRadioName: widget.connectedRadioName,
                                connectedRadioMeshId:
                                    widget.connectedRadioMeshId,
                              ),
                              nodeLabel: _displayNodeLabel(
                                scan.senderName,
                                scan.nodeId,
                                widget.resolvedNodeNames[scan.nodeId],
                              ),
                              onTap: () {
                                _debugLog.info(
                                  'ui_click',
                                  'History card click hex=$locationHex nodeId=${scan.nodeId}',
                                );
                                widget.onOpenMapFromHex(locationHex);
                              },
                            );
                          },
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

List<ScanResult> _filterScansIsolate(Map<String, dynamic> params) {
  final List<ScanResult> scans = params['scans'];
  final List<String> selectedNodeIds =
      ((params['selectedNodeIds'] as List?) ?? const <dynamic>[])
          .cast<String>();
  final DateTimeRange? selectedDateRange = params['selectedDateRange'];
  final int? startHour = params['startHour'];
  final int? endHour = params['endHour'];
  final String? selectedHexId = params['selectedHexId'];
  final selectedNodeIdSet = selectedNodeIds.toSet();

  return scans.where((s) {
    if (selectedNodeIdSet.isNotEmpty && !selectedNodeIdSet.contains(s.nodeId)) {
      return false;
    }
    final localTs = s.timestamp.toLocal();
    if (selectedDateRange != null) {
      final start = DateTime(
        selectedDateRange.start.year,
        selectedDateRange.start.month,
        selectedDateRange.start.day,
      );
      final end = DateTime(
        selectedDateRange.end.year,
        selectedDateRange.end.month,
        selectedDateRange.end.day,
        23,
        59,
        59,
        999,
      );
      if (localTs.isBefore(start) || localTs.isAfter(end)) {
        return false;
      }
    }
    if (startHour != null || endHour != null) {
      final hour = localTs.hour;
      final start = startHour ?? 0;
      final end = endHour ?? 23;
      final inRange = start <= end
          ? (hour >= start && hour <= end)
          : (hour >= start || hour <= end);
      if (!inRange) {
        return false;
      }
    }
    if (selectedHexId != null &&
        hexKey(s.latitude, s.longitude) != selectedHexId) {
      return false;
    }
    return true;
  }).toList();
}

String _csvRow(List<String> cells) {
  return cells.map(_csvCell).join(',');
}

String _csvCell(String value) {
  final needsQuotes =
      value.contains(',') || value.contains('"') || value.contains('\n');
  if (!needsQuotes) return value;
  final escaped = value.replaceAll('"', '""');
  return '"$escaped"';
}

class _HistoryNodeFilterOption {
  const _HistoryNodeFilterOption(this.nodeId, this.label);

  final String nodeId;
  final String label;
}

class _HistoryNodeFilterDialog extends StatefulWidget {
  const _HistoryNodeFilterDialog({
    required this.options,
    required this.initiallySelected,
  });

  final List<_HistoryNodeFilterOption> options;
  final Set<String> initiallySelected;

  @override
  State<_HistoryNodeFilterDialog> createState() =>
      _HistoryNodeFilterDialogState();
}

class _HistoryNodeFilterDialogState extends State<_HistoryNodeFilterDialog> {
  late final TextEditingController _searchController;
  late final Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _selected = Set<String>.from(widget.initiallySelected);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text.trim().toLowerCase();
    final filtered = widget.options
        .where((option) {
          if (query.isEmpty) return true;
          return option.label.toLowerCase().contains(query) ||
              option.nodeId.toLowerCase().contains(query);
        })
        .toList(growable: false);

    return AlertDialog(
      title: const Text('Filter Nodes'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search),
                hintText: 'Search node name or ID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(
                  onPressed: () => setState(() => _selected.clear()),
                  child: const Text('Clear'),
                ),
                TextButton(
                  onPressed: filtered.isEmpty
                      ? null
                      : () => setState(() {
                          _selected.addAll(filtered.map((e) => e.nodeId));
                        }),
                  child: const Text('Select all shown'),
                ),
                Text('${_selected.length} selected'),
              ],
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 320,
              child: ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final option = filtered[index];
                  final checked = _selected.contains(option.nodeId);
                  return CheckboxListTile(
                    value: checked,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(
                      option.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(option.nodeId),
                    onChanged: (value) {
                      setState(() {
                        if (value == true) {
                          _selected.add(option.nodeId);
                        } else {
                          _selected.remove(option.nodeId);
                        }
                      });
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

class _HistoryScanItem extends StatelessWidget {
  const _HistoryScanItem({
    required this.scan,
    required this.unitSystem,
    required this.metricWidth,
    required this.observerName,
    required this.nodeLabel,
    required this.onTap,
    required this.locationHex,
  });

  final ScanResult scan;
  final String unitSystem;
  final double metricWidth;
  final String observerName;
  final String nodeLabel;
  final VoidCallback onTap;
  final String locationHex;

  @override
  Widget build(BuildContext context) {
    final signalClass = signalClassForValues(rssi: scan.rssi, snr: scan.snr);
    final bodySmall = Theme.of(context).textTheme.bodySmall;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                DateFormat.yMd().add_jm().format(scan.timestamp.toLocal()),
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
                      observerName,
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
                        alignment: Alignment.centerRight,
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
                  const Icon(Icons.settings_input_antenna, size: 14),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      nodeLabel,
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
                        alignment: Alignment.centerRight,
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
                      style: bodySmall,
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
                      borderRadius: BorderRadius.circular(999),
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFF1B2329), Color(0xFF0A0E12)],
                      ),
                      border: Border.all(color: Colors.white24, width: 0.6),
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
                        alignment: Alignment.centerRight,
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
                      _formatAltitude(scan.altitude, unitSystem),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const Divider(height: 8, thickness: 0.6),
              Row(
                children: [
                  const Icon(Icons.location_on, size: 14),
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
          ),
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
  String baseLabel;
  if (senderName == null || senderName.trim().isEmpty) {
    if (resolvedName != null && resolvedName.trim().isNotEmpty) {
      baseLabel = resolvedName.trim();
    } else {
      baseLabel = nodeId;
    }
    return _formatNodeDisplayWithId(baseLabel, nodeId);
  }
  final trimmed = senderName.trim();
  if (trimmed == nodeId &&
      resolvedName != null &&
      resolvedName.trim().isNotEmpty) {
    baseLabel = resolvedName.trim();
    return _formatNodeDisplayWithId(baseLabel, nodeId);
  }
  if (trimmed.toLowerCase() == 'unknown' &&
      resolvedName != null &&
      resolvedName.trim().isNotEmpty) {
    baseLabel = resolvedName.trim();
    return _formatNodeDisplayWithId(baseLabel, nodeId);
  }
  if (trimmed == 'Unknown ($nodeId)') {
    if (resolvedName != null && resolvedName.trim().isNotEmpty) {
      baseLabel = resolvedName.trim();
      return _formatNodeDisplayWithId(baseLabel, nodeId);
    }
    baseLabel = nodeId;
    return _formatNodeDisplayWithId(baseLabel, nodeId);
  }
  if (trimmed.startsWith('Unknown (') && trimmed.endsWith(')')) {
    if (resolvedName != null && resolvedName.trim().isNotEmpty) {
      baseLabel = resolvedName.trim();
      return _formatNodeDisplayWithId(baseLabel, nodeId);
    }
    baseLabel = nodeId;
    return _formatNodeDisplayWithId(baseLabel, nodeId);
  }
  baseLabel = trimmed;
  return _formatNodeDisplayWithId(baseLabel, nodeId);
}

String _formatNodeDisplayWithId(String label, String nodeId) {
  final trimmedLabel = label.trim();
  final shortId = _normalizedRadioId(nodeId) ?? _normalizeHexId(nodeId);
  if (shortId.isEmpty) return trimmedLabel;
  if (trimmedLabel.isEmpty) return shortId;
  final alreadyTagged = RegExp(
    '\\(${RegExp.escape(shortId)}\\)\$',
    caseSensitive: false,
  ).hasMatch(trimmedLabel);
  if (alreadyTagged) return trimmedLabel;
  final labelShortId = _normalizedRadioId(trimmedLabel);
  if (_looksLikeObserverId(trimmedLabel) &&
      labelShortId != null &&
      labelShortId == shortId) {
    return shortId;
  }
  return '$trimmedLabel ($shortId)';
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
