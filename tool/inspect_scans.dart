import 'package:mesh_utility/src/services/reax_database.dart';

String norm(String? v) => (v ?? '').toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');

Future<void> main() async {
  final db = await ReaxDatabase.instance();
  final raw = await db.get('scans:raw');
  if (raw is! List) {
    print('scans:raw missing or not list: ${raw.runtimeType}');
    return;
  }

  const target = 'D680456772CA';
  const target8 = 'D6804567';

  int total = 0;
  int radioFull = 0, radio8 = 0;
  int observerFull = 0, observer8 = 0;
  int nodeFull = 0, node8 = 0;
  int downloadedTrue = 0, downloadedFalse = 0;

  final radioPrefixCounts = <String, int>{};
  final observerPrefixCounts = <String, int>{};
  final nodePrefixCounts = <String, int>{};

  for (final e in raw) {
    if (e is! Map) continue;
    total++;
    final m = e.cast<String, dynamic>();
    final radio = norm(m['radioId']?.toString());
    final observer = norm(m['observerId']?.toString());
    final node = norm(m['nodeId']?.toString());
    final downloaded = m['downloadedFromWorker'] == true;
    if (downloaded) {
      downloadedTrue++;
    } else {
      downloadedFalse++;
    }

    if (radio == target) radioFull++;
    if (radio.startsWith(target8)) radio8++;
    if (observer == target) observerFull++;
    if (observer.startsWith(target8)) observer8++;
    if (node == target) nodeFull++;
    if (node.startsWith(target8)) node8++;

    if (radio.isNotEmpty) {
      final p = radio.length >= 8 ? radio.substring(0, 8) : radio;
      radioPrefixCounts[p] = (radioPrefixCounts[p] ?? 0) + 1;
    }
    if (observer.isNotEmpty) {
      final p = observer.length >= 8 ? observer.substring(0, 8) : observer;
      observerPrefixCounts[p] = (observerPrefixCounts[p] ?? 0) + 1;
    }
    if (node.isNotEmpty) {
      final p = node.length >= 8 ? node.substring(0, 8) : node;
      nodePrefixCounts[p] = (nodePrefixCounts[p] ?? 0) + 1;
    }
  }

  List<MapEntry<String, int>> top(Map<String, int> m) {
    final l = m.entries.toList()..sort((a,b) => b.value.compareTo(a.value));
    return l.take(12).toList();
  }

  print('total=$total downloadedFromWorker=true:$downloadedTrue false:$downloadedFalse');
  print('radioId   full=$radioFull prefix8=$radio8 target=$target target8=$target8');
  print('observer  full=$observerFull prefix8=$observer8');
  print('nodeId    full=$nodeFull prefix8=$node8');
  print('top radio prefixes: ${top(radioPrefixCounts)}');
  print('top observer prefixes: ${top(observerPrefixCounts)}');
  print('top node prefixes: ${top(nodePrefixCounts)}');
}
