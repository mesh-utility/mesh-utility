import 'package:flutter/material.dart';
import 'package:mesh_utility/src/models/local_contact.dart';
import 'package:mesh_utility/src/platform/local_contacts_supported.dart';
import 'package:mesh_utility/transport/contact_sync.dart';
import 'package:mesh_utility/transport/protocol.dart';

class ContactsPage extends StatefulWidget {
  const ContactsPage({
    super.key,
    required this.contacts,
    this.contactTypes = const {},
    this.syncProgress = ContactSyncProgress.idle,
  });

  final Map<String, String> contacts;
  final Map<String, int> contactTypes;
  final ContactSyncProgress syncProgress;

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage> {
  String _query = '';

  String _typeLabel(int type) {
    switch (type) {
      case advTypeChat:
        return 'Companion';
      case advTypeRepeater:
        return 'Repeater';
      case advTypeRoom:
        return 'Room';
      case advTypeSensor:
        return 'Sensor';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final showSearch = localContactsSupported;
    final all = widget.contacts.entries
        .map(
          (e) => LocalContact(
            publicKeyPrefix: e.key,
            name: e.value,
            type: widget.contactTypes[e.key] ?? 0,
            lastHeard: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          ),
        )
        .toList();
    final filtered = showSearch ? filterLocalContacts(all, _query) : all;
    filtered.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    final countLabel = widget.syncProgress.active
        ? widget.syncProgress.progressLabel
        : (showSearch && _query.trim().isNotEmpty
            ? 'Contacts (${filtered.length}/${widget.contacts.length})'
            : 'Contacts (${widget.contacts.length})');

    if (widget.syncProgress.active && widget.contacts.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(countLabel)),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(widget.syncProgress.progressLabel),
            ],
          ),
        ),
      );
    }

    if (widget.contacts.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(countLabel)),
        body: const Center(child: Text('No contacts found for this radio.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(countLabel),
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(
            (showSearch ? 56.0 : 0) + (widget.syncProgress.active ? 4.0 : 0),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showSearch)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: 'Search name or ID…',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
              if (widget.syncProgress.active)
                LinearProgressIndicator(
                  value: widget.syncProgress.expected == null ||
                          widget.syncProgress.expected == 0
                      ? null
                      : (widget.syncProgress.received /
                              widget.syncProgress.expected!)
                          .clamp(0.0, 1.0),
                ),
            ],
          ),
        ),
      ),
      body: filtered.isEmpty
          ? const Center(child: Text('No matching contacts.'))
          : ListView.builder(
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final c = filtered[index];
                final type = _typeLabel(c.type);
                return ListTile(
                  title: Text(c.name),
                  subtitle: Text(
                    type.isEmpty ? c.publicKeyPrefix : '${c.publicKeyPrefix} · $type',
                  ),
                );
              },
            ),
    );
  }
}
