import 'package:flutter/material.dart';
import 'package:mesh_utility/transport/contact_sync.dart';

class ContactsPage extends StatelessWidget {
  const ContactsPage({
    super.key,
    required this.contacts,
    this.syncProgress = ContactSyncProgress.idle,
  });

  final Map<String, String> contacts;
  final ContactSyncProgress syncProgress;

  @override
  Widget build(BuildContext context) {
    final countLabel = syncProgress.active
        ? 'Contacts (${syncProgress.received}'
            '${syncProgress.expected != null ? '/${syncProgress.expected}' : ''}…)'
        : 'Contacts (${contacts.length})';

    if (syncProgress.active && contacts.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(countLabel)),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                syncProgress.expected == null
                    ? 'Syncing contacts… ${syncProgress.received}'
                    : 'Syncing contacts… ${syncProgress.received}/${syncProgress.expected}',
              ),
            ],
          ),
        ),
      );
    }

    if (contacts.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(countLabel)),
        body: const Center(child: Text('No contacts found for this radio.')),
      );
    }

    final entries = contacts.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));

    return Scaffold(
      appBar: AppBar(
        title: Text(countLabel),
        bottom: syncProgress.active
            ? PreferredSize(
                preferredSize: const Size.fromHeight(4),
                child: LinearProgressIndicator(
                  value: syncProgress.expected == null ||
                          syncProgress.expected == 0
                      ? null
                      : (syncProgress.received / syncProgress.expected!)
                          .clamp(0.0, 1.0),
                ),
              )
            : null,
      ),
      body: ListView.builder(
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];
          return ListTile(title: Text(entry.value), subtitle: Text(entry.key));
        },
      ),
    );
  }
}
