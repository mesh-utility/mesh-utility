import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/services/settle_debouncer.dart';

void main() {
  testWidgets(
    'several quick schedules produce one call after the quiet period',
    (tester) async {
      final sent = <int>[];
      final debouncer = SettleDebouncer<int>(
        delay: const Duration(milliseconds: 400),
        onSettled: sent.add,
      );
      addTearDown(debouncer.cancel);

      debouncer.schedule(1);
      await tester.pump(const Duration(milliseconds: 200));
      debouncer.schedule(2);
      await tester.pump(const Duration(milliseconds: 200));
      debouncer.schedule(3);
      await tester.pump(const Duration(milliseconds: 399));
      expect(sent, isEmpty);

      await tester.pump(const Duration(milliseconds: 1));
      expect(sent, <int>[3]);

      debouncer.schedule(3);
      await tester.pump(const Duration(milliseconds: 400));
      expect(sent, <int>[3]);

      debouncer.schedule(4);
      await tester.pump(const Duration(milliseconds: 400));
      expect(sent, <int>[3, 4]);

      debouncer.schedule(5);
      debouncer.cancel();
      await tester.pump(const Duration(milliseconds: 400));
      expect(sent, <int>[3, 4]);
    },
  );
}
