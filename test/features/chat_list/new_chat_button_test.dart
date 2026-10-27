import 'package:allora/core/theme/app_theme.dart';
import 'package:allora/features/chat_list/widgets/new_chat_button.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    AppTheme.useGoogleFonts = false;
  });

  Widget buildButtonHarness({
    required ThemeData theme,
    VoidCallback? onPressed,
    bool enabled = true,
    String label = 'New Chat',
  }) {
    return MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Center(
          child: NewChatActionButton(
            onPressed: onPressed,
            enabled: enabled,
            label: label,
          ),
        ),
      ),
    );
  }

  testWidgets('NewChatActionButton dynamically binds to active theme colors across presets',
      (tester) async {
    // Test multiple theme presets and accent variants
    final testThemes = [
      AppTheme.light(accentIndex: 0),
      AppTheme.light(accentIndex: 1),
      AppTheme.dark(accentIndex: 2, darkThemeStyle: 'default'),
      AppTheme.dark(accentIndex: 3, darkThemeStyle: 'amoled'),
      AppTheme.dark(accentIndex: 4, darkThemeStyle: 'cyberpunk'),
      AppTheme.dark(accentIndex: 5, darkThemeStyle: 'ocean'),
    ];

    for (final theme in testThemes) {
      await tester.pumpWidget(buildButtonHarness(
        theme: theme,
        onPressed: () {},
      ));
      await tester.pumpAndSettle();

      final c = theme.extension<AlloraColors>()!;
      final textWidget = tester.widget<Text>(find.text('New Chat'));
      expect(textWidget.style?.color, equals(c.onAccent));

      final animatedContainer =
          tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
      final decoration = animatedContainer.decoration as BoxDecoration;
      final gradient = decoration.gradient as LinearGradient;

      expect(gradient.colors[0], equals(c.accent));
      expect(gradient.colors[1], equals(c.bubbleMineDeep));
      expect(decoration.boxShadow, isNotEmpty);
      expect(decoration.boxShadow!.first.color,
          equals(c.accent.withValues(alpha: 0.38)));
    }
  });

  testWidgets('NewChatActionButton renders disabled state with theme tokens',
      (tester) async {
    final theme = AppTheme.light();
    final c = theme.extension<AlloraColors>()!;

    await tester.pumpWidget(buildButtonHarness(
      theme: theme,
      onPressed: null, // Disabled
    ));
    await tester.pumpAndSettle();

    final textWidget = tester.widget<Text>(find.text('New Chat'));
    expect(textWidget.style?.color, equals(c.textTertiary));

    final animatedContainer =
        tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
    final decoration = animatedContainer.decoration as BoxDecoration;
    final gradient = decoration.gradient as LinearGradient;

    expect(gradient.colors[0], equals(c.surfaceAlt));
    expect(gradient.colors[1], equals(c.surfaceAlt));
    expect(decoration.boxShadow, isEmpty);
  });

  testWidgets('NewChatActionButton triggers onPressed when clicked',
      (tester) async {
    bool clicked = false;
    final theme = AppTheme.light();

    await tester.pumpWidget(buildButtonHarness(
      theme: theme,
      onPressed: () => clicked = true,
    ));

    await tester.tap(find.text('New Chat'));
    await tester.pumpAndSettle();

    expect(clicked, isTrue);
  });

  testWidgets('NewChatActionButton responds to hover gestures',
      (tester) async {
    final theme = AppTheme.light();
    final c = theme.extension<AlloraColors>()!;

    await tester.pumpWidget(buildButtonHarness(
      theme: theme,
      onPressed: () {},
    ));

    final gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);

    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.text('New Chat')));
    await tester.pumpAndSettle();

    final animatedContainer =
        tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
    final decoration = animatedContainer.decoration as BoxDecoration;

    expect(decoration.boxShadow!.first.color,
        equals(c.accent.withValues(alpha: 0.50)));
  });
}
