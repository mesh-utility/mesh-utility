import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/main.dart';

void main() {
  testWidgets('app shell renders', (WidgetTester tester) async {
    await tester.pumpWidget(const MeshUtilityApp());
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(Scaffold), findsWidgets);
  });
}
