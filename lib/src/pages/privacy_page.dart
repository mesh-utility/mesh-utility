import 'package:flutter/material.dart';

class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                const Icon(Icons.privacy_tip_outlined),
                const SizedBox(width: 8),
                Text(
                  'Privacy Policy',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Last updated: February 7, 2026',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    _PrivacySection(
                      title: 'Overview',
                      body:
                          'Mesh Utility is an open tool for mapping LoRa MeshCore radio coverage. We are committed to being transparent about what we collect, how it is used, and how you can manage it.',
                    ),
                    _PrivacySection(
                      title: 'Data We Collect',
                      body:
                          'Location coordinates during scans, RSSI/SNR radio measurements, discovered node public key prefixes and names, radio identifier prefix, and scan metadata such as timestamps and observer/sender labels.',
                    ),
                    _PrivacySection(
                      title: 'Data We Do Not Collect',
                      body:
                          'No name, email, phone number, or account login data. No ad tracking cookies. No full cryptographic radio keys.',
                    ),
                    _PrivacySection(
                      title: 'How Your Data Is Used',
                      body:
                          'To render RF coverage zones, maintain scan history, identify dead zones, and power smart scanning of recently covered areas.',
                    ),
                    _PrivacySection(
                      title: 'Permissions',
                      body:
                          'Bluetooth is required to communicate with your radio. Location is required to map coverage. You can revoke either permission in your system settings.',
                    ),
                    _PrivacySection(
                      title: 'Storage and Retention',
                      body:
                          'Scan data is stored in Cloudflare D1 and committed to the public mesh-data GitHub repository. You can request deletion for your connected radio from Settings using signed radio ownership proof.',
                    ),
                    _PrivacySection(
                      title: 'Local Storage',
                      body:
                          'The app stores non-sensitive local preferences such as theme and scan settings, plus local cache required for offline usage.',
                    ),
                    _PrivacySection(
                      title: 'Third-Party Services',
                      body:
                          'Map tiles are loaded from providers such as CartoDB/OpenStreetMap/Esri. Those services may log standard network request metadata under their own policies.',
                    ),
                    _PrivacySection(
                      title: 'Policy Updates',
                      body:
                          'This policy may change over time. The date on this page reflects the latest published revision.',
                    ),
                    _PrivacySection(
                      title: 'Contact',
                      body:
                          'If you have privacy questions, use the app support/feedback channels listed in the sidebar.',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrivacySection extends StatelessWidget {
  const _PrivacySection({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(body),
        ],
      ),
    );
  }
}
