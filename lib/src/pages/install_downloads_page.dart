import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:mesh_utility/src/platform/web_install_nav.dart';
import 'package:mesh_utility/src/services/release_notes.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens [uri] outside the app. Tests pass their own opener.
typedef InstallLinkOpener = Future<void> Function(Uri uri);

/// Android and Linux install steps for the web app.
///
/// Release asset names include the tag (`mesh-utility-Alpha-N-…`), so the
/// page links to the latest-release page instead of a versioned file URL.
class InstallDownloadsPage extends StatelessWidget {
  const InstallDownloadsPage({super.key, this.openLink, this.httpClient});

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

  /// When null, the page opens its own client for the latest GitHub release.
  final http.Client? httpClient;

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
            _WhatsNewSection(openLink: openLink, httpClient: httpClient),
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

const Key whatsNewLoadingKey = Key('whats-new-loading');
const Key whatsNewFallbackKey = Key('whats-new-fallback');

class _WhatsNewSection extends StatefulWidget {
  const _WhatsNewSection({this.openLink, this.httpClient});

  final InstallLinkOpener? openLink;
  final http.Client? httpClient;

  @override
  State<_WhatsNewSection> createState() => _WhatsNewSectionState();
}

class _WhatsNewSectionState extends State<_WhatsNewSection> {
  http.Client? _ownedClient;
  bool _loading = true;
  bool _usedFallback = false;
  String? _tag;
  String? _htmlUrl;
  ParsedReleaseNotes? _notes;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _ownedClient?.close();
    super.dispose();
  }

  Future<void> _load() async {
    final provided = widget.httpClient;
    final client = provided ?? http.Client();
    if (provided == null) _ownedClient = client;
    final live = await fetchGithubReleaseNotes(client: client);
    if (!mounted) return;
    if (live != null && live.body.trim().isNotEmpty) {
      setState(() {
        _loading = false;
        _usedFallback = false;
        _tag = live.tagName.isEmpty ? null : live.tagName;
        _htmlUrl = live.htmlUrl.isEmpty ? null : live.htmlUrl;
        _notes = parseReleaseNotes(live.body);
      });
      return;
    }
    String? bundled;
    try {
      bundled = await rootBundle.loadString(bundledReleaseNotesAsset);
    } catch (_) {
      bundled = null;
    }
    if (!mounted) return;
    final saved = bundled?.trim();
    setState(() {
      _loading = false;
      _usedFallback = saved != null && saved.isNotEmpty;
      _tag = tagFromReleaseMarkdown(saved);
      _htmlUrl = null;
      _notes = saved == null || saved.isEmpty ? null : parseReleaseNotes(saved);
    });
  }

  Future<void> _openNotes() {
    final raw = (_htmlUrl == null || _htmlUrl!.isEmpty)
        ? InstallDownloadsPage.latestReleaseUrl
        : _htmlUrl!;
    final uri = Uri.parse(raw);
    final open = widget.openLink;
    if (open != null) return open(uri);
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _openItem(ReleaseNoteItem item) {
    final raw = item.url;
    if (raw == null || raw.isEmpty) return Future<void>.value();
    final uri = Uri.tryParse(raw);
    if (uri == null) return Future<void>.value();
    final open = widget.openLink;
    if (open != null) return open(uri);
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final body = Theme.of(context).textTheme.bodySmall;
    final title = _tag == null || _tag!.isEmpty
        ? "What's new"
        : "What's new in $_tag";
    return _InstallCard(
      icon: Icons.new_releases_outlined,
      title: title,
      children: [
        if (_loading)
          const Row(
            key: whatsNewLoadingKey,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 8),
              Expanded(child: Text('Loading release notes…')),
            ],
          ),
        if (_usedFallback)
          Text(
            "Couldn't load the latest notes. Showing the saved copy.",
            key: whatsNewFallbackKey,
            style: body,
          ),
        if (!_loading && _notes != null) ...[
          _NoteGroup(title: 'Fixes', items: _notes!.fixes, onOpen: _openItem),
          _NoteGroup(
            title: 'Enhancements',
            items: _notes!.enhancements,
            onOpen: _openItem,
          ),
          _NoteGroup(
            title: 'Other changes',
            items: _notes!.other,
            onOpen: _openItem,
          ),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _openNotes,
            child: const Text('See release notes on GitHub'),
          ),
        ),
      ],
    );
  }
}

class _NoteGroup extends StatelessWidget {
  const _NoteGroup({
    required this.title,
    required this.items,
    required this.onOpen,
  });

  final String title;
  final List<ReleaseNoteItem> items;
  final Future<void> Function(ReleaseNoteItem item) onOpen;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final body = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          for (final item in items)
            InkWell(
              onTap: item.url == null ? null : () => onOpen(item),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('• ${item.text}', style: body),
              ),
            ),
        ],
      ),
    );
  }
}
