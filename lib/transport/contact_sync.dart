import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_utility/transport/protocol.dart';

/// Quiet window after the last inbound frame before a GET_CONTACTS pass
/// is treated as stalled and released so scans can use the radio.
const Duration kContactSyncStallTimeout = Duration(seconds: 12);

/// Progress for an in-flight GET_CONTACTS sync.
class ContactSyncProgress {
  const ContactSyncProgress({
    required this.active,
    required this.received,
    this.expected,
    this.completed = false,
    this.incomplete = false,
    this.disconnected = false,
    this.stalled = false,
    this.cancelled = false,
  });

  final bool active;
  final int received;
  final int? expected;

  /// RESP_END_OF_CONTACTS was seen.
  final bool completed;

  /// RESP_ERR arrived before RESP_CONTACTS_START. The sync does not retry.
  final bool incomplete;

  /// The transport closed before RESP_END_OF_CONTACTS.
  final bool disconnected;

  /// No inbound frame arrived within [kContactSyncStallTimeout].
  /// The caller may resume with the latest lastMod.
  final bool stalled;

  /// The pass was aborted so a scan or force-scan can use the radio.
  /// The caller should resume after the scan.
  final bool cancelled;

  static const idle = ContactSyncProgress(active: false, received: 0);

  /// `Contacts n/total` while the radio's book size is known.
  String get progressLabel {
    if (expected != null) return 'Contacts $received/$expected';
    return 'Contacts $received';
  }

  /// True once the sync has stopped with a terminal outcome.
  bool get hasOutcome =>
      !active &&
      (completed || incomplete || disconnected || stalled || cancelled);

