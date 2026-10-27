import 'package:allora/data/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SettingsController> freshController() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return SettingsController(prefs, null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Privacy Mode / Incognito Tests', () {
    test('effective flags reflect individual settings when incognito is OFF', () async {
      final c = await freshController();
      expect(c.state.incognito, isFalse);
      expect(c.state.effectiveHideTyping, isFalse);
      expect(c.state.effectiveHideReadReceipts, isFalse);
      expect(c.state.effectiveBlockScreenshots, isFalse);
      expect(c.state.effectiveAiHistory, isTrue);

      c.setHideTyping(true);
      expect(c.state.effectiveHideTyping, isTrue);
      expect(c.state.effectiveHideReadReceipts, isFalse);
    });

    test('incognito mode ON overrides all privacy flags and disables AI history', () async {
      final c = await freshController();
      c.setIncognito(true);

      expect(c.state.incognito, isTrue);
      expect(c.state.effectiveHideTyping, isTrue);
      expect(c.state.effectiveHideReadReceipts, isTrue);
      expect(c.state.effectiveBlockScreenshots, isTrue);
      expect(c.state.effectiveAiHistory, isFalse);
    });

    test('toggling incognito OFF restores individual setting preferences', () async {
      final c = await freshController();
      c.setHideReadReceipts(true);
      c.setIncognito(true);

      expect(c.state.effectiveHideTyping, isTrue);
      expect(c.state.effectiveHideReadReceipts, isTrue);

      c.setIncognito(false);
      expect(c.state.effectiveHideTyping, isFalse);
      expect(c.state.effectiveHideReadReceipts, isTrue);
    });
  });
}
