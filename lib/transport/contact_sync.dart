import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mesh_utility/transport/protocol.dart';

/// Progress for an in-flight GET_CONTACTS sync.
class ContactSyncProgress {
  const ContactSyncProgress({
    required this.active,
    required this.received,
    this.expected,
    this.timedOut = false,
    this.completed = false,
    this.incomplete = false,
  });

  final bool active;
  final int received;
  final int? expected;
  final bool timedOut;

  /// The sync finished and the stored book reached the radio total.
  final bool completed;

  /// The sync finished short of the radio total.
  final bool incomplete;

  static const idle = ContactSyncProgress(active: false, received: 0);

  /// `Contacts n/total` while the radio's book size is known.
  String get progressLabel {
    if (expected != null) return 'Contacts $received/$expected';
    return 'Contacts $received';
  }

  /// True once the sync has stopped and the radio reported a book size.
  bool get hasOutcome =>
      !active && expected != null && (completed || incomplete || timedOut);

  /// [progressLabel] while running. After the sync stops, appends
  /// `complete` or `incomplete`.
  String get statusLabel {
    if (!hasOutcome) return progressLabel;
    final outcome = received >= expected! ? 'complete' : 'incomplete';
    return '$progressLabel $outcome';
  }
}

/// One contact accepted from a RESP_CONTACT frame.
class SyncedContact {
  const SyncedContact({
    required this.publicKeyPrefix,
    required this.name,
    required this.type,
    required this.lastMod,
  });

  final String publicKeyPrefix;
  final String name;
  final int type;

  /// Companion-clock unix seconds. `0` when the frame did not carry one.
  final int lastMod;
}

/// Result of a contact book sync.
class ContactSyncResult {
  const ContactSyncResult({
    required this.contacts,
    required this.contactTypes,
    required this.lastMods,
    required this.expectedTotal,
    required this.timedOut,
    required this.sawEnd,
    required this.attempts,
    this.newestLastMod,
  });

  final Map<String, String> contacts;
  final Map<String, int> contactTypes;
  final Map<String, int> lastMods;
  final int? expectedTotal;
  final bool timedOut;
  final bool sawEnd;
  final int attempts;

  /// Newest positive lastmod collected, including contacts seeded from the
  /// on-device store. This is the next CMD_GET_CONTACTS `since`.
  ///
  /// Lastmod is not arrival order. A resume from this value skips contacts
  /// that were never stored when their lastmod is older.
  final int? newestLastMod;

  /// Stored unique contacts reached the radio total. When the radio sent no
  /// total, this is true only after RESP_END_OF_CONTACTS without an idle stop.
  bool get isComplete {
    final expected = expectedTotal;
    if (expected == null) return sawEnd && !timedOut;
    return contacts.length >= expected;
  }
}

