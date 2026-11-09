import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/pages/settings_page.dart';
import 'package:mesh_utility/src/services/settings_store.dart';

void main() {
  Future<void> pumpSettings(
    WidgetTester tester, {
    Future<void> Function()? onCheckForUpdates,
    Future<void> Function(AppSettings value)? onChanged,
    String? updateStatusMessage,
    bool updateChecking = false,
    String currentVersionLabel = 'Alpha-18',
  }) async {
    tester.view.physicalSize = const Size(900, 8000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            settings: AppSettings.defaults,
            onChanged: onChanged ?? (_) async {},
            onSync: () async {},
            syncing: false,
            localScanCount: 0,
            uploadQueueCount: 0,
            lastSyncAt: null,
            lastSyncScanCount: 0,
            periodicSyncEnabled: false,
            periodicSyncWaitingForInternetTimeAnchor: false,
            nextPeriodicSyncDueAtUtc: null,
            bleConnected: false,
            bleBusy: false,
            debugLogs: const [],
            onClearDebugLogs: () {},
            onClearScanCache: () async {},
            onDownloadOfflineTiles: () async => 0,
            onClearOfflineTiles: () async {},
            onDeleteRadioData: () async {},
            deleteInProgress: false,
            connectedRadioId: null,
            darkMode: true,
            onToggleTheme: () {},
            currentVersionLabel: currentVersionLabel,
            onCheckForUpdates: onCheckForUpdates,
            updateStatusMessage: updateStatusMessage,
            updateChecking: updateChecking,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('hides update controls when updates are unsupported', (
    tester,
  ) async {
    await pumpSettings(tester);
    expect(find.text('Radio / Connection'), findsOneWidget);
    expect(find.text('Scanning'), findsOneWidget);
    expect(find.text('Map & Display'), findsOneWidget);
    expect(find.text('Data & Cache'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);
    expect(find.text('Sync Download Scope'), findsNothing);
    expect(find.text('History & Sync'), findsNothing);
    expect(find.text('App updates'), findsNothing);
    expect(find.text('Check for updates'), findsNothing);
    expect(find.text('Current version: Alpha-18'), findsOneWidget);
  });

  testWidgets('App updates section shows the current alpha above the button', (
    tester,
  ) async {
    var checks = 0;
    await pumpSettings(
      tester,
      onCheckForUpdates: () async {
        checks += 1;
      },
      updateStatusMessage: 'Up to date (Alpha-18).',
    );

    expect(find.text('App updates'), findsOneWidget);
    expect(find.text('Current version: Alpha-18'), findsOneWidget);
    expect(find.text('Check for updates'), findsOneWidget);
    expect(find.text('Up to date (Alpha-18).'), findsOneWidget);

    final updatesCard = find.ancestor(
      of: find.text('Check for updates'),
      matching: find.byType(Card),
    );
    expect(
      find.descendant(of: updatesCard, matching: find.text('App updates')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: updatesCard,
        matching: find.text('Current version: Alpha-18'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: updatesCard, matching: find.text('Sync now (0)')),
      findsNothing,
    );
    expect(
      find.descendant(of: updatesCard, matching: find.text('Data & Cache')),
      findsNothing,
    );

    await tester.scrollUntilVisible(find.text('Check for updates'), 200);
    await tester.tap(find.text('Check for updates'));
    await tester.pump();
    expect(checks, 1);
  });

  testWidgets('check button shows a busy label while a check is running', (
    tester,
  ) async {
    await pumpSettings(
      tester,
      onCheckForUpdates: () async {},
      updateChecking: true,
    );
    expect(find.text('Checking for updates…'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Checking for updates…'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('Map & Display slider sets the max hex size', (tester) async {
    AppSettings? saved;
    await pumpSettings(
      tester,
      onChanged: (value) async {
        saved = value;
      },
    );

    expect(find.text('Max hex size when zoomed out: ~19.5 mi'), findsOneWidget);
    expect(find.textContaining('cells near the edges'), findsOneWidget);
    final slider = tester.widget<Slider>(
      find.byKey(const Key('maxHexScaleSlider')),
    );
    expect(slider.min, 0);
    expect(slider.max, 8);
    expect(slider.divisions, 8);
    expect(slider.value, 8);
    expect(slider.label, '~19.5 mi');

    slider.onChanged!(0);
    expect(saved, isNotNull);
    expect(saved!.maxHexScale, 1);
    slider.onChanged!(4);
    expect(saved!.maxHexScale, 16);
  });
}
