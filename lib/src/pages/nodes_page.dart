import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mesh_utility/src/models/mesh_node.dart';
import 'package:mesh_utility/src/models/scan_result.dart';
import 'package:mesh_utility/src/services/app_debug_log_service.dart';
import 'package:mesh_utility/src/services/signal_class.dart';

class NodesPage extends StatefulWidget {
  const NodesPage({
    super.key,
    required this.nodes,
    required this.scanResults,
    required this.onOpenMapForNode,
  });

  final List<MeshNode> nodes;
  final List<ScanResult> scanResults;
  final ValueChanged<String> onOpenMapForNode;

  @override
  State<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<NodesPage> {
  final AppDebugLogService _debugLog = AppDebugLogService.instance;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final latestByNode = <String, ScanResult>{};
    final scansByNode = <String, List<ScanResult>>{};
    for (final scan in widget.scanResults) {
      latestByNode.putIfAbsent(scan.nodeId, () => scan);
      scansByNode.putIfAbsent(scan.nodeId, () => <ScanResult>[]).add(scan);
    }

    final filtered = widget.nodes.where((n) {
      final q = _query.toLowerCase();
      return (n.name ?? '').toLowerCase().contains(q) ||
          n.nodeId.toLowerCase().contains(q);
    }).toList()..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

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
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
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
                            mainAxisExtent: 176,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                          ),
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final node = filtered[index];
                        final latest = latestByNode[node.nodeId];
                        final valueTextStyle =
                            Theme.of(context).textTheme.bodyMedium;
                        final nodeScans = scansByNode[node.nodeId] ?? const [];
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
                                  const Spacer(),
                                  if (displayRssi != null || displaySnr != null)
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 4,
                                      children: [
                                        if (signalClass != null)
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
                                              style: valueTextStyle?.copyWith(
                                                color: signalClass.color,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                        Chip(
                                          materialTapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                          visualDensity: VisualDensity.compact,
                                          label: Text(
                                            '${displayRssi?.toStringAsFixed(0) ?? '--'} dBm',
                                          ),
                                        ),
                                        Chip(
                                          materialTapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                          visualDensity: VisualDensity.compact,
                                          label: Text(
                                            '${displaySnr?.toStringAsFixed(1) ?? '--'} SNR',
                                          ),
                                        ),
                                      ],
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
}
