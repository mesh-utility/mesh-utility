import 'package:flutter/material.dart';
import 'package:mesh_utility/src/platform/web_install_nav.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens [uri] outside the app. Tests pass their own opener.
typedef InstallLinkOpener = Future<void> Function(Uri uri);

/// Android and Linux install steps for the web app.
///
/// Release asset names include the tag (`mesh-utility-Alpha-N-…`), so the
/// page links to the latest-release page instead of a versioned file URL.
class InstallDownloadsPage extends StatelessWidget {
  const InstallDownloadsPage({super.key, this.openLink});

  static const latestReleaseUrl =
      'https://github.com/mesh-utility/mesh-utility/releases/latest';

  /// Workflow names from `.github/workflows/release-artifacts.yml`.
  static const androidAssetPattern = 'mesh-utility-Alpha-N-android.apk';
  static const linuxAssetPattern = 'mesh-utility-Alpha-N-linux-x64.tar.gz';
  static const checksumFileName = 'SHA256SUMS.txt';

  /// Verifies the Linux archive when [checksumFileName] also lists files
  /// that were not downloaded. A plain `sha256sum -c` of the whole file
  /// fails on those missing names.
  static const linuxVerifyCommand =
      "grep -- '-linux-x64.tar.gz' SHA256SUMS.txt | sha256sum -c -";

  /// The published tar has no top-level directory (`tar -C bundle`).
  static const linuxRunCommands =
      'mkdir -p mesh-utility\n'
      'tar -xzf mesh-utility-*-linux-x64.tar.gz -C mesh-utility\n'
      './mesh-utility/mesh_utility';

  final InstallLinkOpener? openLink;

  Future<void> _openLatestRelease() {
    final uri = Uri.parse(latestReleaseUrl);
    final open = openLink;
    if (open != null) return open(uri);
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final body = Theme.of(context).textTheme.bodySmall;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                const Icon(Icons.download_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    webInstallNavLabel,
                    style: Theme.of(context).textTheme.headlineSmall,
                    softWrap: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Android and Linux downloads from the latest release.',
              style: body,
            ),
            const SizedBox(height: 12),
            SelectableText(latestReleaseUrl, style: body),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _openLatestRelease,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Open latest release'),
              ),
            ),
            const SizedBox(height: 12),
            _InstallCard(
              icon: Icons.phone_android_outlined,
              title: 'Android',
              children: [
                Text(
                  'On the latest release page, download $androidAssetPattern. '
                  'N is the release number shown on that page.',
                  style: body,
                ),
                const SizedBox(height: 8),
                Text(
                  'Allow installation from unknown sources. Android asks for '
                  'this when you open the APK. Allow your browser or Files '
                  'app to install unknown apps, then install Mesh Utility.',
                  style: body,
                ),
                const SizedBox(height: 8),
                Text(
                  'Later updates are in Settings, under App updates.',
                  style: body,
                ),
              ],
            ),
            _InstallCard(
              icon: Icons.terminal,
              title: 'Linux',
              children: [
                Text(
                  'On that same page, download $linuxAssetPattern and '
                  '$checksumFileName.',
                  style: body,
                ),
                const SizedBox(height: 8),
                Text(
                  'In the folder that contains both files, verify the '
                  'archive. $checksumFileName lists every file on the '
                  'release. This command checks the Linux archive when it '
                  'is the only file you downloaded:',
                  style: body,
                ),
                const SizedBox(height: 8),
                const _CommandBlock(linuxVerifyCommand),
                const SizedBox(height: 8),
                Text('Extract and run:', style: body),
                const SizedBox(height: 8),
                const _CommandBlock(linuxRunCommands),
                const SizedBox(height: 8),
                Text(
                  'Later updates use the in-app Install update button. Open '
                  'Settings, then App updates, then Check for updates, and '
                  'choose Install update.',
                  style: body,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InstallCard extends StatelessWidget {
  const _InstallCard({
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _CommandBlock extends StatelessWidget {
  const _CommandBlock(this.command);

  final String command;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        command,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.4),
      ),
    );
  }
}
