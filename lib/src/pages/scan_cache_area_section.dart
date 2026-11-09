import 'package:flutter/material.dart';
import 'package:mesh_utility/src/services/boundary_catalog.dart';
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
            'Downloads and keeps scans within this distance of your last known location. '
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
          Text('Downloads and keeps scans from everywhere.', style: noteStyle),
        ],
        const SizedBox(height: 8),
        _TravelDownloadControls(
          settings: settings,
          mode: mode,
          onChanged: onChanged,
          labelStyle: labelStyle,
          floatingStyle: floatingStyle,
          noteStyle: noteStyle,
        ),
      ],
    );
  }
}

class _TravelDownloadControls extends StatelessWidget {
  const _TravelDownloadControls({
    required this.settings,
    required this.mode,
    required this.onChanged,
    required this.labelStyle,
    required this.floatingStyle,
    required this.noteStyle,
  });

  final AppSettings settings;
  final String mode;
  final Future<void> Function(AppSettings value) onChanged;
  final TextStyle? labelStyle;
  final TextStyle? floatingStyle;
  final TextStyle? noteStyle;

  @override
  Widget build(BuildContext context) {
    final global = mode == scanCacheModeGlobal;
    if (global) {
      return Text(
        'Global already covers every place, so travel download stays off.',
        style: noteStyle,
      );
    }
    final enabled = settings.travelDownloadEnabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Download where I travel'),
          value: enabled,
          onChanged: (value) {
            onChanged(settings.copyWith(travelDownloadEnabled: value));
          },
        ),
        Text(travelDownloadNote, style: noteStyle),
        if (enabled) ...[
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            key: ValueKey<String>(
              'travel-radius-${settings.travelRadiusMiles}',
            ),
            isExpanded: true,
            initialValue: '${settings.travelRadiusMiles}',
            decoration: InputDecoration(
              labelText: 'Travel radius',
              labelStyle: labelStyle,
              floatingLabelStyle: floatingStyle,
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final miles in travelRadiusMileChoices)
                DropdownMenuItem(value: '$miles', child: Text('$miles miles')),
            ],
            onChanged: (value) {
              if (value == null) return;
              final miles = int.parse(value);
              if (miles == settings.travelRadiusMiles) return;
              onChanged(settings.copyWith(travelRadiusMiles: miles));
            },
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

class _DivisionPickerDialogState extends State<_DivisionPickerDialog> {
  late final Set<String> _selected = Set<String>.of(widget.initialSelection);
  final TextEditingController _search = TextEditingController();
  BoundaryIndex? _index;
  Object? _error;
  String? _countryCode;

  @override
  void initState() {
    super.initState();
    widget.indexFuture
        .then((index) {
          if (!mounted) return;
          setState(() => _index = index);
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
    final query = _search.text.trim().toLowerCase();
    if (query.isNotEmpty) {
      final matches = <BoundaryDivision>[];
      for (final division in index.divisions) {
        if (division.name.toLowerCase().contains(query) ||
            division.parentName.toLowerCase().contains(query) ||
            division.id.toLowerCase().contains(query)) {
          matches.add(division);
        }
      }
      return ListView.builder(
        itemCount: matches.length,
        itemBuilder: (context, i) =>
            _divisionTile(matches[i], showParent: true),
      );
    }

    if (_countryCode == null) {
      final counts = <String, int>{};
      final selectedCounts = <String, int>{};
      for (final division in index.divisions) {
        counts[division.countryCode] = (counts[division.countryCode] ?? 0) + 1;
        if (_selected.contains(division.id)) {
          selectedCounts[division.countryCode] =
              (selectedCounts[division.countryCode] ?? 0) + 1;
        }
      }
      final countries = index.countries
          .where((country) => (counts[country.code] ?? 0) > 0)
          .toList(growable: false);
      return ListView.builder(
        itemCount: countries.length,
        itemBuilder: (context, i) {
          final country = countries[i];
          final chosen = selectedCounts[country.code] ?? 0;
          final total = counts[country.code] ?? 0;
          return ListTile(
            title: Text(country.name),
            subtitle: Text(
              chosen == 0 ? '$total' : '$chosen of $total selected',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => setState(() => _countryCode = country.code),
          );
        },
      );
    }

    final divisions = <BoundaryDivision>[
      for (final division in index.divisions)
        if (division.countryCode == _countryCode) division,
    ];
    final countryName = divisions.isEmpty
        ? _countryCode!
        : divisions.first.parentName;
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _countryCode = null),
            icon: const Icon(Icons.arrow_back, size: 16),
            label: Text(countryName),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: divisions.length,
            itemBuilder: (context, i) => _divisionTile(divisions[i]),
          ),
        ),
      ],
    );
  }

  Widget _divisionTile(BoundaryDivision division, {bool showParent = false}) {
    final checked = _selected.contains(division.id);
    return CheckboxListTile(
      value: checked,
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(division.name),
      subtitle: showParent && division.parentName.isNotEmpty
          ? Text(division.parentName)
          : null,
      onChanged: (value) {
        setState(() {
          if (value ?? false) {
            _selected.add(division.id);
          } else {
            _selected.remove(division.id);
          }
        });
      },
    );
  }
}
