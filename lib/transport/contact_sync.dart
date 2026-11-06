import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_utility/transport/protocol.dart';

/// Progress for an in-flight GET_CONTACTS sync.
class ContactSyncProgress {
  const ContactSyncProgress({
    required this.active,
    required this.received,
    this.expected,
    this.timedOut = false,
    this.completed = false,
  });

  final bool active;
  final int received;
  final int? expected;
  final bool timedOut;
  final bool completed;

  static const idle = ContactSyncProgress(active: false, received: 0);
}

/// Result of a contact book sync.
class ContactSyncResult {
  const ContactSyncResult({
    required this.contacts,
    required this.contactTypes,
    required this.expectedTotal,
    required this.timedOut,
    required this.sawEnd,
  });

  final Map<String, String> contacts;
  final Map<String, int> contactTypes;
  final int? expectedTotal;
  final bool timedOut;
  final bool sawEnd;
}

/// Runs GET_CONTACTS collection with an **idle/per-frame** timeout.
///
/// Idle resets on **every** inbound frame (including PUSH), so advert traffic
/// during a large dump does not abort the sync. [overallTimeout] is a safety
/// ceiling for huge books on slow links.
Future<ContactSyncResult> collectContactsFromInbound({
  required Stream<Uint8List> inbound,
  required Future<void> Function() sendGetContacts,
  void Function(ContactSyncProgress progress)? onProgress,
  Duration idleTimeout = const Duration(seconds: 45),
  Duration overallTimeout = const Duration(minutes: 8),
  int maxAttempts = 3,
}) async {
  final contacts = <String, String>{};
  final contactTypes = <String, int>{};
  int? expectedTotal;
  var sawEnd = false;
  var timedOut = false;

  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    final done = Completer<void>();
    Timer? idleTimer;
    late final Timer overallTimer;
    var attemptSawEnd = false;

    void emit({bool completed = false, bool timedOutFlag = false}) {
      onProgress?.call(
        ContactSyncProgress(
          active: !completed && !timedOutFlag,
          received: contacts.length,
          expected: expectedTotal,
          timedOut: timedOutFlag,
          completed: completed,
        ),
      );
    }

    void armIdle() {
      idleTimer?.cancel();
      idleTimer = Timer(idleTimeout, () {
        if (!done.isCompleted) {
          timedOut = true;
          done.complete();
        }
      });
    }

    void onFrame(Uint8List frame) {
      if (frame.isEmpty) return;
      // Any frame means the link is alive — reset idle before filtering.
      armIdle();
      final code = frame[0];
      if (code == respCodeContactsStart) {
        expectedTotal = parseContactsStartTotal(frame) ?? expectedTotal;
        emit();
        return;
      }
      if (code == respCodeContact) {
        final contact = parseRadioContact(frame);
        if (contact != null) {
          final prefix = contact.publicKeyPrefix.trim().toUpperCase();
          final name = contact.name.trim();
          if (prefix.isNotEmpty && name.isNotEmpty) {
            contacts[prefix] = name;
            contactTypes[prefix] = contact.type;
          }
        }
        emit();
        return;
      }
      if (isEndOfContactsFrame(frame)) {
        attemptSawEnd = true;
        sawEnd = true;
        if (!done.isCompleted) done.complete();
        return;
      }
    }

    late final StreamSubscription<Uint8List> sub;
    sub = inbound.listen(onFrame);

    overallTimer = Timer(overallTimeout, () {
      if (!done.isCompleted) {
        timedOut = true;
        done.complete();
      }
    });

    emit();
    armIdle();
    try {
      await sendGetContacts();
      await done.future;
    } finally {
      idleTimer?.cancel();
      overallTimer.cancel();
      await sub.cancel();
    }

    if (attemptSawEnd) {
      timedOut = false;
      break;
    }
    if (expectedTotal != null && contacts.length >= expectedTotal!) {
      timedOut = false;
      sawEnd = true;
      break;
    }
    // Incomplete: retry while keeping merged maps.
    if (attempt < maxAttempts) {
      timedOut = false;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  onProgress?.call(
    ContactSyncProgress(
      active: false,
      received: contacts.length,
      expected: expectedTotal,
      timedOut: timedOut && !sawEnd,
      completed: true,
    ),
  );
  return ContactSyncResult(
    contacts: contacts,
    contactTypes: contactTypes,
    expectedTotal: expectedTotal,
    timedOut: timedOut && !sawEnd,
    sawEnd: sawEnd,
  );
}
