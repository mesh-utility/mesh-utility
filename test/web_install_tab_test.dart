import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/main.dart';
import 'package:mesh_utility/src/pages/install_downloads_page.dart';
import 'package:mesh_utility/src/platform/web_install_nav.dart';

void main() {
  test('install tab visibility follows kIsWeb unless a test passes isWeb', () {
    expect(webInstallNavVisible(isWeb: true), isTrue);
    expect(webInstallNavVisible(isWeb: false), isFalse);
    // Widget tests run on the VM, so the production path follows kIsWeb.
    expect(webInstallNavVisible(), isFalse);
  });

  testWidgets('side nav shows Install on web and opens the download page', (
    tester,
  ) async {
    await _pumpShell(tester, isWeb: true);

    expect(find.byKey(webInstallNavKey), findsOneWidget);
    expect(find.text(webInstallNavLabel), findsOneWidget);
    expect(
      find.textContaining('Allow installation from unknown sources'),
      findsNothing,
    );

    await tester.tap(find.byKey(webInstallNavKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.textContaining('Allow installation from unknown sources'),
      findsOneWidget,
    );
    expect(find.text(InstallDownloadsPage.linuxVerifyCommand), findsOneWidget);
    expect(find.textContaining('choose Install update'), findsOneWidget);
  });

  testWidgets('side nav omits Install on native, including the kIsWeb path', (
    tester,
  ) async {
    await _pumpShell(tester);
    expect(find.byKey(webInstallNavKey), findsNothing);
    expect(find.text(webInstallNavLabel), findsNothing);
    expect(find.text(InstallDownloadsPage.linuxVerifyCommand), findsNothing);
    expect(
      find.textContaining('Allow installation from unknown sources'),
      findsNothing,
    );

    await _pumpShell(tester, isWeb: false);
    expect(find.byKey(webInstallNavKey), findsNothing);
    expect(find.text(webInstallNavLabel), findsNothing);
  });

  testWidgets('narrow web shell keeps Install in the drawer', (tester) async {
    await _pumpShell(tester, isWeb: true, size: const Size(400, 800));

    expect(find.byKey(webInstallNavKey), findsNothing);
    await tester.tap(find.byTooltip('Menu'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(webInstallNavKey), findsOneWidget);
    expect(find.text(webInstallNavLabel), findsOneWidget);
  });

  testWidgets('install page describes Android and Linux downloads', (
    tester,
  ) async {
    await _pumpPage(tester, const Size(800, 2200));

    expect(find.text(webInstallNavLabel), findsOneWidget);
    expect(find.text('Android'), findsOneWidget);
    expect(find.text('Linux'), findsOneWidget);
    expect(find.text(InstallDownloadsPage.latestReleaseUrl), findsOneWidget);
    expect(
      find.textContaining(InstallDownloadsPage.androidAssetPattern),
      findsOneWidget,
    );
    expect(
      find.textContaining(InstallDownloadsPage.linuxAssetPattern),
      findsOneWidget,
    );
    expect(
      find.textContaining(InstallDownloadsPage.checksumFileName),
      findsWidgets,
    );
    expect(find.text(InstallDownloadsPage.linuxVerifyCommand), findsOneWidget);
    expect(find.text(InstallDownloadsPage.linuxRunCommands), findsOneWidget);
    expect(find.textContaining('sha256sum -c'), findsOneWidget);
    expect(
      find.textContaining('Allow installation from unknown sources'),
      findsOneWidget,
    );
    expect(find.textContaining('Settings, under App updates'), findsOneWidget);
    expect(find.textContaining('Install update'), findsOneWidget);
    expect(find.textContaining('Windows'), findsNothing);
    expect(find.textContaining('windows'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('install page opens the stable latest-release link', (
    tester,
  ) async {
    final opened = <Uri>[];
    await _pumpPage(
      tester,
      const Size(800, 900),
      openLink: (uri) async {
        opened.add(uri);
      },
    );

    await tester.tap(find.text('Open latest release'));
    await tester.pump();

    expect(opened, hasLength(1));
    expect(opened.single.toString(), InstallDownloadsPage.latestReleaseUrl);
    expect(opened.single.path, '/mesh-utility/mesh-utility/releases/latest');
  });

  testWidgets('install page lays out on a narrow phone width', (tester) async {
    await _pumpPage(tester, const Size(360, 2400));

    expect(find.text('Open latest release'), findsOneWidget);
    expect(find.text('Extract and run:'), findsOneWidget);
    expect(find.textContaining('choose Install update'), findsOneWidget);
    expect(find.text(InstallDownloadsPage.latestReleaseUrl), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpShell(
  WidgetTester tester, {
  bool? isWeb,
  Size size = const Size(1280, 1600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(MeshUtilityApp(isWeb: isWeb));
  await tester.pump();

  for (var i = 0; i < 25; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    final skip = find.text('Skip (Offline Only)');
    if (skip.evaluate().isNotEmpty) {
      await tester.tap(skip);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      break;
    }
  }
}

Future<void> _pumpPage(
  WidgetTester tester,
  Size size, {
  InstallLinkOpener? openLink,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: InstallDownloadsPage(openLink: openLink)),
    ),
  );
  await tester.pump();
}
