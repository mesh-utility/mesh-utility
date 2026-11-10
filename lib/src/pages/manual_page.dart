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

  static const _sections = <({IconData icon, String title, List<String> content})>[
    (
      icon: Icons.help_outline,
      title: 'What Is Mesh Utility?',
      content: [
        'Mesh Utility helps you see how well your LoRa mesh radio network covers an area. Walk or drive around with your radio connected, and the app builds a color-coded map showing where your signal is strong, weak, or missing entirely.',
      ],
    ),
    (
      icon: Icons.bluetooth,
      title: 'Getting Connected',
      content: [
        'Open the Connections page in the left sidebar, scan for devices, select your radio, then tap Connect.',
        'Only one app can use Bluetooth with your radio at a time. If you have MeshCore or another app connected, close it first.',
        'If another app has the radio, Mesh Utility will not take it. Close the other app or disconnect there, then tap Connect here.',
        'After connecting, the header shows the connected radio label and current scan status.',
        'If the BLE link drops, the app will attempt reconnect and report status in logs/header.',
      ],
    ),
    (
      icon: Icons.radar_outlined,
      title: 'Scanning',
      content: [
        'With your radio connected, use Play on the map to start the scan loop and Pause to stop it. Each cycle sends a discovery signal and listens for repeaters.',
        'On Android, leave the scan loop running when you turn the screen off or leave the app. A scanning notification stays up, including while the app reconnects to the radio. The loop keeps going after the radio comes back. Pausing the loop or disconnecting the radio stops that.',
        'The first time you start the loop, if Android is still optimizing Mesh Utility\'s battery, the app asks once. Allow opens the system prompt so the phone does not cut the radio link after a few minutes. Not now dismisses it and does not ask again. Settings, under Scanning, shows Battery optimization: Unrestricted or Optimized, with a button to allow the exemption or open settings.',
        'The countdown starts as soon as a scan is sent. It does not wait for the radio to answer.',
        'Scan Interval (Settings, under Scanning) is how many seconds the loop waits between scans, from 20 to 300. Your GPS location, and altitude when the phone has it, is stored with each scan.',
        'Force scan is the bolt button. It needs the scan loop running. Tap Play first, then the bolt, to scan your current spot now. That also restarts the countdown.',
        'Smart scan skips areas you covered recently. You pick how many days count as recent. Dead zones are always scanned again.',
      ],
    ),
    (
      icon: Icons.map_outlined,
      title: 'The Coverage Map',
      content: [
        'The main screen is a map covered with hexagonal zones. Each hex represents a small area where scans were taken, colored by signal quality.',
        'The map opens on a general view until you allow location. It then centers on this device.',
        'Approximate general coverage appears as faint large hexes as soon as the map opens, including before the first Sync. Sync or zoom in for the detailed hexes.',
        'Green means excellent signal. Yellow-green is good. Yellow is fair. Orange is marginal. Red is poor. Dark red means no repeater responded at all (a dead zone). Purple means the signal power is okay but clarity is bad, usually from interference.',
        'Tap any hex to see its details: signal readings, how many scans were taken there, altitude, and which repeaters were heard. Long names and messages wrap onto up to three lines so the full text stays readable on a small phone.',
        'Use the layer control in the top right corner to switch between Dark, Standard, and Satellite map views. The color legend sits in the lower-right area of the map (tap it to expand the full scale).',
      ],
    ),
    (
      icon: Icons.battery_std_outlined,
      title: 'Map Overlay',
      content: [
        'While connected, the top header shows your radio label and live scan status.',
        'When smart scan skips a recently-covered zone, the normal countdown is replaced by a skip status message.',
        'The scan toggle button in the overlay lets you start or stop scanning without opening the settings panel.',
      ],
    ),
    (
      icon: Icons.bar_chart_outlined,
      title: 'Bottom Stats Bar',
      content: [
        'At the bottom of the map, a stats bar shows averages for your coverage data: average signal strength (RSSI), average signal clarity (SNR), total zones scanned, and dead zones found.',
        'You can filter these stats by distance using the Stats Radius setting. Set it to a specific number of miles (or kilometers) to only include data near your current position, or set it to 0 to see averages across all your data.',
      ],
    ),
    (
      icon: Icons.signal_cellular_alt,
      title: 'Signal Quality',
      content: [
        'Each scan measures two things: signal power (RSSI) and signal clarity (SNR). The overall quality is whichever of the two is worse.',
        "Excellent means both power and clarity are strong. Good means a reliable connection. Fair is usable with occasional hiccups. Marginal is at the edge of working range. Poor means you're barely picking up anything. A dead zone means no repeater responded at all.",
        'A "Noisy" reading (shown in purple) means the radio is picking up decent power but the signal is garbled, often from nearby interference or competing signals.',
      ],
    ),
    (
      icon: Icons.settings_input_antenna,
      title: 'Discovered Nodes',
      content: [
        "The Nodes page lists every repeater your radio has heard during scans. Each entry shows the repeater's name and a short identifier based on its public key.",
        'This list grows automatically as you scan in different areas and discover new repeaters.',
      ],
    ),
    (
      icon: Icons.radar_outlined,
      title: 'Scan History',
      content: [
        'The History page lists recent scans. Each row shows the signal, which repeater answered, where you were, altitude, and the time.',
        'A radio name ending in "· synced" means that row was recorded by a different radio than the one connected now. Those are shared scans, usually from the cloud, not a scan this connected radio just made.',
        'On the map, tap a hex and choose View History. The title says Cell history, and that list scrolls.',
        'History with no cell selected is titled All Scans. A single row is labeled "1 scan".',
        'Cloud History, under Data & Cache, sets how many online days load (from the last 7 days up to all days).',
      ],
    ),
    (
      icon: Icons.terrain_outlined,
      title: 'Altitude',
      content: [
        "Your altitude is recorded with each scan. On phones with GPS, it comes directly from the GPS sensor. On desktop or when GPS altitude isn't available, the app estimates it from your coordinates using a free elevation service.",
        'Altitude appears in the map overlay, scan history cards, and zone popups. You can switch between feet and meters in settings.',
      ],
    ),
    (
      icon: Icons.settings_outlined,
      title: 'Settings',
      content: [
        'Settings is grouped into Radio / Connection, Scanning, Map & Display, Data & Cache, App updates, and About.',
        'Radio / Connection has Update radio position and Online / Offline Mode. Update radio position is for a radio without GPS. It writes your current location onto the radio so peers can see it. It only updates the radio coordinates.',
        'Scanning has Scan Interval and Smart scan. On Android it also shows battery optimization, Unrestricted or Optimized, with a button to allow an exemption or open settings. Unrestricted is what lets the scan loop keep the radio connected with the screen off.',
        'Map & Display has offline map tiles, Stats Radius, units, and theme. Coverage hexes stay at true size on the fixed grid at every zoom.',
        'Offline map tiles stores tiles you have viewed. Download area tiles fetches tiles around you. Clear tile cache deletes them.',
        'Data & Cache > Scan cache area limits what is downloaded and kept. Radius is 10, 25, 50, 100, 250, 500, or 800 miles around your last location. States and provinces is one list: expand a country to its states or provinces. Select all on a country selects every state or province under it. A dash means only some are selected. Counties uses the same kind of list for the United States: country, then state, then county. Select all on the United States or on a state selects those counties. Other countries do not have county outlines in this build. Search still filters the list. Global keeps every place. Changing the area downloads the new area, or trims scans that no longer fit. A larger area uses more storage and can slow startup.',
        'Cloud History and Deadzone Retrieval are also under Data & Cache. Upload Interval is how often sync can run (30 minutes to 24 hours), using internet time. Clear Scan Cache removes only this device\'s cached scans.',
        'App updates is shown on Android and Linux. About shows the version on the other platforms.',
        'Stats Radius filters the bottom stats bar. Set it to 0 to include everything. Units switches feet and miles, or meters and kilometers.',
      ],
    ),
    (
      icon: Icons.cloud_off_outlined,
      title: 'Online / Offline',
      content: [
        'The app supports offline scanning and queueing. Network history/coverage data is fetched as needed, while local upload-queue scans are kept on-device.',
        'When you lose internet, scanning still works. Local results are queued for upload, and queued items sync automatically when connectivity returns.',
        "You can also force offline mode using the toggle in settings. This is handy if you're on a slow or metered connection and want to batch your uploads for later.",
        'Sync uploads your own scans and refreshes map tiles for the view you are on. It does not bulk-download the world. Download coverage pack pulls an offline copy for the Scan cache area you picked. History can still export a CSV of what you have locally.',
        'If uploads are delayed, keep the app online and use Sync Now from settings to push queued scans immediately.',
      ],
    ),
    (
      icon: Icons.phone_android_outlined,
      title: 'Installing the App',
      content: [
        'On the web app, open the Install tab. It explains the Android APK, the Linux build, and Obtainium, and it shows what is in the latest release.',
        'On Android and Linux, later updates are in Settings, under App updates.',
      ],
    ),
    (
      icon: Icons.forum_outlined,
      title: 'Community & Support',
      content: [
        'Join the Mesh Utility Discord server to connect with users, ask questions, and get setup help.',
        'Use the Share button in the sidebar to send the app link to others.',
        'If you find the app useful, the Support link at the top lets you contribute to development.',
      ],
    ),
    (
      icon: Icons.delete_outline,
      title: 'Deleting Your Data',
      content: [
        'Connect your radio and go to Settings. Delete My Data removes all scan results, coverage zones, and records tied to the connected radio.',
        'This is permanent and cannot be undone. It only affects data from that specific radio.',
      ],
    ),
    (
      icon: Icons.warning_amber_outlined,
      title: 'Troubleshooting',
      content: [
        "Can't connect: make sure no other app is using your radio Bluetooth at the same time.",
        'No scans happening: verify location services are on and app permissions are granted.',
        'Map not updating: refresh and check map overlay scan status messages.',
        'If the radio disconnects while the scan loop is on, the app keeps reconnecting on its own, including with the screen off. Pausing the loop or disconnecting from Connections stops those retries.',
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: _sections.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
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
                ],
              );
            }

            final section = _sections[index - 1];
            return Card(
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
                            style: const TextStyle(fontWeight: FontWeight.w600),
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
            );
          },
        ),
      ),
    );
  }
}
