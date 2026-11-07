import 'dart:async';
import 'dart:isolate';

import 'package:reaxdb_dart/reaxdb_dart.dart';

import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/models/mesh_node.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/models/scan_result.dart';
import 'package:mesh_utility/src/services/history_pipeline.dart';

const int _chunkSize = 1500;

class _LoadRequest {
  const _LoadRequest({required this.databasePath, required this.reply});

  final String databasePath;
  final SendPort reply;
}

class _ScanChunk {
  const _ScanChunk(this.scans);

  final List<RawScan> scans;
}

class _DerivedMeta {
  const _DerivedMeta({
    required this.zones,
    required this.nodes,
    required this.persistedChanges,
    required this.suppressedRows,
  });

  final List<CoverageZone> zones;
  final List<MeshNode> nodes;
  final bool persistedChanges;
  final int suppressedRows;
}

class _ResultChunk {
  const _ResultChunk(this.scanResults);

  final List<ScanResult> scanResults;
}

class _LoadDone {
  const _LoadDone();
}

class _LoadFailed {
  const _LoadFailed(this.message);

  final String message;
}

/// Reads the on-disk scan cache in a background isolate.
///
/// ReaxDB decodes the legacy all-days blob with a synchronous `jsonDecode`
/// on whatever isolate calls `get`. Doing that on the UI isolate is what
/// froze Alpha-20 on restart. The caller must close its own database handle
/// before calling this, then reopen after it returns.
Future<LoadedHistory> loadPersistedHistory(
  String databasePath, {
  void Function(int loadedScans)? onLoaded,
}) async {
  final receive = ReceivePort();
  final errors = ReceivePort();
  final done = Completer<LoadedHistory>();
  final scans = <RawScan>[];
  final scanResults = <ScanResult>[];
  List<CoverageZone> zones = const <CoverageZone>[];
  List<MeshNode> nodes = const <MeshNode>[];
  var persistedChanges = false;
  var suppressedRows = 0;
  Isolate? isolate;

  void fail(Object error) {
    if (!done.isCompleted) {
      done.completeError(StateError('Cached history load failed: $error'));
    }
  }

  final errorSub = errors.listen((message) {
    fail(message ?? 'unknown');
  });
  final messageSub = receive.listen((message) {
    if (message is _LoadFailed) {
      fail(message.message);
      return;
    }
    if (message is _ScanChunk) {
      scans.addAll(message.scans);
      onLoaded?.call(scans.length);
      return;
    }
    if (message is _DerivedMeta) {
      zones = message.zones;
      nodes = message.nodes;
      persistedChanges = message.persistedChanges;
      suppressedRows = message.suppressedRows;
      return;
    }
    if (message is _ResultChunk) {
      scanResults.addAll(message.scanResults);
      return;
    }
    if (message is _LoadDone && !done.isCompleted) {
      done.complete(
        LoadedHistory(
          scans: scans,
          zones: zones,
          nodes: nodes,
          scanResults: scanResults,
          persistedChanges: persistedChanges,
          suppressedRows: suppressedRows,
        ),
      );
    }
  });

  try {
    isolate = await Isolate.spawn(
      _persistedHistoryEntry,
      _LoadRequest(databasePath: databasePath, reply: receive.sendPort),
      onError: errors.sendPort,
      debugName: 'mesh-history-load',
    );
    return await done.future.timeout(const Duration(minutes: 10));
  } finally {
    await messageSub.cancel();
    await errorSub.cancel();
    receive.close();
    errors.close();
    isolate?.kill(priority: Isolate.beforeNextEvent);
  }
}

void _persistedHistoryEntry(_LoadRequest request) {
  final keepAlive = ReceivePort();
  unawaited(() async {
    try {
      await _loadPersistedHistory(request);
    } catch (error, stack) {
      request.reply.send(_LoadFailed('$error\n$stack'));
    } finally {
      keepAlive.close();
    }
  }());
}

Future<void> _loadPersistedHistory(_LoadRequest request) async {
  final db = await ReaxDB.simple(request.databasePath);
  late final PreparedScans prepared;
  late final DerivedScanData derived;
  try {
    final raw = await db.get(rawScansStorageKey);
    final decoded = decodeStoredRawScans(raw);
    prepared = prepareRawScans(decoded);
    derived = buildDerivedScanData(prepared.scans);
    if (prepared.changed) {
      await db.put(
        rawScansStorageKey,
        encodeRawScansForStorage(prepared.scans),
      );
    }
  } finally {
    // Release the files before the UI isolate reopens the same path.
    await db.close();
  }
  _sendChunks(request.reply, prepared.scans, (chunk) => _ScanChunk(chunk));
  request.reply.send(
    _DerivedMeta(
      zones: derived.zones,
      nodes: derived.nodes,
      persistedChanges: prepared.changed,
      suppressedRows: prepared.suppressedRows,
    ),
  );
  _sendChunks(
    request.reply,
    derived.scanResults,
    (chunk) => _ResultChunk(chunk),
  );
  request.reply.send(const _LoadDone());
}

void _sendChunks<T>(
  SendPort reply,
  List<T> items,
  Object Function(List<T> chunk) wrap,
) {
  if (items.isEmpty) return;
  for (var start = 0; start < items.length; start += _chunkSize) {
    final end = start + _chunkSize < items.length
        ? start + _chunkSize
        : items.length;
    reply.send(wrap(items.sublist(start, end)));
  }
}
