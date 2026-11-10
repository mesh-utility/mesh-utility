import 'package:flutter/material.dart';
import 'package:mesh_utility/src/services/boundary_catalog.dart';
import 'package:mesh_utility/src/services/division_picker.dart';
import 'package:mesh_utility/src/services/scan_cache_area.dart';
import 'package:mesh_utility/src/services/settings_store.dart';

/// Settings controls for which downloaded scans stay on the device.
class ScanCacheAreaSection extends StatelessWidget {
  const ScanCacheAreaSection({
    super.key,
    required this.settings,
    required this.onChanged,
    this.catalog,
  });

  final AppSettings settings;
  final Future<void> Function(AppSettings value) onChanged;
  final BoundaryCatalog? catalog;

  @override
  Widget build(BuildContext context) {
    final mode = clampScanCacheMode(settings.scanCacheMode);
    final labelStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
      color: Theme.of(context).colorScheme.onSurface,
    );
    final floatingStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      fontWeight: FontWeight.w700,
      color: Theme.of(context).colorScheme.primary,
    );
    final noteStyle = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey<String>('scan-cache-mode-$mode'),
          isExpanded: true,
          initialValue: mode,
          decoration: InputDecoration(
            labelText: 'Scan cache area',
            labelStyle: labelStyle,
            floatingLabelStyle: floatingStyle,
            border: const OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(value: scanCacheModeRadius, child: Text('Radius')),
            DropdownMenuItem(
              value: scanCacheModeAdmin1,
              child: Text('States and provinces'),
            ),
            DropdownMenuItem(
              value: scanCacheModeAdmin2,
              child: Text('Counties'),
            ),
            DropdownMenuItem(value: scanCacheModeGlobal, child: Text('Global')),
          ],
          onChanged: (value) {
            if (value == null || value == mode) return;
            onChanged(settings.copyWith(scanCacheMode: value));
          },
        ),
        const SizedBox(height: 6),
        Text(scanCacheCloudNote, style: noteStyle),
        const SizedBox(height: 4),
        Text(scanCacheStorageNote, style: noteStyle),
        if (mode == scanCacheModeRadius) ...[
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            key: ValueKey<String>(
              'scan-cache-radius-${settings.scanCacheRadiusMiles}',
            ),
            isExpanded: true,
            initialValue: '${settings.scanCacheRadiusMiles}',
            decoration: InputDecoration(
              labelText: 'Area radius',
              labelStyle: labelStyle,
              floatingLabelStyle: floatingStyle,
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final miles in scanCacheRadiusMileChoices)
                DropdownMenuItem(value: '$miles', child: Text('$miles miles')),
            ],
            onChanged: (value) {
              if (value == null) return;
              final miles = int.parse(value);
              if (miles == settings.scanCacheRadiusMiles) return;
              onChanged(settings.copyWith(scanCacheRadiusMiles: miles));
            },
          ),
          const SizedBox(height: 6),
          Text(
            'Chooses the area for an optional Download coverage pack. The live map still loads tiles for the view. '
            'Choices above 250 miles also send a bounding box so a current server can return the full area. '
            'An older server still returns only 250 miles. '
            'Rows already on the device are kept out to the distance you picked. '
            'With no location yet, cloud history is not downloaded.',
            style: noteStyle,
          ),
        ],
        if (mode == scanCacheModeAdmin1 || mode == scanCacheModeAdmin2) ...[
          const SizedBox(height: 8),
          _DivisionPickerButton(
            settings: settings,
            onChanged: onChanged,
            catalog: catalog,
            counties: mode == scanCacheModeAdmin2,
          ),
          const SizedBox(height: 6),
          Text(
            mode == scanCacheModeAdmin2
                ? scanCacheCountyNote
                : 'Worldwide states, provinces, and other first-level divisions. '
                      'Outlines are simplified.',
            style: noteStyle,
          ),
          const SizedBox(height: 4),
          Text(
            'The download uses the bounding box of those outlines. This device then keeps only the outlines. An older server still caps the request at 250 miles around the center.',
            style: noteStyle,
          ),
          const SizedBox(height: 4),
          Text(
            'Expand a country to see states, and a state to see counties when that mode is on. Select all selects every division under that row. A dash means only some of them are selected.',
            style: noteStyle,
          ),
          if ((mode == scanCacheModeAdmin1
                  ? settings.scanCacheAdmin1Ids
                  : settings.scanCacheAdmin2Ids)
              .isEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'No divisions selected. Cloud history is not downloaded, and downloaded scans are removed until you select at least one.',
              style: noteStyle,
            ),
          ],
        ],
        if (mode == scanCacheModeGlobal) ...[
          const SizedBox(height: 6),
          Text(
            'Global means you can pan anywhere; the map loads true-size tiles for the view. Use Download coverage pack only if you want an offline copy of a chosen area.',
            style: noteStyle,
          ),
        ],
      ],
    );
  }
}

