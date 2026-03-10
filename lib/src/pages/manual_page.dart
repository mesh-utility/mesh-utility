import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class ManualPage extends StatelessWidget {
  const ManualPage({super.key});

  Future<void> _openDiscord() async {
    await launchUrl(
      Uri.parse('https://discord.gg/Xyhjz7CtuW'),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    final sections = <({IconData icon, String title, List<String> content})>[
      (
        icon: Icons.help_outline,
        title: 'What Is Mesh Utility?',
        content: [
          "Mesh Utility helps you see how well your LoRa mesh radio network covers an area. Walk or drive around with your radio connected, and the app builds a color-coded map showing where your signal is strong, weak, or missing entirely.",
        ],
      ),
      (
        icon: Icons.bluetooth,
        title: 'Getting Connected',
        content: [
          "Open Settings, switch to the Connections tab, scan for devices, select your radio, then tap Connect.",
          "Only one app can use Bluetooth with your radio at a time. If you have MeshCore or another app connected, close it first.",
          "After connecting, the header shows the connected radio label and current scan status.",
          "If the BLE link drops, the app will attempt reconnect and report status in logs/header.",
        ],
      ),
      (
        icon: Icons.radar_outlined,
        title: 'Scanning',
        content: [
          "With your radio connected, flip the Scan switch to start. The app sends out a discovery signal and listens for any repeaters that respond, measuring how strong and clear each signal is.",
          "Each scan cycle takes about 20 seconds. Your GPS location (and altitude when available) is recorded with each scan so the map knows exactly where you were.",
          "Smart Scan skips areas you've already covered recently (you pick how many days count as \"recent\" in settings). Dead zones are always re-checked regardless. You can also tap Force Scan to override and scan your current spot right away.",
        ],
      ),
      (
        icon: Icons.map_outlined,
        title: 'The Coverage Map',
        content: [
          "The main screen is a map covered with hexagonal zones. Each hex represents a small area where scans were taken, colored by signal quality.",
          "Green means excellent signal. Yellow-green is good. Yellow is fair. Orange is marginal. Red is poor. Dark red means no repeater responded at all (a dead zone). Purple means the signal power is okay but clarity is bad, usually from interference.",
          "Tap any hex to see its details: signal readings, how many scans were taken there, altitude, and which repeaters were heard.",
          "Use the layer control in the top right corner to switch between Dark, Standard, and Satellite map views. The color legend in the upper left shows what each color means (tap it to expand the full scale).",
        ],
      ),
      (
        icon: Icons.battery_std_outlined,
        title: 'Map Overlay',
        content: [
          "While connected, the top header shows your radio label and live scan status.",
          "When smart scan skips a recently-covered zone, the normal countdown is replaced by a skip status message.",
          "The scan toggle button in the overlay lets you start or stop scanning without opening the settings panel.",
        ],
      ),
      (
        icon: Icons.bar_chart_outlined,
        title: 'Bottom Stats Bar',
        content: [
          "At the bottom of the map, a stats bar shows averages for your coverage data: average signal strength (RSSI), average signal clarity (SNR), total zones scanned, and dead zones found.",
          "You can filter these stats by distance using the Stats Radius setting. Set it to a specific number of miles (or kilometers) to only include data near your current position, or set it to 0 to see averages across all your data.",
        ],
      ),
      (
        icon: Icons.signal_cellular_alt,
        title: 'Signal Quality',
        content: [
          "Each scan measures two things: signal power (RSSI) and signal clarity (SNR). The overall quality is whichever of the two is worse.",
          "Excellent means both power and clarity are strong. Good means a reliable connection. Fair is usable with occasional hiccups. Marginal is at the edge of working range. Poor means you're barely picking up anything. A dead zone means no repeater responded at all.",
          "A \"Noisy\" reading (shown in purple) means the radio is picking up decent power but the signal is garbled, often from nearby interference or competing signals.",
        ],
      ),
      (
        icon: Icons.settings_input_antenna,
        title: 'Discovered Nodes',
        content: [
          "The Nodes page lists every repeater your radio has heard during scans. Each entry shows the repeater's name and a short identifier based on its public key.",
          "This list grows automatically as you scan in different areas and discover new repeaters.",
        ],
      ),
      (
        icon: Icons.radar_outlined,
        title: 'Scan History',
        content: [
          "The History page shows a timeline of your recent scans. Each entry includes the signal readings, which repeater responded, your location, altitude, and when the scan happened.",
          "History combines cloud data from the Worker with local cached scans on your device.",
          "Use the Cloud History setting to control how many online days are loaded on the map (from last 7 days up to all days).",
        ],
      ),
      (
        icon: Icons.terrain_outlined,
        title: 'Altitude',
        content: [
          "Your altitude is recorded with each scan. On phones with GPS, it comes directly from the GPS sensor. On desktop or when GPS altitude isn't available, the app estimates it from your coordinates using a free elevation service.",
          "Altitude appears in the map overlay, scan history cards, and zone popups. You can switch between feet and meters in settings.",
        ],
      ),
      (
        icon: Icons.settings_outlined,
        title: 'Settings',
        content: [
          "Scan Interval sets how many seconds between automatic scans (minimum 20 seconds).",
          "Auto-center keeps the map following your position as you move.",
          "Cloud History controls how much worker history is fetched for map/history rendering.",
          "Deadzone Retrieval controls the deadzone fetch window independently from successful scan history.",
          "Update Radio Position is for radios without GPS. It sets the observer radio coordinates to your current OS location so mesh peers can see your position. It only updates the radio coordinates.",
          "Offline map tiles caches viewed tiles. Use Download area tiles to prefetch around your current location and Clear tile cache to purge local tile files.",
          "Units lets you switch between Imperial (feet, miles) and Metric (meters, kilometers).",
          "Stats Radius filters the bottom stats bar to only show data within a certain distance from you. Set to 0 to include everything.",
          "Smart Scanning and the freshness slider control whether the app skips areas scanned within a certain number of days.",
          "Upload Interval controls how often worker sync/upload can run (30 minutes to 24 hours), anchored to internet time.",
          "Clear Scan Cache removes only local cached scans/zones/outbox data on this device.",
        ],
      ),
      (
        icon: Icons.cloud_off_outlined,
        title: 'Online / Offline',
        content: [
          "The app works fully offline after your first visit. Scans, nodes, and coverage data are all stored on your device automatically.",
          "When you lose internet, everything keeps working. Scan results are saved locally and queued up. When connectivity returns, queued items sync to the server automatically.",
          "You can also force offline mode using the toggle in settings. This is handy if you're on a slow or metered connection and want to batch your uploads for later.",
          "Sync behavior is visible in the header and logs, including skipped syncs in offline mode.",
          "If uploads are delayed, keep the app online and use Sync Now from settings to push queued scans immediately.",
        ],
      ),
      (
        icon: Icons.phone_android_outlined,
        title: 'Installing the App',
        content: [
          "Mesh Utility runs as a native Flutter app on Android, Linux, macOS, Windows, iOS, and web builds.",
          "For local development, run `flutter run` from the project root and select your target device.",
          "For web distribution, build the web bundle and host the generated `build/web` output.",
        ],
      ),
      (
        icon: Icons.forum_outlined,
        title: 'Community & Support',
        content: [
          "Join the Mesh Utility Discord server to connect with users, ask questions, and get setup help.",
          "Use the Share button in the sidebar to send the app link to others.",
          "If you find the app useful, the Support link at the top lets you contribute to development.",
        ],
      ),
      (
        icon: Icons.delete_outline,
        title: 'Deleting Your Data',
        content: [
          "Connect your radio and go to Settings. Delete My Data removes all scan results, coverage zones, and records tied to the connected radio.",
          "This is permanent and cannot be undone. It only affects data from that specific radio.",
        ],
      ),
      (
        icon: Icons.warning_amber_outlined,
        title: 'Troubleshooting',
        content: [
          "Can't connect: make sure no other app is using your radio Bluetooth at the same time.",
          "No scans happening: verify location services are on and app permissions are granted.",
          "Map not updating: refresh and check map overlay scan status messages.",
          "If BLE disconnects unexpectedly, leave the app open briefly to allow auto-reconnect, or reconnect manually from Connections.",
        ],
      ),
    ];

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                const Icon(Icons.menu_book),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'How to Use Mesh Utility',
                    style: Theme.of(context).textTheme.headlineSmall,
                    softWrap: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Everything you need to know about mapping your mesh network',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            ...sections.map(
              (section) => Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(section.icon, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              section.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ...section.content.map(
                        (paragraph) => Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            paragraph,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                      if (section.title == 'Community & Support')
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: OutlinedButton.icon(
                            onPressed: _openDiscord,
                            icon: const Icon(Icons.forum_outlined, size: 16),
                            label: const Text('Join Discord'),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