  /// [progressLabel] while running. After the sync stops, the terminal status.
  /// A dropped link reads "Bluetooth disconnected", never "incomplete".
  String get statusLabel {
    if (disconnected) return 'Bluetooth disconnected';
    if (!hasOutcome) return progressLabel;
    if (cancelled) return progressLabel;
    if (stalled) return '$progressLabel stalled';
    final outcome = completed ? 'complete' : 'incomplete';
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

/// How a one-pass GET_CONTACTS finished.
enum ContactSyncOutcome { completed, incomplete, disconnected, stalled, cancelled }

/// Result of a contact book sync.
class ContactSyncResult {
  const ContactSyncResult({
    required this.contacts,
    required this.contactTypes,
    required this.lastMods,
    required this.expectedTotal,
    required this.outcome,
    required this.framesSeen,
  });

  final Map<String, String> contacts;
  final Map<String, int> contactTypes;
  final Map<String, int> lastMods;
  final int? expectedTotal;
  final ContactSyncOutcome outcome;

  /// Inbound frames observed during the pass, including ignored PUSH frames.
  final int framesSeen;

  /// True when RESP_END_OF_CONTACTS was seen.
  bool get isComplete => outcome == ContactSyncOutcome.completed;
}

/// One GET_CONTACTS pass, matching the MeshCore companion procedure.
///
/// Sends [sendGetContacts] once. [initialSince] is forwarded only when the
/// caller passes a positive value (incremental sync). The radio then sends
/// RESP_CONTACTS_START (code 2), zero or more RESP_CONTACT (code 3) frames,
/// and RESP_END_OF_CONTACTS (code 4). Every other code, including PUSH
/// (0x80+), is ignored. RESP_ERR (code 1) before START finishes as
/// [ContactSyncOutcome.incomplete] and is not retried. The inbound stream
/// closing, or [linkClosed] completing, finishes as
/// [ContactSyncOutcome.disconnected]. A quiet stall of [stallTimeout]
/// finishes as [ContactSyncOutcome.stalled] so the caller can resume.
/// [cancel] finishing aborts as [ContactSyncOutcome.cancelled] so a scan
/// can use the radio. RESP_ERR before START is still not retried.
///
/// [onContacts] receives newly accepted contacts in batches so the caller can
/// merge them into the per-radio store without blocking the frame parser.
Future<ContactSyncResult> collectContactsFromInbound({
  required Stream<Uint8List> inbound,
  required Future<void> Function(int? since) sendGetContacts,
  int? initialSince,
  Future<void>? linkClosed,
  Duration? stallTimeout,
  Future<void>? cancel,
  Map<String, String> seedContacts = const {},
  Map<String, int> seedTypes = const {},
  Map<String, int> seedLastMods = const {},
  void Function(ContactSyncProgress progress)? onProgress,
  Future<void> Function(List<SyncedContact> batch)? onContacts,
  int checkpointEvery = 25,
}) async {
  final contacts = Map<String, String>.from(seedContacts);
  final contactTypes = Map<String, int>.from(seedTypes);
  final lastMods = Map<String, int>.from(seedLastMods);
  int? expectedTotal;
  var sawStart = false;
  var framesSeen = 0;
  var outcome = ContactSyncOutcome.disconnected;

  final pending = <SyncedContact>[];
  Future<void>? flushing;
  var flushQueued = false;

  void emit({bool terminal = false}) {
    onProgress?.call(
      ContactSyncProgress(
        active: !terminal,
        received: contacts.length,
        expected: expectedTotal,
        completed: terminal && outcome == ContactSyncOutcome.completed,
        incomplete: terminal && outcome == ContactSyncOutcome.incomplete,
        disconnected: terminal && outcome == ContactSyncOutcome.disconnected,
        stalled: terminal && outcome == ContactSyncOutcome.stalled,
        cancelled: terminal && outcome == ContactSyncOutcome.cancelled,
      ),
    );
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
    // Identity is the public-key prefix. An empty name is still a contact.
    if (prefix.isEmpty) return;
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

  final framesDone = Completer<void>();

  void finish(ContactSyncOutcome next) {
    if (framesDone.isCompleted) return;
    outcome = next;
    framesDone.complete();
  }

  Timer? stallTimer;
  void armStall() {
    stallTimer?.cancel();
    final timeout = stallTimeout;
    if (timeout == null) return;
    stallTimer = Timer(timeout, () => finish(ContactSyncOutcome.stalled));
  }

  void onFrame(Uint8List frame) {
    framesSeen++;
    if (frame.isEmpty || framesDone.isCompleted) return;
    armStall();
    final code = frame[0];
    if (code == respCodeContactsStart) {
      sawStart = true;
      expectedTotal = parseContactsStartTotal(frame) ?? expectedTotal;
      emit();
      return;
    }
    // ERR before START is a failed command. Do not send GET_CONTACTS again.
    if (!sawStart && code == respCodeErr) {
      finish(ContactSyncOutcome.incomplete);
      return;
    }
    if (code == respCodeContact) {
      final contact = parseRadioContact(frame);
      if (contact != null) remember(contact);
      emit();
      return;
    }
    if (code == respCodeEndOfContacts) {
      finish(ContactSyncOutcome.completed);
      return;
    }
    // PUSH (0x80+) and every other response code stay on the link and are
    // not part of this command.
  }

  final requestSince = (initialSince != null && initialSince > 0)
      ? initialSince
      : null;
  final sub = inbound.listen(
    onFrame,
    onError: (Object _, StackTrace _) =>
        finish(ContactSyncOutcome.disconnected),
    onDone: () => finish(ContactSyncOutcome.disconnected),
  );
  emit();
  if (cancel != null) {
    unawaited(
      cancel.then<void>(
        (_) => finish(ContactSyncOutcome.cancelled),
        onError: (_) => finish(ContactSyncOutcome.cancelled),
      ),
    );
  }
  try {
    await sendGetContacts(requestSince);
    armStall();
    if (!framesDone.isCompleted) {
      final racers = <Future<void>>[framesDone.future];
      if (linkClosed != null) racers.add(linkClosed);
      try {
        await Future.any(racers);
      } catch (_) {
        // linkClosed failed closed. Same as a dropped connection.
      }
      if (!framesDone.isCompleted) {
        finish(
          linkClosed != null
              ? ContactSyncOutcome.disconnected
              : ContactSyncOutcome.stalled,
        );
      }
    }
  } catch (_) {
    finish(ContactSyncOutcome.disconnected);
  } finally {
    stallTimer?.cancel();
    await sub.cancel();
  }
  try {
    await flushNow();
  } catch (_) {
    // Keep contacts already accepted. The caller still sees the outcome.
  }
  emit(terminal: true);
  return ContactSyncResult(
    contacts: contacts,
    contactTypes: contactTypes,
    lastMods: lastMods,
    expectedTotal: expectedTotal,
    outcome: outcome,
    framesSeen: framesSeen,
  );
}
