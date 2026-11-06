import 'package:flutter/material.dart';

class ContactsPage extends StatelessWidget {
  const ContactsPage({super.key, required this.contacts});

  final Map<String, String> contacts;

  @override
  Widget build(BuildContext context) {
    if (contacts.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Contacts')),
        body: const Center(child: Text('No contacts found for this radio.')),
      );
    }

    final entries = contacts.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));

    return Scaffold(
      appBar: AppBar(title: const Text('Contacts')),
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
