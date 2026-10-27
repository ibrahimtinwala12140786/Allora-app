import 'dart:io';
void main() {
  var text = File('lib/screens/telegram/telegram_connection.dart').readAsStringSync();
  text = text.replaceAll("import '../bridge/bridge_room_classifier.dart';", "import '../bridge/bridge_room_classifier.dart';\nimport '../../core/theme/app_theme.dart';");
  text = text.replaceAll('Colors.black87', 'context.allora.text');
  text = text.replaceAll('Colors.black', 'context.allora.text');
  text = text.replaceAll('backgroundColor: Colors.white', 'backgroundColor: context.allora.surface');
  text = text.replaceAll('fillColor: Colors.grey.shade100', 'fillColor: context.allora.surfaceAlt');
  text = text.replaceAll('Colors.grey.shade300', 'context.allora.outline');
  text = text.replaceAll('Colors.grey.shade200', 'context.allora.outline');
  text = text.replaceAll('Colors.grey.shade600', 'context.allora.textSecondary');
  text = text.replaceAll('Colors.grey.shade700', 'context.allora.textSecondary');
  text = text.replaceAll('Colors.grey', 'context.allora.textSecondary');
  text = text.replaceAll('foregroundColor: Colors.white', 'foregroundColor: context.allora.surface');
  text = text.replaceAll('color: Colors.white', 'color: context.allora.surface');
  File('lib/screens/telegram/telegram_connection.dart').writeAsStringSync(text);
}
