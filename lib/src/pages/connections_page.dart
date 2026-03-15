import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

final _deviceIdRegex = RegExp(r'\[([^\]]+)\]$');

class ConnectionsPage extends StatelessWidget {
  const ConnectionsPage({
    super.key,
    required this.status,
    required this.connected,
    required this.busy,
    required this.bleUiEnabled,
    required this.results,
    required this.autoConnectEnabled,
    required this.selectedDeviceId,
    required this.onSelectBleDevice,
    required this.onScanDevices,
    required this.onToggleAutoConnect,
    required this.onConnect,
    required this.onDisconnect,
  });

  final String status;
  final bool connected;
  final bool busy;
  final bool bleUiEnabled;
  final List<String> results;
  final bool autoConnectEnabled;
  final String? selectedDeviceId;
  final ValueChanged<String> onSelectBleDevice;
  final Future<void> Function() onScanDevices;
  final ValueChanged<bool> onToggleAutoConnect;
  final Future<void> Function() onConnect;
  final Future<void> Function() onDisconnect;

  @override
  Widget build(BuildContext context) {
    if (!bleUiEnabled) {
      return ListView(
        padding: const EdgeInsets.all(12),
        children: const [
          Text(
            'Connections',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 10),
          Text(
            'Web BLE is unavailable in this browser. Use Android Chrome/Edge (HTTPS or localhost), or Bluefy on iOS.',
          ),
        ],
      );
    }

    final connectedDeviceLabel = _resolveConnectedDeviceLabel();
    final cleanStatus = _cleanStatus(status);
    final statusText = connected
        ? (connectedDeviceLabel ?? 'Device [${selectedDeviceId ?? 'unknown'}]')
        : cleanStatus;
    final isWebPickerFlow = kIsWeb;
    final listRows = connected ? const <String>[] : results;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Connections', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(statusText),
        const SizedBox(height: 8),
        Row(
          children: [
            const Expanded(child: Text('Auto-connect')),
            Switch(
              value: autoConnectEnabled,
              onChanged: kIsWeb ? null : onToggleAutoConnect,
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: (!connected || busy)
                    ? null
                    : () async {
                        _logButton('connections_disconnect');
                        await onDisconnect();
                      },
                icon: const Icon(Icons.bluetooth_disabled),
                label: const Text('Disconnect'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: (busy || connected)
              ? null
              : () async {
                  _logButton(
                    isWebPickerFlow
                        ? 'connections_connect_device'
                        : 'connections_scan_devices',
                  );
                  await onScanDevices();
                },
          icon: const Icon(Icons.bluetooth_searching),
          label: Text(isWebPickerFlow ? 'Connect Device' : 'Scan Devices'),
        ),
        const SizedBox(height: 12),
        if (!connected && isWebPickerFlow) ...[
          Text(
            'Tap Connect Device to open your browser Bluetooth picker.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (!connected && !isWebPickerFlow) ...[
          Text(
            'Devices Found (${listRows.length})',
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
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No devices found. Tap "Scan Devices".'),
                    ),
                  )
                : ListView.builder(
                    itemCount: listRows.length,
                    itemBuilder: (context, index) {
                      final row = listRows[index];
                      final match = _deviceIdRegex.firstMatch(row);
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
                        shape: Border(
                          bottom: BorderSide(
                            color: Theme.of(context).dividerColor,
                            width: 0.5,
                          ),
                        ),
                        trailing: isSelected
                            ? const Icon(Icons.check_circle, size: 16)
                            : null,
                        onTap: (!connected && !busy && deviceId != null)
                            ? () async {
                                _logButton(
                                  'connections_device_select:$deviceId',
                                );
                                _logButton(
                                  'connections_device_connect:$deviceId',
                                );
                                onSelectBleDevice(deviceId);
                                await onConnect();
                              }
                            : null,
                      );
                    },
                  ),
          ),
        ],
      ],
    );
  }

  String? _resolveConnectedDeviceLabel() {
    final selected = selectedDeviceId;
    if (selected == null || selected.isEmpty) return null;
    for (final row in results) {
      final match = _deviceIdRegex.firstMatch(row);
      if (match?.group(1) == selected) return row;
    }
    return 'Device [$selected]';
  }

  String _cleanStatus(String value) {
    final trimmed = value.trim();
    if (trimmed.toLowerCase().startsWith('ble ')) {
      return trimmed.substring(4);
    }
    return trimmed;
  }

  void _logButton(String action) {
    debugPrint('[ui_click] $action');
  }
}