/// Runs GET_CONTACTS with a per-frame idle timeout and no total timeout.
///
/// [idleTimeout] resets on every inbound frame, including PUSH adverts, so a
/// slow phone can take as long as the link stays alive. The sync is complete
/// only when the merged unique book is at least the START total. A short
/// RESP_END_OF_CONTACTS and an idle timeout both retry. The retry sends
/// CMD_GET_CONTACTS with `since` set to the newest lastmod already collected.
/// If that filtered resume adds no contacts, or a filtered END is still short
/// of the total, the next attempt is a full dump (`since` omitted). Lastmod
/// is not arrival order, so a since cursor cannot fill gaps it skips. Stops
/// when the merged count reaches the START total or [maxAttempts] is exhausted.
///
/// [onContacts] receives newly accepted contacts in batches so the caller can
/// merge them into the per-radio store without blocking the frame parser.
Future<ContactSyncResult> collectContactsFromInbound({
  required Stream<Uint8List> inbound,
  required Future<void> Function(int? since) sendGetContacts,
  int? initialSince,
  Map<String, String> seedContacts = const {},
  Map<String, int> seedTypes = const {},
  Map<String, int> seedLastMods = const {},
  void Function(ContactSyncProgress progress)? onProgress,
  Future<void> Function(List<SyncedContact> batch)? onContacts,
  Duration idleTimeout = const Duration(seconds: 90),
  Duration retryDelay = const Duration(milliseconds: 400),
  int maxAttempts = 4,
  int checkpointEvery = 25,
}) async {
  final contacts = Map<String, String>.from(seedContacts);
  final contactTypes = Map<String, int>.from(seedTypes);
  final lastMods = Map<String, int>.from(seedLastMods);
  int? expectedTotal;
  var sawEnd = false;
  var timedOut = false;
  var attemptsUsed = 0;
  var wantFull = false;

  final pending = <SyncedContact>[];
  Future<void>? flushing;
  var flushQueued = false;

  void emit() {
    onProgress?.call(
      ContactSyncProgress(
        active: true,
        received: contacts.length,
        expected: expectedTotal,
      ),
    );
  }

  void logSync(String message) {
    debugPrint('contact sync $message');
  }

  Future<void> deliver(List<SyncedContact> batch) async {
    if (batch.isEmpty || onContacts == null) return;
    await onContacts(batch);
  }

  void scheduleFlush() {
    if (onContacts == null || pending.isEmpty) return;
    if (flushing != null) {
      flushQueued = true;
      return;
    }
    final batch = List<SyncedContact>.from(pending);
    pending.clear();
    flushing = deliver(batch).whenComplete(() {
      flushing = null;
      if (flushQueued || pending.length >= checkpointEvery) {
        flushQueued = false;
        if (pending.isNotEmpty) scheduleFlush();
      }
    });
  }

  Future<void> flushNow() async {
    if (onContacts == null) {
      pending.clear();
      return;
    }
    while (flushing != null || pending.isNotEmpty) {
      if (flushing != null) {
        await flushing;
        continue;
      }
      scheduleFlush();
      if (flushing == null) return;
    }
  }

  void remember(RadioContact contact) {
    final prefix = contact.publicKeyPrefix.trim().toUpperCase();
    final name = contact.name.trim();
    if (prefix.isEmpty || name.isEmpty) return;
    final previousLast = lastMods[prefix] ?? 0;
    final changed =
        contacts[prefix] != name ||
        contactTypes[prefix] != contact.type ||
        contact.lastMod > previousLast;
    contacts[prefix] = name;
    contactTypes[prefix] = contact.type;
    if (contact.lastMod > previousLast) {
      lastMods[prefix] = contact.lastMod;
    }
    if (!changed) return;
    pending.add(
      SyncedContact(
        publicKeyPrefix: prefix,
        name: name,
        type: contact.type,
        lastMod: contact.lastMod > previousLast
            ? contact.lastMod
            : previousLast,
      ),
    );
    if (pending.length >= checkpointEvery) scheduleFlush();
  }

  bool reachedTotal() {
    final expected = expectedTotal;
    return expected != null && contacts.length >= expected;
  }

  Completer<void>? done;
  Timer? idleTimer;

  void armIdle() {
    idleTimer?.cancel();
    final current = done;
    if (current == null) return;
    idleTimer = Timer(idleTimeout, () {
      if (!current.isCompleted) {
        timedOut = true;
        current.complete();
      }
    });
  }

  void onFrame(Uint8List frame) {
    if (frame.isEmpty) return;
    // Any frame means the link is alive — reset idle before filtering.
    final current = done;
    if (current != null && !current.isCompleted) armIdle();
    final code = frame[0];
    if (code == respCodeContactsStart) {
      expectedTotal = parseContactsStartTotal(frame) ?? expectedTotal;
      emit();
      return;
    }
    if (code == respCodeContact) {
      final contact = parseRadioContact(frame);
      if (contact != null) remember(contact);
      emit();
      return;
    }
    if (isEndOfContactsFrame(frame)) {
      sawEnd = true;
      final current = done;
      if (current != null && !current.isCompleted) current.complete();
    }
  }

  final sub = inbound.listen(onFrame);
  emit();
  try {
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final countBefore = contacts.length;
      final newest = _newestPositive(lastMods);
      final int? requestSince = wantFull
          ? null
          : (attempt == 1 ? (_positiveSince(initialSince) ?? newest) : newest);
      wantFull = false;
      sawEnd = false;
      timedOut = false;
      attemptsUsed = attempt;

      // Stay visible across resumes. END and idle must not clear the bar
      // until the whole sync stops.
      emit();
      logSync(
        'attempt=$attempt/$maxAttempts since=${requestSince ?? 0} '
        'stored=${contacts.length} expected=${expectedTotal ?? -1}',
      );

      final attemptDone = Completer<void>();
      done = attemptDone;
      armIdle();
      try {
        await sendGetContacts(requestSince);
        await attemptDone.future;
      } finally {
        idleTimer?.cancel();
        idleTimer = null;
        done = null;
      }
      await flushNow();

      final added = contacts.length - countBefore;
      final reached = reachedTotal();
      final wasSince = (requestSince ?? 0) > 0;
      logSync(
        'attempt=$attempt added=$added stored=${contacts.length} '
        'expected=${expectedTotal ?? -1} sawEnd=$sawEnd '
        'idle=${!sawEnd && !reached}',
      );

      if (reached) {
        timedOut = false;
        break;
      }

      // Still short of the radio total. A since cursor of the newest stored
      // lastmod misses contacts that have not arrived yet when their lastmod
      // is older, so a resume that adds nothing cannot make progress.
      if (wasSince && (added == 0 || sawEnd)) {
        wantFull = true;
        logSync(
          'next=full stored=${contacts.length} '
          'expected=${expectedTotal ?? -1} '
          'reason=${added == 0 ? 'since-added-none' : 'filtered-end-short'}',
        );
      } else if (sawEnd) {
        logSync(
          'next=retry stored=${contacts.length} '
          'expected=${expectedTotal ?? -1} reason=end-short',
        );
      } else {
        timedOut = true;
        logSync(
          'next=retry stored=${contacts.length} '
          'expected=${expectedTotal ?? -1} reason=idle',
        );
      }

      emit();
      if (attempt >= maxAttempts) break;
      sawEnd = false;
      timedOut = false;
      if (retryDelay > Duration.zero) {
        await Future<void>.delayed(retryDelay);
      }
    }
  } finally {
    idleTimer?.cancel();
    await sub.cancel();
  }
  await flushNow();

  final newest = _newestPositive(lastMods);
  final stored = contacts.length;
  final expected = expectedTotal;
  final idleStop = timedOut && !sawEnd;
  final short = expected != null && stored < expected;
  final complete = !short && (expected != null || (sawEnd && !idleStop));
  logSync(
    'done stored=$stored expected=${expected ?? -1} '
    '${complete ? 'complete' : 'incomplete'} '
    'attempts=$attemptsUsed sawEnd=$sawEnd idle=$idleStop',
  );
  onProgress?.call(
    ContactSyncProgress(
      active: false,
      received: stored,
      expected: expected,
      timedOut: idleStop,
      completed: complete,
      incomplete: short,
    ),
  );
  return ContactSyncResult(
    contacts: contacts,
    contactTypes: contactTypes,
    lastMods: lastMods,
    expectedTotal: expected,
    timedOut: idleStop,
    sawEnd: sawEnd,
    attempts: attemptsUsed,
    newestLastMod: newest,
  );
}

int? _positiveSince(int? since) {
  if (since == null || since <= 0) return null;
  return since;
}

int? _newestPositive(Map<String, int> lastMods) {
  int? newest;
  for (final value in lastMods.values) {
    if (value <= 0) continue;
    if (newest == null || value > newest) newest = value;
  }
  return newest;
}
