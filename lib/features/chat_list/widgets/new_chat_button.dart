import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// A dynamic, state-aware action button for initiating new chats, external
/// invitations, and multi-platform bridge aggregation.
///
/// Inherits all color tokens dynamically from [AlloraColors] (`context.allora`)
/// to ensure seamless adaptation across light, dark, AMOLED, and custom accent
/// presets.
class NewChatActionButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final String label;
  final IconData icon;
  final bool enabled;
  final Object? heroTag;

  const NewChatActionButton({
    super.key,
    required this.onPressed,
    this.label = 'New Chat',
    this.icon = Icons.add_rounded,
    this.enabled = true,
    this.heroTag,
  });

  @override
  State<NewChatActionButton> createState() => _NewChatActionButtonState();
}

class _NewChatActionButtonState extends State<NewChatActionButton> {
  bool _isHovered = false;
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    final isEffectivelyDisabled = !widget.enabled || widget.onPressed == null;

    // Resolve foreground colors based on active state & theme tokens
    final foregroundColor =
        isEffectivelyDisabled ? c.textTertiary : c.onAccent;

    // Resolve gradient based on theme accent tokens and interactive states
    final Gradient backgroundGradient;
    if (isEffectivelyDisabled) {
      backgroundGradient = LinearGradient(
        colors: [c.surfaceAlt, c.surfaceAlt],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
    } else if (_isPressed) {
      backgroundGradient = LinearGradient(
        colors: [
          Color.lerp(c.accent, Colors.black, 0.08) ?? c.accent,
          Color.lerp(c.bubbleMineDeep, Colors.black, 0.08) ?? c.bubbleMineDeep,
        ],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
    } else if (_isHovered) {
      backgroundGradient = LinearGradient(
        colors: [
          Color.lerp(c.accent, Colors.white, 0.10) ?? c.accent,
          Color.lerp(c.bubbleMineDeep, Colors.white, 0.10) ?? c.bubbleMineDeep,
        ],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
    } else {
      backgroundGradient = LinearGradient(
        colors: [c.accent, c.bubbleMineDeep],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
    }

    // Resolve shadow elevation dynamically
    final List<BoxShadow> shadows;
    if (isEffectivelyDisabled) {
      shadows = const [];
    } else if (_isPressed) {
      shadows = [
        BoxShadow(
          color: c.accent.withValues(alpha: 0.28),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ];
    } else if (_isHovered) {
      shadows = [
        BoxShadow(
          color: c.accent.withValues(alpha: 0.50),
          blurRadius: 18,
          offset: const Offset(0, 6),
        ),
      ];
    } else {
      shadows = [
        BoxShadow(
          color: c.accent.withValues(alpha: 0.38),
          blurRadius: 14,
          offset: const Offset(0, 5),
        ),
      ];
    }

    Widget buttonContent = AnimatedScale(
      scale: _isPressed && !isEffectivelyDisabled ? 0.97 : 1.0,
      duration: const Duration(milliseconds: 120),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: backgroundGradient,
          boxShadow: shadows,
          border: isEffectivelyDisabled
              ? Border.all(color: c.outline.withValues(alpha: 0.5), width: 1)
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(28),
            onTap: isEffectivelyDisabled ? null : widget.onPressed,
            onHover: (hovered) {
              if (mounted) setState(() => _isHovered = hovered);
            },
            onHighlightChanged: (pressed) {
              if (mounted) setState(() => _isPressed = pressed);
            },
            hoverColor: c.onAccent.withValues(alpha: 0.08),
            splashColor: c.onAccent.withValues(alpha: 0.20),
            highlightColor: c.onAccent.withValues(alpha: 0.12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.icon,
                    color: foregroundColor,
                    size: 20,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: foregroundColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      letterSpacing: -0.1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (widget.heroTag != null) {
      buttonContent = Hero(
        tag: widget.heroTag!,
        child: buttonContent,
      );
    }

    return Semantics(
      button: true,
      enabled: !isEffectivelyDisabled,
      label: widget.label,
      child: buttonContent,
    );
  }
}
