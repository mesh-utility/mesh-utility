import 'package:mesh_utility/src/services/boundary_catalog.dart';

/// One row in the scan-cache division tree.
///
/// Parents are countries or states. Leaves are the divisions the active mode
/// stores (`scanCacheAdmin1Ids` or `scanCacheAdmin2Ids`). A parent [leafIds]
/// list is every stored id under that row, so Select all does not write the
/// parent itself.
class DivisionPickerNode {
  const DivisionPickerNode({
    required this.key,
    required this.title,
    required this.leafIds,
    this.children = const <DivisionPickerNode>[],
  });

  final String key;
  final String title;
  final List<String> leafIds;
  final List<DivisionPickerNode> children;

  bool get isLeaf => children.isEmpty;
}

/// Country, then state, then county when [BoundaryIndex.regions] is set.
///
/// Admin-1 indexes have no regions, so the tree is country then division.
/// Admin-2 indexes keep the country (United States) and use regions for
/// states. Counties stay the leaves. Ids are unchanged.
List<DivisionPickerNode> buildDivisionPickerTree(BoundaryIndex index) {
  if (index.regions.isNotEmpty) {
    return _admin2Tree(index);
  }
  return _admin1Tree(index);
}

List<DivisionPickerNode> _admin1Tree(BoundaryIndex index) {
  final byCountry = <String, List<BoundaryDivision>>{};
  for (final division in index.divisions) {
    byCountry
        .putIfAbsent(division.countryCode, () => <BoundaryDivision>[])
        .add(division);
  }
  final nodes = <DivisionPickerNode>[];
  final seen = <String>{};
  for (final country in index.countries) {
    seen.add(country.code);
    final leaves = byCountry[country.code];
    if (leaves == null || leaves.isEmpty) continue;
    nodes.add(_countryNode(country.code, country.name, leaves));
  }
  for (final entry in byCountry.entries) {
    if (seen.contains(entry.key) || entry.value.isEmpty) continue;
    final name = entry.value.first.parentName.isNotEmpty
        ? entry.value.first.parentName
        : entry.key;
    nodes.add(_countryNode(entry.key, name, entry.value));
  }
  return List<DivisionPickerNode>.unmodifiable(nodes);
}

List<DivisionPickerNode> _admin2Tree(BoundaryIndex index) {
  final regionsByCountry = <String, List<BoundaryRegion>>{};
  for (final region in index.regions) {
    regionsByCountry
        .putIfAbsent(region.countryCode, () => <BoundaryRegion>[])
        .add(region);
  }
  final divisionsByRegion = <String, List<BoundaryDivision>>{};
  for (final division in index.divisions) {
    divisionsByRegion
        .putIfAbsent(division.countryCode, () => <BoundaryDivision>[])
        .add(division);
  }
  final countries = index.countries.isNotEmpty
      ? index.countries
      : const <BoundaryCountry>[
          BoundaryCountry(code: '', name: 'United States'),
        ];
  final nodes = <DivisionPickerNode>[];
  final seen = <String>{};
  for (final country in countries) {
    seen.add(country.code);
    final regionNodes = _regionNodes(
      regionsByCountry[country.code] ?? const <BoundaryRegion>[],
      divisionsByRegion,
      country.code,
    );
    if (regionNodes.isEmpty) continue;
    nodes.add(
      DivisionPickerNode(
        key: 'country:${country.code}',
        title: country.name,
        leafIds: List<String>.unmodifiable(<String>[
          for (final region in regionNodes) ...region.leafIds,
        ]),
        children: List<DivisionPickerNode>.unmodifiable(regionNodes),
      ),
    );
  }
  for (final entry in regionsByCountry.entries) {
    if (seen.contains(entry.key)) continue;
    final regionNodes = _regionNodes(entry.value, divisionsByRegion, entry.key);
    if (regionNodes.isEmpty) continue;
    nodes.add(
      DivisionPickerNode(
        key: 'country:${entry.key}',
        title: entry.key.isEmpty ? 'United States' : entry.key,
        leafIds: List<String>.unmodifiable(<String>[
          for (final region in regionNodes) ...region.leafIds,
        ]),
        children: List<DivisionPickerNode>.unmodifiable(regionNodes),
      ),
    );
  }
  return List<DivisionPickerNode>.unmodifiable(nodes);
}