class _DivisionPickerButton extends StatelessWidget {
  const _DivisionPickerButton({
    required this.settings,
    required this.onChanged,
    required this.counties,
    this.catalog,
  });

  final AppSettings settings;
  final Future<void> Function(AppSettings value) onChanged;
  final bool counties;
  final BoundaryCatalog? catalog;

  @override
  Widget build(BuildContext context) {
    final ids = counties
        ? settings.scanCacheAdmin2Ids
        : settings.scanCacheAdmin1Ids;
    final label = counties
        ? 'Choose US counties (${ids.length})'
        : 'Choose states and provinces (${ids.length})';
    return OutlinedButton.icon(
      onPressed: () async {
        final selected = await showDialog<List<String>>(
          context: context,
          builder: (context) => _DivisionPickerDialog(
            title: counties ? 'US counties' : 'States and provinces',
            searchHint: counties
                ? 'Search counties or states'
                : 'Search divisions or countries',
            initialSelection: ids.toSet(),
            indexFuture: counties
                ? (catalog ?? BoundaryCatalog()).loadAdmin2Index()
                : (catalog ?? BoundaryCatalog()).loadAdmin1Index(),
          ),
        );
        if (selected == null) return;
        if (counties) {
          await onChanged(settings.copyWith(scanCacheAdmin2Ids: selected));
        } else {
          await onChanged(settings.copyWith(scanCacheAdmin1Ids: selected));
        }
      },
      icon: const Icon(Icons.map_outlined, size: 16),
      label: Text(label),
    );
  }
}

class _DivisionPickerDialog extends StatefulWidget {
  const _DivisionPickerDialog({
    required this.title,
    required this.searchHint,
    required this.initialSelection,
    required this.indexFuture,
  });

  final String title;
  final String searchHint;
  final Set<String> initialSelection;
  final Future<BoundaryIndex> indexFuture;

  @override
  State<_DivisionPickerDialog> createState() => _DivisionPickerDialogState();
}

class _VisibleDivisionRow {
  const _VisibleDivisionRow(this.node, this.depth);

  final DivisionPickerNode node;
  final int depth;
}

class _DivisionPickerDialogState extends State<_DivisionPickerDialog> {
  late final Set<String> _selected = Set<String>.of(widget.initialSelection);
  final TextEditingController _search = TextEditingController();
  BoundaryIndex? _index;
  List<DivisionPickerNode> _roots = const <DivisionPickerNode>[];
  final Set<String> _expanded = <String>{};
  Object? _error;

