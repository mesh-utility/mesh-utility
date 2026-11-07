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

Future<void> _pumpTicks(WidgetTester tester, int frames) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

RenderRepaintBoundary _marqueeLayer(RenderRepaintBoundary pageLayer) {
  final matches = <RenderRepaintBoundary>[];
  void visit(RenderObject object) {
    if (object is RenderRepaintBoundary &&
        object != pageLayer &&
        object.size.height > 0 &&
        object.size.height < 40 &&
        object.size.width > 40) {
      matches.add(object);
    }
    object.visitChildren(visit);
  }

  visit(pageLayer);
  expect(matches, hasLength(1));
  return matches.single;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scrolling map tips do not repaint the map', (tester) async {
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
    await tester.pump(const Duration(milliseconds: 16));

    final pageLayer = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(pageLayerKey),
    );
    final marqueeLayer = _marqueeLayer(pageLayer);
    pageLayer.debugResetMetrics();
    marqueeLayer.debugResetMetrics();
    paints[0] = 0;

    await _pumpTicks(tester, 30);

    final marqueePaints =
        marqueeLayer.debugSymmetricPaintCount +
        marqueeLayer.debugAsymmetricPaintCount;
    expect(paints[0], 0);
    expect(pageLayer.debugSymmetricPaintCount, 0);
    expect(pageLayer.debugAsymmetricPaintCount, 0);
    expect(marqueePaints, greaterThanOrEqualTo(30));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
  });

  testWidgets('sync spinner does not repaint the map', (tester) async {
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
    expect(paints[0], 0);
    expect(pageLayer.debugSymmetricPaintCount, 0);
    expect(pageLayer.debugAsymmetricPaintCount, 0);
  });

  testWidgets('hidden map tips leave no pending ticker', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: _controls(bleUiEnabled: false, syncing: false)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Tip:'), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });
}
