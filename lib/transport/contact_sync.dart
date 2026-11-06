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
/// Each START/CONTACT/END frame resets [idleTimeout]. [overallTimeout] is only
/// a safety ceiling for huge books on slow links.
Future<ContactSyncResult> collectContactsFromInbound({
  required Stream<Uint8List> inbound,
  required Future<void> Function() sendGetContacts,
  void Function(ContactSyncProgress progress)? onProgress,
  Duration idleTimeout = const Duration(seconds: 25),
  Duration overallTimeout = const Duration(minutes: 6),
}) async {
  final contacts = <String, String>{};
  final contactTypes = <String, int>{};
  int? expectedTotal;
  var sawEnd = false;
  var timedOut = false;

  final done = Completer<void>();
  Timer? idleTimer;
  late final Timer overallTimer;

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
    final code = frame[0];
    if (code == respCodeContactsStart) {
      expectedTotal = parseContactsStartTotal(frame);
      armIdle();
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
      armIdle();
      emit();
      return;
    }
    if (isEndOfContactsFrame(frame)) {
      sawEnd = true;
      armIdle();
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

  emit(completed: true, timedOutFlag: timedOut);
  return ContactSyncResult(
    contacts: contacts,
    contactTypes: contactTypes,
    expectedTotal: expectedTotal,
    timedOut: timedOut,
    sawEnd: sawEnd,
  );
}