  @override
  void initState() {
    super.initState();
    widget.indexFuture
        .then((index) {
          if (!mounted) return;
          final roots = buildDivisionPickerTree(index);
          setState(() {
            _index = index;
            _roots = roots;
            _expanded
              ..clear()
              ..addAll(expandedKeysForPartialSelection(roots, _selected));
          });
        })
        .catchError((Object error) {
          if (!mounted) return;
          setState(() => _error = error);
        });
    _search.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final index = _index;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        height: 480,
        child: index == null
            ? Center(
                child: _error == null
                    ? const CircularProgressIndicator()
                    : const Text('Boundary list could not be loaded.'),
              )
            : Column(
                children: [
                  TextField(
                    controller: _search,
                    decoration: InputDecoration(
                      hintText: widget.searchHint,
                      prefixIcon: const Icon(Icons.search),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(child: _buildList(index)),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: index == null
              ? null
              : () => Navigator.of(context).pop(_selected.toList()..sort()),
          child: Text('Done (${_selected.length})'),
        ),
      ],
    );
  }

  Widget _buildList(BoundaryIndex index) {
    final query = _search.text.trim();
    if (query.isNotEmpty) {
      final matches = matchingDivisions(index, query);
      if (matches.isEmpty) {
        return const Center(child: Text('No matches'));
      }
      return ListView.builder(
        itemCount: matches.length,
        itemBuilder: (context, i) => _searchTile(matches[i]),
      );
    }

    final rows = _visibleRows();
    if (rows.isEmpty) {
      return const Center(child: Text('No divisions in this list.'));
    }
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, i) => _nodeRow(rows[i]),
    );
  }

  List<_VisibleDivisionRow> _visibleRows() {
    final rows = <_VisibleDivisionRow>[];
    void walk(DivisionPickerNode node, int depth) {
      rows.add(_VisibleDivisionRow(node, depth));
      if (node.isLeaf || !_expanded.contains(node.key)) return;
      for (final child in node.children) {
        walk(child, depth + 1);
      }
    }

    for (final root in _roots) {
      walk(root, 0);
    }
    return rows;
  }

  void _toggleExpanded(String key) {
    setState(() {
      if (!_expanded.add(key)) _expanded.remove(key);
    });
  }

  void _toggleNode(DivisionPickerNode node) {
    setState(() => toggleDivisionSelection(_selected, node.leafIds));
  }

  Widget _nodeRow(_VisibleDivisionRow row) {
    final node = row.node;
    final expanded = _expanded.contains(node.key);
    final state = divisionSelectionState(_selected, node.leafIds);
    final hits = selectedLeafCount(_selected, node.leafIds);
    final total = node.leafIds.length;
    final subtitle = node.isLeaf
        ? null
        : (hits == 0 ? '$total' : '$hits of $total selected');
    return Padding(
      padding: EdgeInsets.only(left: row.depth * 12.0),
      child: Row(
        children: [
          if (node.isLeaf)
            const SizedBox(width: 32)
          else
            IconButton(
              key: Key('division-expand-${node.key}'),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: expanded ? 'Collapse' : 'Expand',
              icon: Icon(
                expanded ? Icons.expand_more : Icons.chevron_right,
                size: 20,
              ),
              onPressed: () => _toggleExpanded(node.key),
            ),
          Checkbox(
            key: Key('division-check-${node.key}'),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            tristate: !node.isLeaf,
            value: node.isLeaf ? (state ?? false) : state,
            onChanged: (_) => _toggleNode(node),
          ),
          Expanded(
            child: InkWell(
              onTap: () =>
                  node.isLeaf ? _toggleNode(node) : _toggleExpanded(node.key),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      node.title,
                      key: Key('division-title-${node.key}'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (!node.isLeaf)
            TextButton(
              key: Key('division-select-all-${node.key}'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: () => _toggleNode(node),
              child: Text(state == true ? 'Clear' : 'Select all'),
            ),
        ],
      ),
    );
  }

  Widget _searchTile(BoundaryDivision division) {
    final checked = _selected.contains(division.id);
    return CheckboxListTile(
      key: Key('division-check-div:${division.id}'),
      value: checked,
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(division.name),
      subtitle: division.parentName.isNotEmpty
          ? Text(division.parentName)
          : null,
      onChanged: (_) {
        setState(
          () => toggleDivisionSelection(_selected, <String>[division.id]),
        );
      },
    );
  }
}
