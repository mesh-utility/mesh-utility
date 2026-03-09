import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mesh_utility/src/services/app_debug_log_service.dart';
import 'package:mesh_utility/src/services/settings_store.dart';

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
    required this.bleStatus,
    required this.bleScanDevices,
    required this.bleSelectedDeviceId,
    required this.onSelectBleDevice,
    required this.onScanBleDevices,
    required this.onBleConnect,
    required this.onBleDisconnect,
    required this.onBleNodeDiscover,
    required this.debugLogs,
    required this.onClearDebugLogs,
    required this.onClearScanCache,
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
  final String bleStatus;
  final List<String> bleScanDevices;
  final String? bleSelectedDeviceId;
  final ValueChanged<String> onSelectBleDevice;
  final Future<void> Function() onScanBleDevices;
  final Future<void> Function() onBleConnect;
  final Future<void> Function() onBleDisconnect;
  final Future<void> Function() onBleNodeDiscover;
  final List<AppDebugLogEntry> debugLogs;
  final VoidCallback onClearDebugLogs;
  final Future<void> Function() onClearScanCache;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with TickerProviderStateMixin {
  late final TabController _mainController = TabController(
    length: 2,
    vsync: this,
  );

  @override
  void dispose() {
    _mainController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final unitLabel = s.unitSystem == 'metric' ? 'km' : 'miles';
    final radiusDisplay = _radiusDisplayValue(s.statsRadiusMiles, s.unitSystem);
    final syncMeta = _syncMeta(
      count: widget.lastSyncScanCount,
      at: widget.lastSyncAt,
    );
    return SafeArea(
      top: false,
      bottom: true,
      child: Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surface,
            child: TabBar(
              controller: _mainController,
              tabs: const [
                Tab(text: 'General'),
                Tab(text: 'Connections'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _mainController,
              children: [
                ListView(
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
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
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
                                  onChanged: (v) => widget.onChanged(
                                    s.copyWith(smartScanEnabled: v),
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              'Skip zones covered recently to reduce redundant scans.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            Text(
                              'Smart scan freshness days: ${s.smartScanDays}',
                            ),
                            Slider(
                              value: s.smartScanDays.toDouble(),
                              min: 1,
                              max: 14,
                              divisions: 13,
                              label: '${s.smartScanDays}',
                              onChanged: (v) => widget.onChanged(
                                s.copyWith(smartScanDays: v.round()),
                              ),
                            ),
                            Text(
                              'Dead zones always scan at the configured interval, regardless of smart scanning.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 10),
                            FilledButton.tonalIcon(
                              onPressed:
                                  (!widget.bleConnected || widget.bleBusy)
                                  ? null
                                  : widget.onBleNodeDiscover,
                              icon: const Icon(Icons.radar),
                              label: const Text('Node Discover'),
                            ),
                            _SectionDivider(),
                            _AdaptiveSwitchRow(
                              icon: Icons.radio_outlined,
                              label: 'Update radio position',
                              value: s.updateRadioPosition,
                              onChanged: (v) => widget.onChanged(
                                s.copyWith(updateRadioPosition: v),
                              ),
                            ),
                            Text(
                              s.updateRadioPosition
                                  ? 'Radio advert location updates are enabled during scanning.'
                                  : 'Radio advert location updates are disabled.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            _SectionDivider(),
                            _AdaptiveSwitchRow(
                              icon: Icons.download_outlined,
                              label: 'Offline map tiles',
                              value: s.tileCachingEnabled,
                              onChanged: (v) => widget.onChanged(
                                s.copyWith(tileCachingEnabled: v),
                              ),
                            ),
                            Text(
                              s.tileCachingEnabled
                                  ? 'Tile caching is enabled.'
                                  : 'Tile caching is disabled.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: s.tileCachingEnabled
                                        ? () {}
                                        : null,
                                    icon: const Icon(
                                      Icons.map_outlined,
                                      size: 16,
                                    ),
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
                                    onPressed: s.tileCachingEnabled
                                        ? () {}
                                        : null,
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 16,
                                    ),
                                    label: const Text('Clear tile cache'),
                                  ),
                                ),
                              ],
                            ),
                            _SectionDivider(),
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final narrow = constraints.maxWidth < 280;
                                final selector = SegmentedButton<String>(
                                  style: const ButtonStyle(
                                    visualDensity: VisualDensity.compact,
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  segments: const [
                                    ButtonSegment(
                                      value: 'imperial',
                                      label: Text('Imperial'),
                                    ),
                                    ButtonSegment(
                                      value: 'metric',
                                      label: Text('Metric'),
                                    ),
                                  ],
                                  selected: {s.unitSystem},
                                  showSelectedIcon: false,
                                  onSelectionChanged: (value) {
                                    widget.onChanged(
                                      s.copyWith(unitSystem: value.first),
                                    );
                                  },
                                );
                                if (narrow) {
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
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
                                DropdownMenuItem(
                                  value: 'en',
                                  child: Text('English'),
                                ),
                                DropdownMenuItem(
                                  value: 'es',
                                  child: Text('Español'),
                                ),
                                DropdownMenuItem(
                                  value: 'fr',
                                  child: Text('Français'),
                                ),
                                DropdownMenuItem(
                                  value: 'de',
                                  child: Text('Deutsch'),
                                ),
                                DropdownMenuItem(
                                  value: 'pt',
                                  child: Text('Português'),
                                ),
                                DropdownMenuItem(
                                  value: 'zh',
                                  child: Text('中文'),
                                ),
                                DropdownMenuItem(
                                  value: 'ja',
                                  child: Text('日本語'),
                                ),
                                DropdownMenuItem(
                                  value: 'ko',
                                  child: Text('한국어'),
                                ),
                              ],
                              onChanged: (value) {
                                if (value == null) return;
                                widget.onChanged(s.copyWith(language: value));
                              },
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
                            _SectionDivider(),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              isExpanded: true,
                              initialValue: _historyDaysValue(s.historyDays),
                              decoration: const InputDecoration(
                                labelText: 'Cloud History',
                                border: OutlineInputBorder(),
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: '7',
                                  child: Text('Last 7 days'),
                                ),
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
                                DropdownMenuItem(
                                  value: '0',
                                  child: Text('All days'),
                                ),
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
                              decoration: const InputDecoration(
                                labelText: 'Deadzone Retrieval',
                                border: OutlineInputBorder(),
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: '7',
                                  child: Text('Last 7 days'),
                                ),
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
                                DropdownMenuItem(
                                  value: '0',
                                  child: Text('All days'),
                                ),
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
                              min: 5,
                              max: 60,
                              divisions: 11,
                              onChanged: (v) => widget.onChanged(
                                s.copyWith(
                                  uploadBatchIntervalMinutes: v.round(),
                                ),
                              ),
                            ),
                            Text(
                              '${widget.uploadQueueCount} scans queued for upload • ${widget.localScanCount} cached locally',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              syncMeta,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
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
                            _SectionDivider(),
                            const Text(
                              'Dead Zones',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Mark current observer location as a dead zone.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              onPressed: null,
                              icon: const Icon(
                                Icons.warning_amber_rounded,
                                size: 16,
                              ),
                              label: const Text('Mark dead zone'),
                            ),
                            _SectionDivider(),
                            _AdaptiveSwitchRow(
                              icon: s.forceOffline
                                  ? Icons.wifi_off
                                  : Icons.wifi,
                              iconColor: s.forceOffline
                                  ? Colors.orange
                                  : Colors.green,
                              label: s.forceOffline
                                  ? 'Offline Mode'
                                  : 'Online Mode',
                              value: !s.forceOffline,
                              onChanged: (checked) {
                                widget.onChanged(
                                  s.copyWith(forceOffline: !checked),
                                );
                              },
                            ),
                            Text(
                              s.forceOffline
                                  ? 'Forces app to remain offline until disabled.'
                                  : 'Online mode enabled when network is available.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            _SectionDivider(),
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
                            const SizedBox(height: 6),
                            OutlinedButton.icon(
                              onPressed: null,
                              icon: const Icon(Icons.delete_forever, size: 16),
                              label: const Text('Delete radio data'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                Column(
                  children: [
                    Expanded(
                      // TODO(chris): Reintroduce USB/TCP connection panes when
                      // transport UIs are fully wired and tested.
                      child: _ScanResultsConnectionPane(
                        title: 'Bluetooth LE',
                        status: widget.bleStatus,
                        connected: widget.bleConnected,
                        busy: widget.bleBusy,
                        selectedDeviceId: widget.bleSelectedDeviceId,
                        autoConnectEnabled: widget.settings.bleAutoConnect,
                        results: [
                          ...widget.bleScanDevices.map((d) => 'BLE $d'),
                        ],
                        onSelectBleDevice: widget.onSelectBleDevice,
                        onScanDevices: widget.onScanBleDevices,
                        onToggleAutoConnect: (v) => widget.onChanged(
                          widget.settings.copyWith(bleAutoConnect: v),
                        ),
                        onConnect: widget.onBleConnect,
                        onDisconnect: widget.onBleDisconnect,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanResultsConnectionPane extends StatelessWidget {
  const _ScanResultsConnectionPane({
    required this.title,
    required this.status,
    required this.connected,
    required this.busy,
    required this.results,
    this.selectedDeviceId,
    this.autoConnectEnabled = false,
    this.onSelectBleDevice,
    this.onScanDevices,
    this.onToggleAutoConnect,
    this.onConnect,
    this.onDisconnect,
  });

  final String title;
  final String status;
  final bool connected;
  final bool busy;
  final List<String> results;
  final String? selectedDeviceId;
  final bool autoConnectEnabled;
  final ValueChanged<String>? onSelectBleDevice;
  final Future<void> Function()? onScanDevices;
  final ValueChanged<bool>? onToggleAutoConnect;
  final Future<void> Function()? onConnect;
  final Future<void> Function()? onDisconnect;

  @override
  Widget build(BuildContext context) {
    final connectedDeviceLabel = _resolveConnectedDeviceLabel();
    final listRows = connected
        ? (connectedDeviceLabel == null
              ? const <String>[]
              : <String>[connectedDeviceLabel])
        : results;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(status),
        const SizedBox(height: 8),
        if (onToggleAutoConnect != null)
          Row(
            children: [
              const Expanded(child: Text('BLE Auto-connect')),
              Switch(value: autoConnectEnabled, onChanged: onToggleAutoConnect),
            ],
          ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed:
                    (onConnect == null ||
                        connected ||
                        busy ||
                        (selectedDeviceId == null || selectedDeviceId!.isEmpty))
                    ? null
                    : onConnect,
                icon: const Icon(Icons.bluetooth_connected),
                label: const Text('Connect'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: (onDisconnect == null || !connected || busy)
                    ? null
                    : onDisconnect,
                icon: const Icon(Icons.bluetooth_disabled),
                label: const Text('Disconnect'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: (onScanDevices == null || busy || connected)
              ? null
              : onScanDevices,
          icon: const Icon(Icons.bluetooth_searching),
          label: const Text('Scan Devices'),
        ),
        const SizedBox(height: 12),
        Text(
          connected ? 'Connected Device' : 'Devices Found (${listRows.length})',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Container(
          constraints: const BoxConstraints(minHeight: 120, maxHeight: 320),
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(12),
          ),
          child: listRows.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      connected
                          ? 'No connected BLE device'
                          : 'No devices found. Tap "Scan Devices".',
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: listRows.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final row = listRows[index];
                    final match = RegExp(r'\[([^\]]+)\]$').firstMatch(row);
                    final deviceId = match?.group(1);
                    final isSelected =
                        deviceId != null &&
                        selectedDeviceId != null &&
                        selectedDeviceId == deviceId;
                    return ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: const Icon(Icons.bluetooth, size: 18),
                      title: Text(row),
                      selected: isSelected,
                      trailing: isSelected
                          ? const Icon(Icons.check_circle, size: 16)
                          : null,
                      onTap:
                          (!connected &&
                              deviceId != null &&
                              onSelectBleDevice != null)
                          ? () => onSelectBleDevice!(deviceId)
                          : null,
                    );
                  },
                ),
        ),
      ],
    );
  }

  String? _resolveConnectedDeviceLabel() {
    final selected = selectedDeviceId;
    if (selected == null || selected.isEmpty) return null;
    for (final row in results) {
      final match = RegExp(r'\[([^\]]+)\]$').firstMatch(row);
      if (match?.group(1) == selected) return row;
    }
    return 'BLE Device [$selected]';
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
