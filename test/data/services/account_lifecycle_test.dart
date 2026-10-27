import 'package:allora/data/services/account_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('does not automatically encrypt a mautrix bridge portal', () {
    expect(
      AccountLifecycleService.shouldAutomaticallyEncrypt(
        isAlreadyEncrypted: false,
        isBridgeControlled: true,
        canSetEncryption: true,
      ),
      isFalse,
    );
  });
}