List<DivisionPickerNode> _regionNodes(
  List<BoundaryRegion> regions,
  Map<String, List<BoundaryDivision>> divisionsByRegion,
  String countryCode,
) {
  final nodes = <DivisionPickerNode>[];
  for (final region in regions) {
    final leaves = divisionsByRegion[region.code];
    if (leaves == null || leaves.isEmpty) continue;
    nodes.add(
      DivisionPickerNode(
        key: 'region:$countryCode:${region.code}',
        title: region.name,
        leafIds: List<String>.unmodifiable(<String>[
          for (final division in leaves) division.id,
        ]),
        children: List<DivisionPickerNode>.unmodifiable(<DivisionPickerNode>[
          for (final division in leaves)
            DivisionPickerNode(
              key: 'div:${division.id}',
              title: division.name,
              leafIds: List<String>.unmodifiable(<String>[division.id]),
            ),
        ]),
      ),
    );
  }
  return nodes;
}

DivisionPickerNode _countryNode(
  String code,
  String name,
  List<BoundaryDivision> leaves,
) {
  return DivisionPickerNode(
    key: 'country:$code',
    title: name,
    leafIds: List<String>.unmodifiable(<String>[
      for (final division in leaves) division.id,
    ]),
    children: List<DivisionPickerNode>.unmodifiable(<DivisionPickerNode>[
      for (final division in leaves)
        DivisionPickerNode(
          key: 'div:${division.id}',
          title: division.name,
          leafIds: List<String>.unmodifiable(<String>[division.id]),
        ),
    ]),
  );
}

/// `true` all, `false` none, `null` some. Empty [leafIds] is unchecked.
bool? divisionSelectionState(Set<String> selected, Iterable<String> leafIds) {
  var total = 0;
  var hits = 0;
  for (final id in leafIds) {
    total++;
    if (selected.contains(id)) hits++;
  }
  if (total == 0 || hits == 0) return false;
  if (hits == total) return true;
  return null;
}

int selectedLeafCount(Set<String> selected, Iterable<String> leafIds) {
  var hits = 0;
  for (final id in leafIds) {
    if (selected.contains(id)) hits++;
  }
  return hits;
}

/// Selects every leaf when the row is clear or partial. Clears when all are on.
void toggleDivisionSelection(Set<String> selected, Iterable<String> leafIds) {
  if (divisionSelectionState(selected, leafIds) == true) {
    selected.removeAll(leafIds);
  } else {
    selected.addAll(leafIds);
  }
}

/// Opens ancestors that are only partly selected, so a saved county is visible
/// without expanding every fully selected state.
Set<String> expandedKeysForPartialSelection(
  List<DivisionPickerNode> roots,
  Set<String> selected,
) {
  final keys = <String>{};
  void walk(DivisionPickerNode node) {
    if (node.isLeaf) return;
    // Only a partial row auto-expands. A fully selected country stays
    // collapsed so thousands of counties are not built at once.
    if (divisionSelectionState(selected, node.leafIds) != null) return;
    keys.add(node.key);
    for (final child in node.children) {
      walk(child);
    }
  }

  for (final root in roots) {
    walk(root);
  }
  return keys;
}

/// Flat search matches. The tree is hidden while [query] is non-empty.
List<BoundaryDivision> matchingDivisions(BoundaryIndex index, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return const <BoundaryDivision>[];
  return <BoundaryDivision>[
    for (final division in index.divisions)
      if (division.name.toLowerCase().contains(needle) ||
          division.parentName.toLowerCase().contains(needle) ||
          division.id.toLowerCase().contains(needle))
        division,
  ];
}
