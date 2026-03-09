import 'package:flutter/material.dart';

class MapTopControls extends StatelessWidget {
  const MapTopControls({
    super.key,
    required this.autoCenter,
    required this.onToggleAutoCenter,
    required this.bleConnected,
    required this.bleBusy,
    required this.bleScanning,
    required this.bleUiEnabled,
    required this.onToggleScan,
    required this.onForceScan,
    required this.syncing,
    required this.forceOffline,
    required this.onSync,
  });

  final bool autoCenter;
  final VoidCallback onToggleAutoCenter;
  final bool bleConnected;
  final bool bleBusy;
  final bool bleScanning;
  final bool bleUiEnabled;
  final VoidCallback onToggleScan;
  final VoidCallback onForceScan;
  final bool syncing;
  final bool forceOffline;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: onToggleAutoCenter,
              icon: Icon(
                autoCenter ? Icons.location_pin : Icons.location_searching,
                size: 18,
              ),
              tooltip: autoCenter ? 'Auto-center on' : 'Auto-center off',
            ),
            if (bleUiEnabled)
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: (!bleConnected || bleBusy) ? null : onToggleScan,
                icon: Icon(
                  bleScanning ? Icons.pause : Icons.play_arrow,
                  size: 18,
                ),
                tooltip: bleScanning ? 'Pause scan loop' : 'Start scan loop',
              ),
            if (bleUiEnabled)
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: (!bleConnected || bleBusy || !bleScanning)
                    ? null
                    : onForceScan,
                icon: const Icon(Icons.flash_on, size: 18),
                tooltip: 'Force scan now',
              ),
            if (syncing)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: forceOffline ? null : onSync,
                icon: const Icon(Icons.sync, size: 18),
                tooltip: forceOffline ? 'Offline mode enabled' : 'Sync',
              ),
          ],
        ),
      ),
    );
  }
}
