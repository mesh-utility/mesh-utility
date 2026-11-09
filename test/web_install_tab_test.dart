import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mesh_utility/main.dart';
import 'package:mesh_utility/src/pages/install_downloads_page.dart';
import 'package:mesh_utility/src/platform/web_install_nav.dart';
import 'package:mesh_utility/src/services/release_notes.dart';

class _ScriptClient extends http.BaseClient {
  _ScriptClient(this._handle);

  final Future<http.Response> Function(http.BaseRequest request) _handle;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _handle(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }
}

http.Client _offlineClient() {
  return _ScriptClient((request) async {
    return http.Response('offline', 503);
  });
}

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
    await _pumpShell(tester, isWeb: true, size: const Size(1280, 4000));

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
    await _pumpPage(tester, const Size(360, 5600));

    expect(find.text('Open latest release'), findsOneWidget);
    expect(find.text('Extract and run:'), findsOneWidget);
    expect(find.textContaining('choose Install update'), findsOneWidget);
    expect(find.text(InstallDownloadsPage.latestReleaseUrl), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets("what's new groups the latest release notes", (tester) async {
    final opened = <Uri>[];
    final gate = Completer<http.Response>();
    final client = _ScriptClient((request) => gate.future);
    await _pumpPage(
      tester,
      const Size(800, 2400),
      openLink: (uri) async {
        opened.add(uri);
      },
      httpClient: client,
      settleWhatsNew: false,
    );

    expect(find.byKey(whatsNewLoadingKey), findsOneWidget);

    gate.complete(
      http.Response(
        jsonEncode(<String, String>{
          'tag_name': 'Alpha-22',
          'html_url':
              'https://github.com/mesh-utility/mesh-utility/releases/tag/Alpha-22',
          'body': '''
## Fixes
- The countdown starts when the scan is sent. See the [notes](https://example.com/notes).
## Enhancements
- Travel downloads wait until you move.
### Other
- Docs updated.
''',
        }),
        200,
        headers: const {'content-type': 'application/json'},
      ),
    );
    await _pumpUntilWhatsNewSettles(tester);

    expect(find.text("What's new in Alpha-22"), findsOneWidget);
    expect(find.text('Fixes'), findsOneWidget);
    expect(
      find.textContaining('The countdown starts when the scan is sent'),
      findsOneWidget,
    );
    expect(find.text('Enhancements'), findsOneWidget);
    expect(
      find.textContaining('Travel downloads wait until you move'),
      findsOneWidget,
    );
    expect(find.text('Other changes'), findsOneWidget);
    expect(find.textContaining('Docs updated'), findsOneWidget);
    expect(find.byKey(whatsNewFallbackKey), findsNothing);
    expect(find.text('See release notes on GitHub'), findsOneWidget);

    await tester.ensureVisible(find.textContaining('See the notes'));
    await tester.tap(find.textContaining('See the notes'));
    await tester.pump();
    expect(opened, hasLength(1));
    expect(opened.single.toString(), 'https://example.com/notes');

    await tester.ensureVisible(find.text('See release notes on GitHub'));
    await tester.tap(find.text('See release notes on GitHub'));
    await tester.pump();
    expect(opened, hasLength(2));
    expect(
      opened.last.toString(),
      'https://github.com/mesh-utility/mesh-utility/releases/tag/Alpha-22',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets("what's new uses the bundled notes when GitHub fails", (
    tester,
  ) async {
    await _pumpPage(
      tester,
      const Size(800, 4400),
      httpClient: _offlineClient(),
    );

    expect(find.byKey(whatsNewLoadingKey), findsNothing);
    expect(find.byKey(whatsNewFallbackKey), findsOneWidget);
    expect(find.text("What's new in Alpha-23"), findsOneWidget);
    expect(find.text('Other changes'), findsOneWidget);
    expect(
      find.textContaining('The map shows general coverage as soon as it opens'),
      findsOneWidget,
    );
    expect(find.text('Fixes'), findsOneWidget);
    expect(find.text('Enhancements'), findsOneWidget);
    expect(find.text('See release notes on GitHub'), findsOneWidget);
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

  await tester.pumpWidget(
    MeshUtilityApp(isWeb: isWeb, installHttpClient: _offlineClient()),
  );
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
  http.Client? httpClient,
  bool settleWhatsNew = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // A previous test can leave this string's cached future unfinished.
  // Drop it so this page reads the asset again.
  rootBundle.evict(bundledReleaseNotesAsset);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: InstallDownloadsPage(
          openLink: openLink,
          httpClient: httpClient ?? _offlineClient(),
        ),
      ),
    ),
  );
  await tester.pump();
  if (settleWhatsNew) {
    await _pumpUntilWhatsNewSettles(tester);
  }
}

Future<void> _pumpUntilWhatsNewSettles(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump();
    if (find.byKey(whatsNewLoadingKey).evaluate().isEmpty) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
}
