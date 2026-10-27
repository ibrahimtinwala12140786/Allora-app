import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

final _urlPattern = RegExp(
  r'(https?://[^\s<>"]+|www\.[^\s<>"]+\.[a-z]{2,})',
  caseSensitive: false,
);

/// Message text with full formatting support:
/// - Plain text
/// - Bold: *text*
/// - Italic: _text_
/// - Strikethrough: ~text~
/// - Monospace: `inline code` or ```multiline code block```
/// - Links: clickable hyperlinks with custom styling & tap recognizers
class LinkText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final Color linkColor;
  final bool selectable;

  const LinkText({
    super.key,
    required this.text,
    required this.style,
    required this.linkColor,
    this.selectable = false,
  });

  @override
  State<LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<LinkText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant LinkText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      for (final r in _recognizers) {
        r.dispose();
      }
      _recognizers.clear();
    }
  }

  Future<void> _open(String raw) async {
    var url = raw;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final spans = _parseFormatting(widget.text, widget.style);
    if (widget.selectable) {
      return SelectableText.rich(
        TextSpan(style: widget.style, children: spans),
      );
    }
    return Text.rich(
      TextSpan(style: widget.style, children: spans),
    );
  }

  List<InlineSpan> _parseFormatting(String input, TextStyle currentStyle) {
    if (input.isEmpty) return const [];

    // Step 1: Split by code blocks and URLs first so their internals are never formatted.
    final tokenRegex = RegExp(
      r'(```[\s\S]*?```|`[^`\n]+`|https?://[^\s<>"]+|www\.[^\s<>"]+\.[a-z]{2,})',
      caseSensitive: false,
    );

    final matches = tokenRegex.allMatches(input).toList();
    if (matches.isEmpty) {
      return _parseInlineStyles(input, currentStyle);
    }

    final spans = <InlineSpan>[];
    var cursor = 0;

    for (final m in matches) {
      if (m.start > cursor) {
        spans.addAll(_parseInlineStyles(input.substring(cursor, m.start), currentStyle));
      }

      final matchedText = input.substring(m.start, m.end);

      if (matchedText.startsWith('```') && matchedText.endsWith('```') && matchedText.length >= 6) {
        // Multi-line code block
        final codeContent = matchedText.substring(3, matchedText.length - 3);
        spans.add(TextSpan(
          text: codeContent,
          style: currentStyle.copyWith(
            fontFamily: 'monospace',
            backgroundColor: widget.style.color?.withValues(alpha: 0.12) ?? Colors.black12,
            letterSpacing: -0.2,
          ),
        ));
      } else if (matchedText.startsWith('`') && matchedText.endsWith('`') && matchedText.length >= 2) {
        // Single inline monospace
        final codeContent = matchedText.substring(1, matchedText.length - 1);
        spans.add(TextSpan(
          text: codeContent,
          style: currentStyle.copyWith(
            fontFamily: 'monospace',
            backgroundColor: widget.style.color?.withValues(alpha: 0.12) ?? Colors.black12,
            letterSpacing: -0.2,
          ),
        ));
      } else {
        // URL
        final url = matchedText;
        final recognizer = TapGestureRecognizer()..onTap = () => _open(url);
        _recognizers.add(recognizer);
        spans.add(TextSpan(
          text: url,
          style: TextStyle(
            color: widget.linkColor,
            decoration: TextDecoration.underline,
            decorationColor: widget.linkColor,
          ),
          recognizer: recognizer,
        ));
      }

      cursor = m.end;
    }

    if (cursor < input.length) {
      spans.addAll(_parseInlineStyles(input.substring(cursor), currentStyle));
    }

    return spans;
  }

  // Parses WhatsApp-style formatting: *bold*, _italic_, ~strikethrough~
  List<InlineSpan> _parseInlineStyles(String input, TextStyle currentStyle) {
    if (input.isEmpty) return const [];

    // Find the first occurrence of *bold*, _italic_, or ~strikethrough~
    // Delimiters must not have leading/trailing spaces inside: *(?!\s)...(?<!\s)*
    final inlineRegex = RegExp(
      r'(\*(?!\s)([^\*\n]+?)(?<!\s)\*)|(_(?!\s)([^_\n]+?)(?<!\s)_)|(~(?!\s)([^~\n]+?)(?<!\s)~)',
      multiLine: true,
    );

    final match = inlineRegex.firstMatch(input);
    if (match == null) {
      return [TextSpan(text: input, style: currentStyle)];
    }

    final spans = <InlineSpan>[];
    if (match.start > 0) {
      spans.add(TextSpan(text: input.substring(0, match.start), style: currentStyle));
    }

    if (match.group(1) != null) {
      // Bold: *text*
      final inner = match.group(2)!;
      final newStyle = currentStyle.copyWith(fontWeight: FontWeight.bold);
      spans.addAll(_parseInlineStyles(inner, newStyle));
    } else if (match.group(3) != null) {
      // Italic: _text_
      final inner = match.group(4)!;
      final newStyle = currentStyle.copyWith(fontStyle: FontStyle.italic);
      spans.addAll(_parseInlineStyles(inner, newStyle));
    } else if (match.group(5) != null) {
      // Strikethrough: ~text~
      final inner = match.group(6)!;
      final newStyle = currentStyle.copyWith(
        decoration: currentStyle.decoration == null
            ? TextDecoration.lineThrough
            : TextDecoration.combine([currentStyle.decoration!, TextDecoration.lineThrough]),
        decorationColor: currentStyle.color,
      );
      spans.addAll(_parseInlineStyles(inner, newStyle));
    }

    if (match.end < input.length) {
      spans.addAll(_parseInlineStyles(input.substring(match.end), currentStyle));
    }

    return spans;
  }
}
