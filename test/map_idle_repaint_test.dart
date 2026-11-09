import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/widgets/map_top_controls.dart';

/// Stands in for the coverage map surface. [paint] runs when this painter
/// shares a layer that a ticker invalidates.
class _MapPaintProbe extends CustomPainter {
  _MapPaintProbe(this.paints);

  final List<int> paints;

  @override
  void paint(Canvas canvas, Size size) {
    paints[0] += 1;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF224466),
    );
  }

  @override
  bool shouldRepaint(covariant _MapPaintProbe oldDelegate) => false;
}

Widget _controls({required bool bleUiEnabled, required bool syncing}) {
  return MapTopControls(
    autoCenter: false,
    onToggleAutoCenter: () {},
    bleConnected: false,
    bleBusy: false,
    bleScanning: false,
    bleUiEnabled: bleUiEnabled,
    onToggleScan: () {},
    onForceScan: () {},
    syncing: syncing,
    forceOffline: false,
    onSync: () {},
    connectionLabel: 'Disconnected',
  );
}

/// Map stack used by [MapPage]: a full-size map under the top controls, inside
/// the same page layer the route already creates.
Widget _mapStack({
  required Key pageLayerKey,
  required List<int> paints,
  required bool bleUiEnabled,
  required bool syncing,
}) {
  return MaterialApp(
    home: Scaffold(
      body: RepaintBoundary(
        key: pageLayerKey,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _MapPaintProbe(paints),
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              top: 20,
              left: 12,
              child: _controls(bleUiEnabled: bleUiEnabled, syncing: syncing),
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _controlsApp({required bool bleUiEnabled, required bool syncing}) {
  return MaterialApp(
    home: Scaffold(
      body: _controls(bleUiEnabled: bleUiEnabled, syncing: syncing),
    ),
  );
}

Future<void> _pumpTicks(WidgetTester tester, int frames) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Text _tipWidget(WidgetTester tester) {
  return tester.widget<Text>(
    find.descendant(
      of: find.byKey(const ValueKey<String>('map-usage-tip')),
      matching: find.byType(Text),
    ),
  );
}

/// The rendered tip is taller than a single line of the same style.
void _expectTipWraps(WidgetTester tester) {
  final tipText = _tipWidget(tester);
  expect(tipText.softWrap, isTrue);
  expect(tipText.maxLines, 3);
  expect(tipText.overflow, TextOverflow.ellipsis);
  expect(tipText.style?.fontSize, greaterThanOrEqualTo(11));
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(
      of: find.byKey(const ValueKey<String>('map-usage-tip')),
      matching: find.byType(Text),
    ),
  );
  final oneLine = TextPainter(
    text: TextSpan(text: 'Tip', style: tipText.style),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(
      tester.element(find.byKey(const ValueKey<String>('map-usage-tip'))),
    ),
    maxLines: 1,
  )..layout();
  expect(paragraph.size.height, greaterThan(oneLine.height));
  oneLine.dispose();
  expect(paragraph.didExceedMaxLines, isTrue);
}

String _tipText(WidgetTester tester) {
  final tip = tester.widget<Text>(
    find.descendant(
      of: find.byKey(const ValueKey<String>('map-usage-tip')),
      matching: find.byType(Text),
    ),
  );
  expect(tip.data, isNotNull);
  return tip.data!;
}

void _expectIdleFrameSchedule(WidgetTester tester) {
  expect(tester.binding.transientCallbackCount, 0);
  expect(tester.binding.hasScheduledFrame, isFalse);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('idle map tips do not schedule continuous frames', (
    tester,
  ) async {
    final paints = <int>[0];
    final pageLayerKey = GlobalKey();
    await tester.pumpWidget(
      _mapStack(
        pageLayerKey: pageLayerKey,
        paints: paints,
        bleUiEnabled: true,
        syncing: false,
      ),
    );
    await tester.pump();

    final pageLayer = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(pageLayerKey),
    );
    final tipLayer = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey<String>('map-usage-tip')),
    );
    final tip = _tipText(tester);
    pageLayer.debugResetMetrics();
    tipLayer.debugResetMetrics();
    paints[0] = 0;

    await _pumpTicks(tester, 60);

    final tipPaints =
        tipLayer.debugSymmetricPaintCount + tipLayer.debugAsymmetricPaintCount;
    expect(_tipText(tester), tip);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(paints[0], 0);
    expect(pageLayer.debugSymmetricPaintCount, 0);
    expect(pageLayer.debugAsymmetricPaintCount, 0);
    expect(tipPaints, 0);
    _expectIdleFrameSchedule(tester);
  });

  testWidgets('map tips swap once per interval without a ticker', (
    tester,
  ) async {
    final paints = <int>[0];
    final pageLayerKey = GlobalKey();
    await tester.pumpWidget(
      _mapStack(
        pageLayerKey: pageLayerKey,
        paints: paints,
        bleUiEnabled: true,
        syncing: false,
      ),
    );
    await tester.pump();

    final pageLayer = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(pageLayerKey),
    );
    final first = _tipText(tester);
    pageLayer.debugResetMetrics();
    paints[0] = 0;

    await tester.pump(mapUsageTipInterval - const Duration(seconds: 1));
    expect(_tipText(tester), first);
    expect(paints[0], 0);
    _expectIdleFrameSchedule(tester);

    await tester.pump(const Duration(seconds: 1));
    final second = _tipText(tester);
    expect(second, isNot(first));
    expect(paints[0], 0);
    expect(pageLayer.debugSymmetricPaintCount, 0);
    expect(pageLayer.debugAsymmetricPaintCount, 0);
    _expectIdleFrameSchedule(tester);

    await _pumpTicks(tester, 30);
    expect(_tipText(tester), second);
    expect(paints[0], 0);
    _expectIdleFrameSchedule(tester);
  });

  testWidgets('hidden map tips pause rotation and resume on a new interval', (
    tester,
  ) async {
    await tester.pumpWidget(_controlsApp(bleUiEnabled: true, syncing: false));
    await tester.pump();
    final first = _tipText(tester);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(_controlsApp(bleUiEnabled: false, syncing: false));
    await tester.pump(const Duration(seconds: 30));

    expect(find.textContaining('Tip:'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    _expectIdleFrameSchedule(tester);

    await tester.pumpWidget(_controlsApp(bleUiEnabled: true, syncing: false));
    // Showing the scan buttons changes the card width and runs one finite
    // implicit animation. That is not the tip ticker.
    const controlsSettle = Duration(milliseconds: 400);
    await tester.pump(controlsSettle);
    expect(_tipText(tester), first);
    _expectIdleFrameSchedule(tester);

    await tester.pump(
      mapUsageTipInterval - controlsSettle - const Duration(seconds: 1),
    );
    expect(_tipText(tester), first);
    await tester.pump(const Duration(seconds: 1));
    expect(_tipText(tester), isNot(first));
    _expectIdleFrameSchedule(tester);
  });

  for (final state in const <AppLifecycleState>[
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
  ]) {
    testWidgets('map tips pause while $state and resume on a new interval', (
      tester,
    ) async {
      addTearDown(() {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      });

      await tester.pumpWidget(_controlsApp(bleUiEnabled: true, syncing: false));
      await tester.pump();
      final first = _tipText(tester);

      await tester.pump(const Duration(seconds: 4));
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump(const Duration(seconds: 30));
      expect(_tipText(tester), first);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(_tipText(tester), first);
      _expectIdleFrameSchedule(tester);

      await tester.pump(mapUsageTipInterval - const Duration(seconds: 1));
      expect(_tipText(tester), first);
      await tester.pump(const Duration(seconds: 1));
      expect(_tipText(tester), isNot(first));
      _expectIdleFrameSchedule(tester);
    });
  }

  testWidgets('a long map tip wraps, and a still-truncated tip opens in full', (
    tester,
  ) async {
    await tester.pumpWidget(_controlsApp(bleUiEnabled: true, syncing: false));
    await tester.pump();

    final tip = _tipText(tester);
    _expectTipWraps(tester);
    // The status card stays the icon-row width (172) plus the card margin.
    expect(tester.getSize(find.byType(Card)).width, lessThanOrEqualTo(180));

    await tester.tap(find.byKey(const ValueKey<String>('map-usage-tip')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byKey(const ValueKey<String>('map-usage-tip-dialog')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('map-usage-tip-dialog')),
        matching: find.text(tip),
      ),
      findsOneWidget,
    );
    expect(_tipText(tester), tip);
    _expectIdleFrameSchedule(tester);
  });

  testWidgets(
    'status card stays clear of the filter controls on a 360dp phone',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  top: 20,
                  left: 12,
                  child: _controls(bleUiEnabled: true, syncing: false),
                ),
                Positioned(
                  top: 20,
                  right: 12,
                  child: Row(
                    children: [
                      Card(
                        elevation: 1,
                        child: IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: () {},
                          icon: const Icon(Icons.filter_alt),
                          tooltip: 'Filter repeater hits',
                        ),
                      ),
                      const SizedBox(width: 8),
                      Card(
                        elevation: 1,
                        child: IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: () {},
                          icon: const Icon(Icons.dark_mode),
                          tooltip: 'Map layers',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final status = tester.getRect(find.byType(MapTopControls));
      final filter = tester.getRect(find.byIcon(Icons.filter_alt));
      final layers = tester.getRect(find.byIcon(Icons.dark_mode));
      expect(status.overlaps(filter), isFalse);
      expect(status.overlaps(layers), isFalse);
      expect(status.right, lessThan(filter.left));
      expect(status.width, lessThanOrEqualTo(180));

      _expectTipWraps(tester);
    },
  );

  testWidgets(
    'sync spinner runs only while syncing and does not repaint the map',
    (tester) async {
      final paints = <int>[0];
      final pageLayerKey = GlobalKey();
      await tester.pumpWidget(
        _mapStack(
          pageLayerKey: pageLayerKey,
          paints: paints,
          bleUiEnabled: false,
          syncing: true,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      final pageLayer = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(pageLayerKey),
      );
      pageLayer.debugResetMetrics();
      paints[0] = 0;

      await _pumpTicks(tester, 30);

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining('Tip:'), findsNothing);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      expect(paints[0], 0);
      expect(pageLayer.debugSymmetricPaintCount, 0);
      expect(pageLayer.debugAsymmetricPaintCount, 0);

      await tester.pumpWidget(
        _mapStack(
          pageLayerKey: pageLayerKey,
          paints: paints,
          bleUiEnabled: false,
          syncing: false,
        ),
      );
      await tester.pump();
      pageLayer.debugResetMetrics();
      paints[0] = 0;

      await _pumpTicks(tester, 30);

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(paints[0], 0);
      expect(pageLayer.debugSymmetricPaintCount, 0);
      expect(pageLayer.debugAsymmetricPaintCount, 0);
      _expectIdleFrameSchedule(tester);
    },
  );
}
