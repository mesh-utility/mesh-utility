import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mesh_utility/src/models/mesh_node.dart';
import 'package:mesh_utility/src/models/scan_result.dart';
import 'package:mesh_utility/src/services/app_debug_log_service.dart';

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
    for (final scan in widget.scanResults) {
      latestByNode.putIfAbsent(scan.nodeId, () => scan);
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
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Mesh Nodes',
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'All discovered repeaters and nodes',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      Chip(label: Text('${widget.nodes.length} Nodes')),
                    ],
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
                            childAspectRatio: 2.8,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                          ),
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final node = filtered[index];
                        final latest = latestByNode[node.nodeId];
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
                                  if (latest != null)
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 4,
                                      children: [
                                        Chip(
                                          materialTapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                          visualDensity: VisualDensity.compact,
                                          label: Text(
                                            '${latest.rssi.toStringAsFixed(0)} dBm',
                                          ),
                                        ),
                                        Chip(
                                          materialTapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                          visualDensity: VisualDensity.compact,
                                          label: Text(
                                            '${latest.snr?.toStringAsFixed(1) ?? '--'} SNR',
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
