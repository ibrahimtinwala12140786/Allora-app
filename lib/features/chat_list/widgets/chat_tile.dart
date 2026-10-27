import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/chat_time.dart';
import '../../../core/widgets/allora_avatar.dart';
import '../../../data/services/contacts_service.dart';
import '../chat_list_providers.dart';

/// One conversation row matching the executive modern Allora design.
///
/// Features:
///   - Large avatar with platform brand badge cleanly nested on bottom-right.
///   - Contact title with clean typography and right-aligned timestamp.
///   - Subtitle with "[Platform] •" in brand color followed by the message preview.
///   - Deep navy unread count badge pill on the far right.
///   - Indented divider (74dp) matching modern iOS/executive aesthetics.
class ChatTile extends ConsumerWidget {
  final ChatEntry entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const ChatTile({
    super.key,
    required this.entry,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.allora;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    ref.watch(contactsProvider);
    final contacts = ref.read(contactsProvider.notifier);
    final room = entry.room;
    final preview = previewFor(
      entry.lastEvent,
      isGroup: entry.isGroup,
      myUserId: room.client.userID,
      resolveName: contacts.resolveName,
    );
    final hasStamp = entry.lastEvent != null;

    final titleColor = isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A);
    final subtitleColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final timeColor = isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8);
    final dividerColor = isDark ? const Color(0xFF1E212A) : const Color(0xFFF1F3F6);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Avatar with platform badge
                  AlloraAvatar(
                    name: entry.title,
                    mxcUri: AlloraAvatar.resolveUri(room),
                    client: room.client,
                    size: 50,
                    network: entry.network,
                    showNetworkBadge: true,
                  ),
                  const SizedBox(width: 13),

                  // Middle details column
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Name and Timestamp
                        Row(
                          children: [
                            if (entry.pinned) ...[
                              Icon(
                                Icons.push_pin_rounded,
                                size: 13,
                                color: isDark
                                    ? const Color(0xFF8E8E93)
                                    : const Color(0xFF7A7B80),
                              ),
                              const SizedBox(width: 4),
                            ],
                            Expanded(
                              child: Text(
                                entry.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.2,
                                  color: titleColor,
                                ),
                              ),
                            ),
                            for (final label in entry.labels.take(2))
                              Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: Container(
                                  width: 6.5,
                                  height: 6.5,
                                  decoration: BoxDecoration(
                                    color: label.color,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                            if (hasStamp) ...[
                              const SizedBox(width: 8),
                              Text(
                                ChatTime.listStamp(entry.lastActivity),
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: timeColor,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3.5),

                        // Subtitle: [Platform •] + Message Preview + Unread Badge
                        Row(
                          children: [
                            if (entry.network != null) ...[
                              Text(
                                entry.network!.displayName,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w500,
                                  color: subtitleColor,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Container(
                                width: 5.5,
                                height: 5.5,
                                decoration: BoxDecoration(
                                  color: entry.network!.brandColor,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Expanded(
                              child: entry.typing
                                  ? _TypingPreview(color: c.accent)
                                  : Row(
                                      children: [
                                        if (_glyphIcon(preview.glyph) != null) ...[
                                          Icon(
                                            _glyphIcon(preview.glyph),
                                            size: 14,
                                            color: subtitleColor,
                                          ),
                                          const SizedBox(width: 4),
                                        ],
                                        Expanded(
                                          child: Text(
                                            preview.text,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 13.5,
                                              fontWeight: entry.isUnread
                                                  ? FontWeight.w600
                                                  : FontWeight.w400,
                                              color: subtitleColor,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                            if (entry.muted)
                              Padding(
                                padding: const EdgeInsets.only(left: 6),
                                child: Icon(
                                  Icons.notifications_off_rounded,
                                  size: 14,
                                  color: timeColor,
                                ),
                              ),
                            if (entry.unreadCount > 0)
                              Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: Container(
                                  constraints: const BoxConstraints(
                                      minWidth: 20, minHeight: 20),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? const Color(0xFF3843D0)
                                        : const Color(0xFF1E2238),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    entry.unreadCount > 99
                                        ? '99+'
                                        : '${entry.unreadCount}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      height: 1.1,
                                    ),
                                  ),
                                ),
                              )
                            else if (entry.markedUnread)
                              Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? const Color(0xFF3843D0)
                                        : const Color(0xFF1E2238),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Divider(
          height: 1,
          thickness: 0.8,
          indent: 77,
          endIndent: 16,
          color: dividerColor,
        ),
      ],
    );
  }

  static IconData? _glyphIcon(PreviewGlyph glyph) {
    switch (glyph) {
      case PreviewGlyph.photo:
        return Icons.photo_outlined;
      case PreviewGlyph.video:
        return Icons.videocam_outlined;
      case PreviewGlyph.voice:
        return Icons.mic_outlined;
      case PreviewGlyph.file:
        return Icons.description_outlined;
      case PreviewGlyph.location:
        return Icons.location_on_outlined;
      case PreviewGlyph.sticker:
        return Icons.emoji_emotions_outlined;
      case PreviewGlyph.deleted:
        return Icons.block_outlined;
      case PreviewGlyph.none:
        return null;
    }
  }
}

/// "typing" with three bouncing dots, shown in the preview line.
class _TypingPreview extends StatefulWidget {
  final Color color;
  const _TypingPreview({required this.color});

  @override
  State<_TypingPreview> createState() => _TypingPreviewState();
}

class _TypingPreviewState extends State<_TypingPreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          'typing',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: widget.color,
          ),
        ),
        const SizedBox(width: 3),
        AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            return Row(
              children: List.generate(3, (i) {
                final t = (_ctrl.value * 3 - i).clamp(0.0, 1.0);
                final bounce = (t < 0.5 ? t : 1 - t) * 2;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: Transform.translate(
                    offset: Offset(0, -2.5 * bounce),
                    child: Container(
                      width: 3.5,
                      height: 3.5,
                      decoration: BoxDecoration(
                        color: widget.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                );
              }),
            );
          },
        ),
      ],
    );
  }
}
