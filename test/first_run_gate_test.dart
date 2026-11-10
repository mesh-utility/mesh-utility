import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/services/first_run_gate.dart';

void main() {
  group('canRequestStartupOsPermissions', () {
    test(
      'blocks OS permission prompts until the privacy dialog is resolved',
      () {
        expect(
          canRequestStartupOsPermissions(
            privacyAccepted: false,
            privacyDialogResolved: false,
          ),
          isFalse,
        );
      },
    );

    test('allows prompts after privacy is accepted', () {
      expect(
        canRequestStartupOsPermissions(
          privacyAccepted: true,
          privacyDialogResolved: false,
        ),
        isTrue,
      );
    });

    test('allows prompts after the privacy dialog is skipped', () {
      expect(
        canRequestStartupOsPermissions(
          privacyAccepted: false,
          privacyDialogResolved: true,
        ),
        isTrue,
      );
    });
  });
}
