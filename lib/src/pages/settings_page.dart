import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mesh_utility/src/services/app_debug_log_service.dart';
import 'package:mesh_utility/src/services/settings_store.dart';
import 'package:mesh_utility/src/services/tile_cache_service.dart';
import 'package:mesh_utility/src/services/tile_cache_stats.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.onSync,
    required this.syncing,
    required this.localScanCount,
    required this.uploadQueueCount,
    required this.lastSyncAt,
    required this.lastSyncScanCount,
    required this.bleConnected,
    required this.bleBusy,
    required this.debugLogs,
    required this.onClearDebugLogs,
    required this.onClearScanCache,
    required this.onDownloadOfflineTiles,
    required this.onClearOfflineTiles,
    required this.onDeleteRadioData,
    required this.deleteInProgress,
    required this.connectedRadioId,
    required this.darkMode,
    required this.onToggleTheme,
  });

  final AppSettings settings;
  final Future<void> Function(AppSettings value) onChanged;
  final Future<void> Function() onSync;
  final bool syncing;
  final int localScanCount;
  final int uploadQueueCount;
  final DateTime? lastSyncAt;
  final int lastSyncScanCount;

  final bool bleConnected;
  final bool bleBusy;
  final List<AppDebugLogEntry> debugLogs;
  final VoidCallback onClearDebugLogs;
  final Future<void> Function() onClearScanCache;
  final Future<int> Function() onDownloadOfflineTiles;
  final Future<void> Function() onClearOfflineTiles;
  final Future<void> Function() onDeleteRadioData;
  final bool deleteInProgress;
  final String? connectedRadioId;
  final bool darkMode;
  final VoidCallback onToggleTheme;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _tileOpInProgress = false;
  bool _tileStatsLoading = false;
  TileCacheStats? _tileCacheStats;

  @override
  void initState() {
    super.initState();
    _loadTileCacheStats();
  }

  Future<void> _loadTileCacheStats() async {
    if (_tileStatsLoading) return;
    setState(() => _tileStatsLoading = true);
    try {
      final stats = await TileCacheService.getCacheStats();
      if (!mounted) return;
      setState(() => _tileCacheStats = stats);
    } finally {
      if (mounted) {
        setState(() => _tileStatsLoading = false);
      }
    }
  }

  Future<void> _handleDeleteRadioData() async {
    final id = (widget.connectedRadioId ?? '').trim();
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Delete'),
        content: Text(
          id.isEmpty
              ? 'Delete all data recorded by this connected radio? This cannot be undone.'
              : 'Delete all data recorded by radio $id? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;

    try {
      await widget.onDeleteRadioData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Delete request completed.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }

  Future<void> _handleDownloadTiles() async {
    if (_tileOpInProgress) return;
    setState(() => _tileOpInProgress = true);
    try {
      final count = await widget.onDownloadOfflineTiles();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Downloaded $count tile(s) for offline use.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Tile download failed: $e')));
    } finally {
      if (mounted) {
        setState(() => _tileOpInProgress = false);
      }
      await _loadTileCacheStats();
    }
  }

  Future<void> _handleClearTiles() async {
    if (_tileOpInProgress) return;
    setState(() => _tileOpInProgress = true);
    try {
      await widget.onClearOfflineTiles();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Offline tile cache cleared.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Clear tile cache failed: $e')));
    } finally {
      if (mounted) {
        setState(() => _tileOpInProgress = false);
      }
      await _loadTileCacheStats();
    }
  }

  String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    if (bytes <= 0) return '0 B';
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit += 1;
    }
    final decimals = value >= 10 || unit == 0 ? 0 : 1;
    return '${value.toStringAsFixed(decimals)} ${units[unit]}';
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final unitLabel = s.unitSystem == 'metric' ? 'km' : 'miles';
    final pickerLabelStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
      color: Theme.of(context).colorScheme.onSurface,
    );
    final pickerFloatingLabelStyle = Theme.of(context).textTheme.bodySmall
        ?.copyWith(
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.primary,
        );
    final radiusDisplay = _radiusDisplayValue(s.statsRadiusMiles, s.unitSystem);
    final syncMeta = _syncMeta(
      count: widget.lastSyncScanCount,
      at: widget.lastSyncAt,
    );
    return SafeArea(
      top: false,
      bottom: true,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(
            'General Settings',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          Text(
            'Backend endpoint is managed internally for production and is not user-configurable.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Card(
            elevation: 3,
            shadowColor: Theme.of(
              context,
            ).colorScheme.shadow.withValues(alpha: 0.28),
            surfaceTintColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.06),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(
                color: Theme.of(
                  context,
                ).colorScheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _CardSectionHeader(
                    title: 'Scanning',
                    icon: Icons.radar_outlined,
                  ),
                  const SizedBox(height: 12),
                  _SectionTitle(
                    icon: Icons.timer_outlined,
                    label: 'Scan Interval: ${s.scanIntervalSeconds}s',
                  ),
                  Slider(
                    value: s.scanIntervalSeconds.toDouble(),
                    min: 20,
                    max: 300,
                    divisions: 28,
                    label: '${s.scanIntervalSeconds}',
                    onChanged: (v) => widget.onChanged(
                      s.copyWith(scanIntervalSeconds: v.round()),
                    ),
                  ),
                  Text(
                    'Minimum delay between automatic scan cycles.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  _SectionDivider(),
                  Row(
                    children: [
                      const Expanded(child: Text('Smart scan')),
                      Switch(
                        value: s.smartScanEnabled,
                        onChanged: (v) =>
                            widget.onChanged(s.copyWith(smartScanEnabled: v)),
                      ),
                    ],
                  ),
                  Text(
                    'Skip zones covered recently to reduce redundant scans.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text('Smart scan freshness days: ${s.smartScanDays}'),
                  Slider(
                    value: s.smartScanDays.toDouble(),
                    min: 1,
                    max: 14,
                    divisions: 13,
                    label: '${s.smartScanDays}',
                    onChanged: (v) =>
                        widget.onChanged(s.copyWith(smartScanDays: v.round())),
                  ),
                  Text(
                    'Dead zones always scan at the configured interval, regardless of smart scanning.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            elevation: 3,
            shadowColor: Theme.of(
              context,
            ).colorScheme.shadow.withValues(alpha: 0.28),
            surfaceTintColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.06),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(
                color: Theme.of(
                  context,
                ).colorScheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _CardSectionHeader(
                    title: 'Map & Radio',
                    icon: Icons.map_outlined,
                  ),
                  const SizedBox(height: 12),
                  _AdaptiveSwitchRow(
                    icon: Icons.radio_outlined,
                    label: 'Update radio position',
                    value: s.updateRadioPosition,
                    onChanged: (v) =>
                        widget.onChanged(s.copyWith(updateRadioPosition: v)),
                  ),
                  Text(
                    s.updateRadioPosition
                        ? 'Radio coordinate updates are enabled.'
                        : 'Radio coordinate updates are disabled.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text(
                    'For radios without GPS, this sets the observer radio coordinates to your current OS location so mesh peers can see your position. It only updates the radio coordinates.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  _SectionDivider(),
                  _AdaptiveSwitchRow(
                    icon: Icons.download_outlined,
                    label: 'Offline map tiles',
                    value: s.tileCachingEnabled,
                    onChanged: (v) =>
                        widget.onChanged(s.copyWith(tileCachingEnabled: v)),
                  ),
                  Text(
                    s.tileCachingEnabled
                        ? 'Viewed tiles are cached and offline tile actions are enabled.'
                        : 'Tile caching is disabled.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  if (_tileStatsLoading && _tileCacheStats == null)
                    const Text('Tile cache usage: loading...')
                  else if ((_tileCacheStats?.supported ?? false))
                    Text(
                      'Cached tiles: ${_tileCacheStats?.tileCount ?? 0}  •  Size: ${_formatBytes(_tileCacheStats?.totalBytes ?? 0)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    )
                  else
                    Text(
                      'Tile cache usage is unavailable on this platform.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed:
                              (!s.tileCachingEnabled || _tileOpInProgress)
                              ? null
                              : _handleDownloadTiles,
                          icon: const Icon(Icons.map_outlined, size: 16),
                          label: const Text('Download area tiles'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _tileOpInProgress
                              ? null
                              : _handleClearTiles,
                          icon: const Icon(Icons.delete_outline, size: 16),
                          label: const Text('Clear tile cache'),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    'Download area tiles prefetches map tiles around your current OS location.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  _SectionDivider(),
                  _SectionTitle(
                    icon: Icons.radar_outlined,
                    label:
                        'Stats Radius: ${radiusDisplay == 0 ? 'All map' : '$radiusDisplay $unitLabel'}',
                  ),
                  Slider(
                    value: radiusDisplay.toDouble(),
                    min: 0,
                    max: 1000,
                    divisions: 200,
                    onChanged: (v) => widget.onChanged(
                      s.copyWith(
                        statsRadiusMiles: _toMilesRadius(
                          v.round(),
                          s.unitSystem,
                        ),
                      ),
                    ),
                  ),
                  Text(
                    radiusDisplay == 0
                        ? 'Include all scans in visible map bounds.'
                        : 'Limit map stats to $radiusDisplay $unitLabel radius.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            elevation: 3,
            shadowColor: Theme.of(
              context,
            ).colorScheme.shadow.withValues(alpha: 0.28),
            surfaceTintColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.06),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(
                color: Theme.of(
                  context,
                ).colorScheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _CardSectionHeader(title: 'Display', icon: Icons.tune),
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final narrow = constraints.maxWidth < 280;
                      final selector = SegmentedButton<String>(
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        segments: const [
                          ButtonSegment(
                            value: 'imperial',
                            label: Text('Imperial'),
                          ),
                          ButtonSegment(value: 'metric', label: Text('Metric')),
                        ],
                        selected: {s.unitSystem},
                        showSelectedIcon: false,
                        onSelectionChanged: (value) {
                          widget.onChanged(s.copyWith(unitSystem: value.first));
                        },
                      );
                      if (narrow) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.straighten, size: 14),
                                SizedBox(width: 8),
                                Text('Units'),
                              ],
                            ),
                            const SizedBox(height: 8),
                            selector,
                          ],
                        );
                      }
                      return Row(
                        children: [
                          const Icon(Icons.straighten, size: 14),
                          const SizedBox(width: 8),
                          const Text('Units'),
                          const Spacer(),
                          selector,
                        ],
                      );
                    },
                  ),
                  _SectionDivider(),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: s.language,
                    decoration: const InputDecoration(
                      labelText: 'Language',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'en', child: Text('English')),
                      DropdownMenuItem(value: 'es', child: Text('Español')),
                      DropdownMenuItem(value: 'fr', child: Text('Français')),
                      DropdownMenuItem(value: 'de', child: Text('Deutsch')),
                      DropdownMenuItem(value: 'pt', child: Text('Português')),
                      DropdownMenuItem(value: 'zh', child: Text('中文')),
                      DropdownMenuItem(value: 'ja', child: Text('日本語')),
                      DropdownMenuItem(value: 'ko', child: Text('한국어')),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      widget.onChanged(s.copyWith(language: value));
                    },
                  ),
                  _SectionDivider(),
                  OutlinedButton.icon(
                    onPressed: widget.onToggleTheme,
                    icon: Icon(
                      widget.darkMode
                          ? Icons.dark_mode_outlined
                          : Icons.light_mode_outlined,
                      size: 16,
                    ),
                    label: Text(
                      widget.darkMode
                          ? 'Theme: Dark (tap for Light)'
                          : 'Theme: Light (tap for Dark)',
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Map default follows app theme: Light = Standard, Dark = Carto. '
                    'You can still change map layer manually.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            elevation: 3,
            shadowColor: Theme.of(
              context,
            ).colorScheme.shadow.withValues(alpha: 0.28),
            surfaceTintColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.06),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(
                color: Theme.of(
                  context,
                ).colorScheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _CardSectionHeader(
                    title: 'History & Sync',
                    icon: Icons.sync,
                  ),
                  const SizedBox(height: 12),
                  _AdaptiveSwitchRow(
                    icon: s.forceOffline ? Icons.cloud_off : Icons.cloud,
                    iconColor: s.forceOffline ? Colors.orange : Colors.green,
                    label: s.forceOffline ? 'Offline Mode' : 'Online Mode',
                    value: !s.forceOffline,
                    onChanged: (checked) {
                      widget.onChanged(s.copyWith(forceOffline: !checked));
                    },
                  ),
                  Text(
                    s.forceOffline
                        ? 'Offline mode is ON. Sync with the online database is paused. '
                              'Turn Offline Mode off to see worldwide scan data and contribute.'
                        : 'Online mode is enabled. You can sync and contribute scan data worldwide. '
                              'Turn Offline Mode on to pause cloud sync.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (s.forceOffline) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Online mode requires accepted Privacy Policy.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  _SectionDivider(),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _historyDaysValue(s.historyDays),
                    decoration: InputDecoration(
                      labelText: 'Cloud History',
                      labelStyle: pickerLabelStyle,
                      floatingLabelStyle: pickerFloatingLabelStyle,
                      border: const OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: '7', child: Text('Last 7 days')),
                      DropdownMenuItem(
                        value: '14',
                        child: Text('Last 14 days'),
                      ),
                      DropdownMenuItem(
                        value: '30',
                        child: Text('Last 30 days'),
                      ),
                      DropdownMenuItem(
                        value: '60',
                        child: Text('Last 60 days'),
                      ),
                      DropdownMenuItem(
                        value: '90',
                        child: Text('Last 90 days'),
                      ),
                      DropdownMenuItem(
                        value: '180',
                        child: Text('Last 180 days'),
                      ),
                      DropdownMenuItem(
                        value: '270',
                        child: Text('Last 270 days'),
                      ),
                      DropdownMenuItem(
                        value: '365',
                        child: Text('Last 365 days'),
                      ),
                      DropdownMenuItem(value: '0', child: Text('All days')),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      widget.onChanged(
                        s.copyWith(historyDays: int.parse(value)),
                      );
                    },
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Controls how many online history days are loaded on the map.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _historyDaysValue(s.deadzoneDays),
                    decoration: InputDecoration(
                      labelText: 'Deadzone Retrieval',
                      labelStyle: pickerLabelStyle,
                      floatingLabelStyle: pickerFloatingLabelStyle,
                      border: const OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: '7', child: Text('Last 7 days')),
                      DropdownMenuItem(
                        value: '14',
                        child: Text('Last 14 days'),
                      ),
                      DropdownMenuItem(
                        value: '30',
                        child: Text('Last 30 days'),
                      ),
                      DropdownMenuItem(
                        value: '60',
                        child: Text('Last 60 days'),
                      ),
                      DropdownMenuItem(
                        value: '90',
                        child: Text('Last 90 days'),
                      ),
                      DropdownMenuItem(
                        value: '180',
                        child: Text('Last 180 days'),
                      ),
                      DropdownMenuItem(
                        value: '270',
                        child: Text('Last 270 days'),
                      ),
                      DropdownMenuItem(
                        value: '365',
                        child: Text('Last 365 days'),
                      ),
                      DropdownMenuItem(value: '0', child: Text('All days')),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      widget.onChanged(
                        s.copyWith(deadzoneDays: int.parse(value)),
                      );
                    },
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Controls deadzone fetch window without changing successful scan history range.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  _SectionDivider(),
                  _SectionTitle(
                    icon: Icons.sync,
                    label:
                        'Upload Interval: ${s.uploadBatchIntervalMinutes} min',
                  ),
                  Slider(
                    value: s.uploadBatchIntervalMinutes.toDouble(),
                    min: 30,
                    max: 1440,
                    divisions: 47,
                    onChanged: (v) => widget.onChanged(
                      s.copyWith(
                        uploadBatchIntervalMinutes: ((v / 30).round() * 30)
                            .clamp(30, 1440),
                      ),
                    ),
                  ),
                  Text(
                    '${widget.uploadQueueCount} scans queued for upload • ${widget.localScanCount} cached locally',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  Text(syncMeta, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: (widget.syncing || s.forceOffline)
                        ? null
                        : widget.onSync,
                    icon: const Icon(Icons.sync, size: 16),
                    label: Text(
                      s.forceOffline
                          ? 'Sync disabled (Offline Mode)'
                          : widget.syncing
                          ? 'Syncing...'
                          : 'Sync now (${widget.uploadQueueCount})',
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Downloaded scans are marked read-only and excluded from upload queue.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            elevation: 3,
            shadowColor: Theme.of(
              context,
            ).colorScheme.shadow.withValues(alpha: 0.28),
            surfaceTintColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.06),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(
                color: Theme.of(
                  context,
                ).colorScheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _CardSectionHeader(
                    title: 'Data Management',
                    icon: Icons.storage_outlined,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Clear Local Data',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    onPressed: widget.onClearScanCache,
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('Clear Scan Cache'),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Delete My Data',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Connect to a radio to enable signed delete request.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if ((widget.connectedRadioId ?? '').trim().isNotEmpty)
                    Text(
                      'Connected radio ID: ${widget.connectedRadioId}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  const SizedBox(height: 6),
                  OutlinedButton.icon(
                    onPressed:
                        (!widget.bleConnected ||
                            widget.bleBusy ||
                            widget.deleteInProgress)
                        ? null
                        : _handleDeleteRadioData,
                    icon: const Icon(Icons.delete_forever, size: 16),
                    label: Text(
                      widget.deleteInProgress
                          ? 'Deleting...'
                          : 'Delete radio data',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          icon,
          size: 14,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _CardSectionHeader extends StatelessWidget {
  const _CardSectionHeader({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: Theme.of(context).colorScheme.primary,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _AdaptiveSwitchRow extends StatelessWidget {
  const _AdaptiveSwitchRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.iconColor,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 260;
        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 14, color: iconColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Switch(value: value, onChanged: onChanged),
              ),
            ],
          );
        }

        return Row(
          children: [
            Icon(icon, size: 14, color: iconColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            Switch(value: value, onChanged: onChanged),
          ],
        );
      },
    );
  }
}

class _SectionDivider extends StatelessWidget {
  const _SectionDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 10),
      child: Divider(height: 1),
    );
  }
}

String _historyDaysValue(int value) {
  const allowed = <int>{0, 7, 14, 30, 60, 90, 180, 270, 365};
  if (allowed.contains(value)) return '$value';
  return '7';
}

int _radiusDisplayValue(int miles, String unitSystem) {
  if (unitSystem == 'metric') {
    return (miles * 1.60934).round();
  }
  return miles;
}

int _toMilesRadius(int displayValue, String unitSystem) {
  if (displayValue <= 0) return 0;
  if (unitSystem == 'metric') {
    return (displayValue / 1.60934).round();
  }
  return displayValue;
}

String _syncMeta({required int count, required DateTime? at}) {
  if (at == null) return 'No completed sync yet';
  final formatted = DateFormat.yMd().add_jm().format(at.toLocal());
  return 'Last sync: $formatted • $count scans fetched';
}
