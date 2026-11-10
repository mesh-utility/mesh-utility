import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/pages/connections_page.dart';

void main() {
  testWidgets('Disconnect stays enabled while connected even when busy', (
    tester,
  ) async {
    var disconnects = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectionsPage(
            status: 'Connected',
            connected: true,
            busy: true,
            bleUiEnabled: true,
            results: const [],
            autoConnectEnabled: false,
            selectedDeviceId: null,
            onSelectBleDevice: (_) {},
            onScanDevices: () async {},
            onToggleAutoConnect: (_) {},
            onConnect: () async {},
            onDisconnect: () async => disconnects++,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Disconnect'));
    await tester.pump();
    expect(disconnects, 1);
  });
}
