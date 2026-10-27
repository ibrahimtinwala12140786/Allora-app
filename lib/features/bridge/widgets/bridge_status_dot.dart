import 'package:flutter/material.dart';
import '../models/bridge_connection_state.dart';

/// Animated status dot for network and room avatars indicating real-time bridge health.
/// Green: Connected
/// Amber: Reconnecting (with subtle pulse animation)
/// Red: Needs Login, Rate Limited, Bridge Unreachable
class BridgeStatusDot extends StatefulWidget {
  final BridgeConnectionState state;
  final double size;
  final bool showBorder;

  const BridgeStatusDot({
    super.key,
    required this.state,
    this.size = 12.0,
    this.showBorder = true,
  });

  @override
  State<BridgeStatusDot> createState() => _BridgeStatusDotState();
}

class _BridgeStatusDotState extends State<BridgeStatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    _pulseAnimation = Tween<double>(begin: 0.75, end: 1.25).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _updateAnimationState();
  }

  @override
  void didUpdateWidget(covariant BridgeStatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      _updateAnimationState();
    }
  }

  void _updateAnimationState() {
    if (widget.state == BridgeConnectionState.reconnecting) {
      _pulseController.repeat(reverse: true);
    } else {
      _pulseController.stop();
      _pulseController.value = 1.0;
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.state.statusColor;

    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, child) {
        final scale = widget.state == BridgeConnectionState.reconnecting
            ? _pulseAnimation.value
            : 1.0;

        return Transform.scale(
          scale: scale,
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: widget.showBorder
                  ? Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 2.0)
                  : null,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.4),
                  blurRadius: widget.state == BridgeConnectionState.reconnecting ? 6.0 : 3.0,
                  spreadRadius: 1.0,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
