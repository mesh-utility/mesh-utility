import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mesh_utility/src/models/mesh_node.dart';
import 'package:mesh_utility/src/models/scan_result.dart';
import 'package:mesh_utility/src/services/app_debug_log_service.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/services/signal_class.dart';

class NodesPage extends StatefulWidget {
  const NodesPage({
    super.key,
    required this.nodes,
    required this.scanResults,
    required this.onOpenMapForNode,
    this.statsRadiusMiles = 0,
    this.observerLat,
    this.observerLng,
  });

  final List<MeshNode> nodes;
  final List<ScanResult> scanResults;
  final ValueChanged<String> onOpenMapForNode;
  final int statsRadiusMiles;
  final double? observerLat;
  final double? observerLng;

  @override
  State<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<NodesPage> {
  final AppDebugLogService _debugLog = AppDebugLogService.instance;
  String _query = '';
  late Map<String, ScanResult> _latestByNode;
  late Map<String, List<ScanResult>> _scansByNode;
  List<MeshNode> _sortedNodes = [];

  @override
  void initState() {
    super.initState();
    _processScans();
    _updateSortedNodes();
  }

  @override
  void didUpdateWidget(NodesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final radiusChanged =
        widget.statsRadiusMiles != oldWidget.statsRadiusMiles ||
        widget.observerLat != oldWidget.observerLat ||
        widget.observerLng != oldWidget.observerLng;
    if (widget.scanResults != oldWidget.scanResults || radiusChanged) {
      _processScans();
    }
    if (widget.nodes != oldWidget.nodes || radiusChanged) {
      _updateSortedNodes();
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _sortedNodes.where((n) {
      if (_query.isEmpty) return true;
      final q = _query.toLowerCase();
      return (n.name ?? '').toLowerCase().contains(q) ||
          n.nodeId.toLowerCase().contains(q);
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
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Mesh Nodes',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Chip(label: Text('${_sortedNodes.length} Nodes')),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Theme.of(
                          context,
                        ).dividerColor.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Click on a node to zoom and filter its coverage on the map.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search nodes',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ],
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(
                      child: Text(
                        'No nodes discovered yet. Connect and scan to populate this list.',
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 420,
                            mainAxisExtent: 154,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                          ),
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final node = filtered[index];
                        final latest = _latestByNode[node.nodeId];
                        final valueTextStyle = Theme.of(
                          context,
                        ).textTheme.bodyMedium;
                        final nodeScans = _scansByNode[node.nodeId] ?? const [];
                        final nodeHexes = nodeScans
                            .map((s) => hexKey(s.latitude, s.longitude))
                            .toSet();
                        final avgRssi = nodeScans.isEmpty
                            ? null
                            : nodeScans
                                      .map((s) => s.rssi)
                                      .reduce((a, b) => a + b) /
                                  nodeScans.length;
                        final snrValues = nodeScans
                            .map((s) => s.snr)
                            .whereType<double>()
                            .toList(growable: false);
                        final avgSnr = snrValues.isEmpty
                            ? null
                            : snrValues.reduce((a, b) => a + b) /
                                  snrValues.length;
                        final displayRssi = avgRssi ?? latest?.rssi;
                        final displaySnr = avgSnr ?? latest?.snr;
                        final signalClass =
                            displayRssi == null && displaySnr == null
                            ? null
                            : signalClassForValues(
                                rssi: displayRssi,
                                snr: displaySnr,
                                includeDeadZone: false,
                              );
                        return Card(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () {
                              _debugLog.info(
                                'ui_click',
                                'Nodes card click nodeId=${node.nodeId}',
                              );
                              widget.onOpenMapForNode(node.nodeId);
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.settings_input_antenna,
                                        size: 16,
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          node.name?.isNotEmpty == true
                                              ? node.name!
                                              : node.nodeId,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      Text(
                                        DateFormat.Hm().format(
                                          node.lastSeen.toLocal(),
                                        ),
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    node.nodeId,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.radar_outlined,
                                        size: 14,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        '${nodeScans.length}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                      const SizedBox(width: 12),
                                      const Icon(
                                        Icons.hexagon_outlined,
                                        size: 14,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        '${nodeHexes.length}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  if (displayRssi != null || displaySnr != null)
                                    SizedBox(
                                      width: double.infinity,
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        alignment: Alignment.centerLeft,
                                        child: Row(
                                          children: [
                                            if (signalClass != null)
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 2,
                                                    ),
                                                decoration: BoxDecoration(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        999,
                                                      ),
                                                  gradient:
                                                      const LinearGradient(
                                                        begin:
                                                            Alignment.topCenter,
                                                        end: Alignment
                                                            .bottomCenter,
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
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: valueTextStyle
                                                      ?.copyWith(
                                                        color:
                                                            signalClass.color,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                ),
                                              ),
                                            if (signalClass != null)
                                              const SizedBox(width: 8),
                                            Chip(
                                              materialTapTargetSize:
                                                  MaterialTapTargetSize
                                                      .shrinkWrap,
                                              visualDensity:
                                                  VisualDensity.compact,
                                              label: Text(
                                                '${displayRssi?.toStringAsFixed(0) ?? '--'} dBm',
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Chip(
                                              materialTapTargetSize:
                                                  MaterialTapTargetSize
                                                      .shrinkWrap,
                                              visualDensity:
                                                  VisualDensity.compact,
                                              label: Text(
                                                '${displaySnr?.toStringAsFixed(1) ?? '--'} SNR',
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
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

  void _processScans() {
    _latestByNode = {};
    _scansByNode = {};
    final scans = _filterScansByRadius(widget.scanResults);
    for (final scan in scans) {
      _latestByNode.putIfAbsent(scan.nodeId, () => scan);
      _scansByNode.putIfAbsent(scan.nodeId, () => <ScanResult>[]).add(scan);
    }
  }

  void _updateSortedNodes() {
    final radiusNodeIds = _scansByNode.keys.toSet();
    _sortedNodes = widget.nodes.where((n) {
      if (widget.statsRadiusMiles == 0 ||
          widget.observerLat == null ||
          widget.observerLng == null) {
        return true;
      }
      return radiusNodeIds.contains(n.nodeId);
    }).toList();
    _sortedNodes.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
  }

  List<ScanResult> _filterScansByRadius(List<ScanResult> scans) {
    if (widget.statsRadiusMiles == 0 ||
        widget.observerLat == null ||
        widget.observerLng == null) {
      return scans;
    }
    return scans.where((s) {
      final d = distanceMiles(
        widget.observerLat!,
        widget.observerLng!,
        s.latitude,
        s.longitude,
      );
      return d <= widget.statsRadiusMiles;
    }).toList();
  }
}
