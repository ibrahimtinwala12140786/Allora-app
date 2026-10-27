// ignore_for_file: deprecated_member_use
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/chat_time.dart';
import '../../../core/utils/media_limits.dart';
import '../../../core/widgets/allora_avatar.dart';
import '../../../core/utils/matrix_media.dart';
import '../../../core/widgets/link_text.dart';
import '../../../data/services/contacts_service.dart';
import '../../../data/settings/app_settings.dart';
import '../../../data/services/ai_service.dart';
import '../../../screens/bridge/bridge_room_classifier.dart';
import 'image_viewer.dart';
import 'video_player_screen.dart';
import '../../../core/services/link_preview_service.dart';
import '../../../core/widgets/link_preview_card.dart';

/// Strips the legacy `> quoted` fallback block from reply bodies.
String stripReplyFallback(String body) {
  if (body.isEmpty) return '';
  final lower = body.toLowerCase().trim();
  if (lower.startsWith('unknown message format')) return '';
  if (lower.startsWith('m.room.')) return '';
  if (!body.startsWith('> ')) return body;
  final lines = body.split('\n');
  var i = 0;
  while (i < lines.length && lines[i].startsWith('> ')) {
    i++;
  }
  while (i < lines.length && lines[i].trim().isEmpty) {
    i++;
  }
  return lines.sublist(i).join('\n');
}

String? replyToEventId(Event event) {
  final relates = event.content['m.relates_to'];
  if (relates is Map) {
    final inReply = relates['m.in_reply_to'];
    if (inReply is Map) return inReply['event_id']?.toString();
  }
  return null;
}

/// One message row: avatar (groups), bubble with content + inline footer,
/// reaction chips, swipe-to-reply, long-press menu hook, selection state.
class MessageBubble extends ConsumerStatefulWidget {
  final Event event; // display event (edits already applied)
  final Timeline timeline;
  final Event? older; // previous message in time
  final Event? newer; // next message in time
  final bool selectionMode;
  final bool selected;
  final bool highlighted;
  final double fontScale;
  final Event? Function(String eventId) resolveEvent;
  final void Function(Event event, Rect bubbleRect) onLongPress;
  final void Function(Event event) onSwipeReply;
  final VoidCallback onTap;
  final void Function(String eventId) onJumpTo;
  final Future<void> Function(Event event, String key) onToggleReaction;

  const MessageBubble({
    super.key,
    required this.event,
    required this.timeline,
    required this.older,
    required this.newer,
    required this.selectionMode,
    required this.selected,
    required this.highlighted,
    required this.fontScale,
    required this.resolveEvent,
    required this.onLongPress,
    required this.onSwipeReply,
    required this.onTap,
    required this.onJumpTo,
    required this.onToggleReaction,
  });

  @override
  ConsumerState<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends ConsumerState<MessageBubble> {
  double _dragX = 0;
  bool _pressed = false;

  static final Map<String, String> _translationCache = {};
  bool _isTranslating = false;
  bool _isDownloading = false;

  Future<void> _downloadAndOpen(MediaSource? source, String filename, {bool isVideo = false, bool isAudio = false}) async {
    if (_isDownloading) return;
    setState(() => _isDownloading = true);
    try {
      final tempDir = await getTemporaryDirectory();
      final safeName = filename.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final file = File('${tempDir.path}/$safeName');
      if (!await file.exists()) {
        if (event.isAttachmentEncrypted) {
          final matrixFile = await event.downloadAndDecryptAttachment();
          await file.writeAsBytes(matrixFile.bytes);
        } else if (source != null) {
          final res = await http.get(Uri.parse(source.url), headers: source.headers);
          if (res.statusCode == 200) {
            await file.writeAsBytes(res.bodyBytes);
          } else {
            final matrixFile = await event.downloadAndDecryptAttachment();
            await file.writeAsBytes(matrixFile.bytes);
          }
        } else {
          final matrixFile = await event.downloadAndDecryptAttachment();
          await file.writeAsBytes(matrixFile.bytes);
        }
      }
      if (!mounted) return;
      final bool shouldPlayVideo = isVideo || MediaLimits.isVideo(safeName);
      final bool shouldPlayAudio = isAudio || MediaLimits.isAudio(safeName);

      if (shouldPlayVideo || shouldPlayAudio) {
        Navigator.of(context).push(VideoPlayerScreen.route(
          url: file.path,
          headers: {}, // local files don't need auth headers
          title: isMe
              ? 'You'
              : (BridgeRoomClassifier.isDirectChat(room, client: room.client)
                  ? ref.read(contactsProvider.notifier).resolveContactHierarchy(room: room)
                  : ref.read(contactsProvider.notifier).resolveName(event.senderId, event.senderFromMemoryOrFallback.calcDisplayname())),
          isAudio: shouldPlayAudio,
        ));
      } else {
        await OpenFilex.open(file.path);
      }
    } catch (e) {
      debugPrint('Failed to download media: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to load media')),
        );
      }
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  static const _groupWindow = Duration(minutes: 3);

  Event get event => widget.event;
  Room get room => event.room;
  bool get isMe {
    if (event.senderId == room.client.userID) return true;
    if (room.isDirectChat) {
      final directId = room.directChatMatrixID;
      if (directId != null && directId.isNotEmpty && event.senderId != directId) {
        final localpart = event.senderId.split(':').first.toLowerCase();
        if (!localpart.endsWith('bot') && !localpart.contains('bridge') && localpart != 'allora') {
          return true;
        }
      }
    }
    return false;
  }

  bool _sameAuthor(Event? other) {
    if (other == null) return false;
    if (other.senderId != event.senderId) return false;
    if (other.type != EventTypes.Message &&
        other.type != EventTypes.Encrypted &&
        other.type != EventTypes.Sticker) {
      return false;
    }
    return true;
  }

  bool get _isFirstInGroup {
    final older = widget.older;
    if (!_sameAuthor(older)) return true;
    if (!ChatTime.sameDay(older!.originServerTs, event.originServerTs)) {
      return true;
    }
    return event.originServerTs.difference(older.originServerTs) >
        _groupWindow;
  }

  bool get _isLastInGroup {
    final newer = widget.newer;
    if (!_sameAuthor(newer)) return true;
    if (!ChatTime.sameDay(newer!.originServerTs, event.originServerTs)) {
      return true;
    }
    return newer.originServerTs.difference(event.originServerTs) >
        _groupWindow;
  }

  void _handleLongPress() {
    HapticFeedback.mediumImpact();
    final box = context.findRenderObject() as RenderBox?;
    final rect = box == null
        ? Rect.zero
        : box.localToGlobal(Offset.zero) & box.size;
    widget.onLongPress(event, rect);
  }


  bool _isSystemNotice(Event event) {
    final text = event.body.toLowerCase();
    if (text.startsWith('you turned on disappearing') ||
        text.startsWith('you turned off disappearing') ||
        text.contains('new messages will disappear from this chat') ||
        text.contains('disappearing messages after they\'re sent') ||
        event.body.startsWith('⏲')) {
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    if (event.type == EventTypes.Encrypted) {
      final maxWidth = MediaQuery.of(context).size.width * 0.78;
      const r = Radius.circular(19);
      const rs = Radius.circular(6);
      final radius = isMe
          ? BorderRadius.only(topLeft: r, bottomLeft: r, topRight: _isFirstInGroup ? r : rs, bottomRight: rs)
          : BorderRadius.only(topRight: r, bottomRight: r, topLeft: _isFirstInGroup ? r : rs, bottomLeft: rs);

      return Padding(
        padding: EdgeInsets.only(
          left: 10,
          right: 10,
          top: _isFirstInGroup ? 8 : 1.5,
          bottom: _isLastInGroup ? 2 : 0,
        ),
        child: Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            constraints: BoxConstraints(maxWidth: maxWidth),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: isMe ? c.bubbleMine.withValues(alpha: 0.8) : c.surface,
              borderRadius: radius,
              border: !isMe ? Border.all(color: c.outline, width: 0.8) : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline_rounded, size: 16, color: isMe ? c.onAccent : c.textSecondary),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Encrypted message',
                    style: TextStyle(
                      fontSize: 13.5 * widget.fontScale,
                      fontStyle: FontStyle.italic,
                      color: isMe ? c.onAccent : c.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  ChatTime.formatTime12h(event.originServerTs),
                  style: TextStyle(
                    fontSize: 10.5,
                    color: isMe ? c.onAccent.withOpacity(0.7) : c.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (_isSystemNotice(event)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: c.surfaceAlt.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              event.body,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5 * widget.fontScale,
                color: c.textSecondary,
                height: 1.35,
              ),
            ),
          ),
        ),
      );
    }
    final isGroupChat = !BridgeRoomClassifier.isDirectChat(room, client: room.client);
    final showAvatar = !isMe && isGroupChat;
    final showName = showAvatar && _isFirstInGroup;

    ref.watch(contactsProvider);
    final fallbackName = event.senderFromMemoryOrFallback.calcDisplayname();
    final displayName = ref.read(contactsProvider.notifier).resolveName(event.senderId, fallbackName);

    final bubble = _buildBubble(context);

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment:
          isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        if (widget.selectionMode)
          Padding(
            padding: const EdgeInsets.only(right: 6, bottom: 6),
            child: AnimatedScale(
              scale: 1,
              duration: const Duration(milliseconds: 150),
              child: Icon(
                widget.selected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 21,
                color: widget.selected ? c.accent : c.textTertiary,
              ),
            ),
          ),
        if (showAvatar)
          Padding(
            padding: const EdgeInsets.only(right: 7, bottom: 2),
            child: _isLastInGroup
                ? AlloraAvatar(
                    name: displayName,
                    mxcUri: event.senderFromMemoryOrFallback.avatarUrl,
                    client: room.client,
                    size: 28,
                    showNetworkBadge: false,
                  )
                : const SizedBox(width: 28),
          ),
        Flexible(
          child: Column(
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (showName)
                Padding(
                  padding: const EdgeInsets.only(left: 12, bottom: 2),
                  child: Text(
                    displayName,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: colorForId(event.senderId,
                          dark:
                              Theme.of(context).brightness == Brightness.dark),
                    ),
                  ),
                ),
              bubble,
              _ReactionsRow(
                event: event,
                timeline: widget.timeline,
                isMe: isMe,
                onToggle: (key) => widget.onToggleReaction(event, key),
              ),
            ],
          ),
        ),
      ],
    );

    // Swipe-to-reply: light horizontal drag with a spring back.
    return Padding(
      padding: EdgeInsets.only(
        left: 10,
        right: 10,
        top: _isFirstInGroup ? 8 : 1.5,
        bottom: _isLastInGroup ? 2 : 0,
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onHorizontalDragUpdate: widget.selectionMode
            ? null
            : (d) => setState(() {
                  _dragX = (_dragX + d.delta.dx).clamp(isMe ? -72.0 : 0.0,
                      isMe ? 0.0 : 72.0);
                }),
        onHorizontalDragEnd: widget.selectionMode
            ? null
            : (_) {
                if (_dragX.abs() > 44) {
                  HapticFeedback.lightImpact();
                  widget.onSwipeReply(event);
                }
                setState(() => _dragX = 0);
              },
        child: Stack(
          children: [
            if (_dragX.abs() > 6)
              Positioned.fill(
                child: Align(
                  alignment:
                      isMe ? Alignment.centerRight : Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Opacity(
                      opacity: (_dragX.abs() / 60).clamp(0.0, 1.0),
                      child: Icon(Icons.reply_rounded,
                          size: 20, color: c.textSecondary),
                    ),
                  ),
                ),
              ),
            AnimatedContainer(
              duration: _dragX == 0
                  ? const Duration(milliseconds: 220)
                  : Duration.zero,
              curve: Curves.easeOutBack,
              transform: Matrix4.translationValues(_dragX, 0, 0),
              child: row,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBubble(BuildContext context) {
    final c = context.allora;
    final maxWidth = MediaQuery.of(context).size.width * 0.78;

    if (_isSticker) {
      return GestureDetector(
        onTap: widget.selectionMode ? widget.onTap : null,
        onLongPress: widget.selectionMode ? widget.onTap : _handleLongPress,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 160, maxHeight: 160),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Column(
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _stickerContent(context),
              _footer(context),
            ],
          ),
        ),
      );
    }

    final BorderRadius radius;
    const r = Radius.circular(19);
    const rs = Radius.circular(6);
    if (isMe) {
      radius = BorderRadius.only(
        topLeft: r,
        bottomLeft: r,
        topRight: _isFirstInGroup ? r : rs,
        bottomRight: rs, // WhatsApp-style tail corner on own bubbles
      );
    } else {
      radius = BorderRadius.only(
        topRight: r,
        bottomRight: r,
        topLeft: _isFirstInGroup ? r : rs,
        bottomLeft: rs,
      );
    }

    final isMedia = _isImage || _isVideo;
    final replyId = replyToEventId(event);
    final bg = event.redacted
        ? c.surfaceAlt
        : isMe
            ? null
            : c.surface;

    return GestureDetector(
      onTap: widget.selectionMode ? widget.onTap : null,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onLongPress: widget.selectionMode ? widget.onTap : _handleLongPress,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          constraints: BoxConstraints(maxWidth: maxWidth),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: widget.highlighted
                ? c.accent.withValues(alpha: 0.25)
                : widget.selected
                    ? c.accent.withValues(alpha: 0.18)
                    : bg,
            gradient: (isMe && !event.redacted && !widget.selected &&
                    !widget.highlighted)
                ? LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [c.bubbleMine, c.bubbleMineDeep],
                  )
                : null,
            borderRadius: radius,
            border: !isMe && !event.redacted
                ? Border.all(color: c.outline, width: 0.8)
                : null,
            boxShadow: [
              if (!isMe && !event.redacted)
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
            ],
          ),
          padding: isMedia
              ? EdgeInsets.zero
              : const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (replyId != null && !event.redacted)
                _ReplyPreview(
                  replyId: replyId,
                  resolveEvent: widget.resolveEvent,
                  isMine: isMe,
                  onJumpTo: widget.onJumpTo,
                  inMediaBubble: isMedia,
                ),

              _content(context),
              Padding(
                padding: isMedia
                    ? const EdgeInsets.fromLTRB(8, 3, 6, 3)
                    : EdgeInsets.zero,
                child: _footer(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Content variants ──────────────────────────────────────────────────────

  String? get _mxcUri => MatrixMedia.mxcOf(event);

  String get _mimetype {
    final info = event.content['info'];
    if (info is Map && info['mimetype'] is String) {
      return (info['mimetype'] as String).toLowerCase();
    }
    final m = event.content['mimetype'];
    if (m is String) return m.toLowerCase();
    return '';
  }

  String get _rawFilename {
    final fn = event.content['filename'];
    if (fn is String && fn.trim().isNotEmpty) return fn.trim();
    final info = event.content['info'];
    if (info is Map && info['name'] is String && (info['name'] as String).trim().isNotEmpty) {
      return (info['name'] as String).trim();
    }
    final file = event.content['file'];
    if (file is Map && file['name'] is String && (file['name'] as String).trim().isNotEmpty) {
      return (file['name'] as String).trim();
    }
    final b = event.text.trim();
    if (b.isNotEmpty &&
        !b.toLowerCase().startsWith('unknown message format') &&
        !b.startsWith('m.room.') &&
        !b.startsWith('> ')) {
      return b;
    }
    return '';
  }

  String get _cleanBody {
    final t = event.text.trim();
    if (t.isNotEmpty &&
        !t.toLowerCase().startsWith('unknown message format') &&
        !t.startsWith('m.room.')) {
      return stripReplyFallback(t);
    }
    final mscText = event.content['org.matrix.msc1767.text'];
    if (mscText is String && mscText.trim().isNotEmpty) {
      return stripReplyFallback(mscText.trim());
    }
    final mscMsg = event.content['org.matrix.msc1767.message'];
    if (mscMsg is List && mscMsg.isNotEmpty) {
      for (final part in mscMsg) {
        if (part is Map && part['body'] is String) {
          final s = (part['body'] as String).trim();
          if (s.isNotEmpty) return stripReplyFallback(s);
        }
      }
    }
    return '';
  }

  String _resolveDocumentFilename() {
    if (_rawFilename.isNotEmpty) return _rawFilename;
    final ext = MediaLimits.resolveExtensionFromMime(_mimetype);
    if (ext.isNotEmpty) {
      return 'Document.$ext';
    }
    return 'Document.bin';
  }

  bool get _hasMedia => _mxcUri != null;

  bool get _isSticker {
    if (event.redacted) return false;
    if (event.type == EventTypes.Sticker ||
        event.type == 'm.sticker' ||
        event.content['msgtype'] == 'm.sticker' ||
        _mimetype == 'image/webp.sticker') {
      return _hasMedia;
    }
    return false;
  }

  bool get _isImage {
    if (event.redacted || _isSticker) return false;
    final msgtype = event.content['msgtype'] as String? ?? '';
    if (msgtype == 'm.image') return _hasMedia;
    if (_mimetype.startsWith('image/')) return _hasMedia;
    if (_hasMedia && MediaLimits.isImage(_rawFilename)) return true;
    return false;
  }

  bool get _isVideo {
    if (event.redacted) return false;
    final msgtype = event.content['msgtype'] as String? ?? '';
    if (msgtype == 'm.video') return _hasMedia;
    if (_mimetype.startsWith('video/')) return _hasMedia;
    if (_hasMedia && MediaLimits.isVideo(_rawFilename)) return true;
    return false;
  }

  bool get _isAudio {
    if (event.redacted) return false;
    final msgtype = event.content['msgtype'] as String? ?? '';
    if (msgtype == 'm.audio') return _hasMedia;
    if (_mimetype.startsWith('audio/')) return _hasMedia;
    if (event.content['org.matrix.msc3245.voice'] != null) return _hasMedia;
    if (event.content['org.matrix.msc1767.audio'] != null) return _hasMedia;
    if (_hasMedia && MediaLimits.isAudio(_rawFilename)) return true;
    return false;
  }

  bool get _isLocation {
    if (event.redacted) return false;
    final msgtype = event.content['msgtype'] as String? ?? '';
    if (msgtype == 'm.location') return true;
    final geo = event.content['geo_uri'];
    if (geo is String && geo.isNotEmpty) return true;
    return false;
  }

  bool get _isContact {
    if (event.redacted) return false;
    final msgtype = event.content['msgtype'] as String? ?? '';
    if (msgtype == 'm.contact') return true;
    if (_mimetype.contains('vcard')) return true;
    if (_rawFilename.toLowerCase().endsWith('.vcf')) return true;
    final b = event.text.trim();
    if (b.startsWith('BEGIN:VCARD')) return true;
    return false;
  }

  bool get _isFile {
    if (event.redacted) return false;
    if (_isSticker || _isImage || _isVideo || _isAudio || _isLocation || _isContact) return false;
    final msgtype = event.content['msgtype'] as String? ?? '';
    return msgtype == 'm.file' || _hasMedia;
  }

  Widget _content(BuildContext context) {
    final c = context.allora;

    if (event.redacted) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.block_rounded, size: 15, color: c.textTertiary),
          const SizedBox(width: 6),
          Text('Message deleted',
              style: TextStyle(
                  fontSize: 14 * widget.fontScale,
                  fontStyle: FontStyle.italic,
                  color: c.textTertiary)),
        ],
      );
    }

    if (event.type == EventTypes.Encrypted) {
      return _EncryptedMessageWidget(
        event: event,
        fontScale: widget.fontScale,
        isMe: isMe,
      );
    }

    if (_isSticker) return _stickerContent(context);
    if (_isImage) return _imageContent(context);
    if (_isVideo) return _videoContent(context);
    if (_isAudio) return _audioContent(context);
    if (_isLocation) return _locationContent(context);
    if (_isContact) return _contactContent(context);
    if (_isFile) {
      return _fileLikeContent(context,
          icon: Icons.description_rounded, label: 'Document');
    }

    return _textContent(context);
  }

  Widget _stickerContent(BuildContext context) {
    final mxc = _mxcUri;
    final full = MatrixMedia.download(room.client, mxc);
    return SizedBox(
      width: 140,
      height: 140,
      child: full == null
          ? const SizedBox()
          : Image.network(
              full.url,
              headers: full.headers,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const Icon(
                Icons.emoji_emotions_rounded,
                size: 44,
                color: Colors.white54,
              ),
            ),
    );
  }

  Widget _mutedLine(BuildContext context, IconData icon, String text) {
    final c = context.allora;
    final color = isMe ? c.onAccent.withValues(alpha: 0.8) : c.textSecondary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(text,
              style: TextStyle(
                  fontSize: 13.5 * widget.fontScale,
                  fontStyle: FontStyle.italic,
                  color: color)),
        ),
      ],
    );
  }

  Widget _textContent(BuildContext context) {
    final c = context.allora;
    final body = _cleanBody;
    if (body.isEmpty) return const SizedBox.shrink();
    final emojiOnly = _isEmojiOnly(body);
    
    final settings = ref.watch(settingsProvider);
    final shouldTranslate = !isMe && settings.autoTranslateEnabled && !emojiOnly;
    
    if (shouldTranslate && !_translationCache.containsKey(event.eventId) && !_isTranslating) {
      _isTranslating = true;
      AiService.translate(body, settings.aiTranslateLanguage).then((res) {
        if (mounted && res.ok && res.text != null) {
          setState(() {
            _translationCache[event.eventId] = res.text!;
            _isTranslating = false;
          });
        } else {
          if (mounted) setState(() => _isTranslating = false);
        }
      });
    }

    final translatedText = shouldTranslate ? _translationCache[event.eventId] : null;
    final firstUrl = !emojiOnly ? LinkPreviewService.extractFirstUrl(body) : null;

    final textWidget = LinkText(
      text: body,
      style: TextStyle(
        fontSize: (emojiOnly ? 34 : 15.5) * widget.fontScale,
        height: 1.35,
        letterSpacing: -0.1,
        color: isMe ? c.onAccent : c.text,
      ),
      linkColor: isMe ? c.onAccent : c.accent,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        textWidget,
        if (firstUrl != null)
          LinkPreviewCard(url: firstUrl, isMe: isMe),
        if (translatedText != null) ...[
          const SizedBox(height: 6),
          Container(height: 1, color: isMe ? Colors.white24 : c.outline),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.translate_rounded, size: 14, color: isMe ? Colors.white70 : c.textTertiary),
              const SizedBox(width: 4),
              Flexible(
                child: LinkText(
                  text: translatedText,
                  style: TextStyle(
                    fontSize: 14.5 * widget.fontScale,
                    height: 1.35,
                    color: isMe ? Colors.white70 : c.textSecondary,
                  ),
                  linkColor: isMe ? Colors.white : c.accent,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  static final _emojiOnlyPattern = RegExp(
      r'^[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{200D}\s]+$',
      unicode: true);

  static bool _isEmojiOnly(String s) {
    final t = s.trim();
    return t.isNotEmpty && t.length <= 12 && _emojiOnlyPattern.hasMatch(t);
  }

  Widget _imageContent(BuildContext context) {
    final c = context.allora;
    final mxc = _mxcUri;
    final info = event.content['info'];
    double aspect = 4 / 3;
    if (info is Map) {
      final w = (info['w'] as num?)?.toDouble();
      final h = (info['h'] as num?)?.toDouble();
      if (w != null && h != null && w > 0 && h > 0) {
        aspect = (w / h).clamp(0.55, 2.4);
      }
    }

    final full = MatrixMedia.download(room.client, mxc);

    final caption = _cleanBody;
    final showCaption = caption.isNotEmpty &&
        caption.toLowerCase() != 'image' &&
        !caption.toLowerCase().endsWith('.jpg') &&
        !caption.toLowerCase().endsWith('.jpeg') &&
        !caption.toLowerCase().endsWith('.png') &&
        !caption.toLowerCase().endsWith('.webp');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: widget.selectionMode
              ? widget.onTap
              : () {
                  if (full == null) return;
                  Navigator.of(context).push(ImageViewerScreen.route(
                    url: full.url,
                    headers: full.headers,
                    heroTag: 'img_${event.eventId}',
                    title: isMe
                        ? 'You'
                        : (BridgeRoomClassifier.isDirectChat(room, client: room.client)
                            ? ref.read(contactsProvider.notifier).resolveContactHierarchy(room: room)
                            : ref.read(contactsProvider.notifier).resolveName(event.senderId, event.senderFromMemoryOrFallback.calcDisplayname())),
                  ));
                },
          child: Hero(
            tag: 'img_${event.eventId}',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(15),
              child: AspectRatio(
                aspectRatio: aspect,
                child: full == null
                    ? Container(
                        color: c.surfaceAlt,
                        child: Icon(Icons.image_rounded,
                            color: c.textTertiary, size: 40),
                      )
                    : Image.network(
                        full.url,
                        headers: full.headers,
                        fit: BoxFit.cover,
                        cacheWidth: 1080,
                        filterQuality: FilterQuality.high,
                        gaplessPlayback: true,
                        loadingBuilder: (context, child, progress) {
                          if (progress == null) return child;
                          return Container(
                            color: c.surfaceAlt,
                            child: Center(
                              child: SizedBox(
                                width: 26,
                                height: 26,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: c.textTertiary,
                                ),
                              ),
                            ),
                          );
                        },
                        errorBuilder: (_, __, ___) => Container(
                          color: c.surfaceAlt,
                          child: Icon(Icons.broken_image_rounded,
                              color: c.textTertiary, size: 36),
                        ),
                      ),
              ),
            ),
          ),
        ),
        if (showCaption)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
            child: LinkText(
              text: caption,
              style: TextStyle(
                fontSize: 14.5 * widget.fontScale,
                height: 1.35,
                color: isMe ? c.onAccent : c.text,
              ),
              linkColor: isMe ? c.onAccent : c.accent,
            ),
          ),
      ],
    );
  }

  Widget _audioContent(BuildContext context) {
    final c = context.allora;
    final fg = isMe ? c.onAccent : c.text;
    final info = event.content['info'];
    Duration? duration;
    if (info is Map && info['duration'] is num) {
      duration = Duration(milliseconds: (info['duration'] as num).toInt());
    }

    List<int> waveform = const [];
    final audioMeta = event.content['org.matrix.msc1767.audio'];
    if (audioMeta is Map && audioMeta['waveform'] is List) {
      waveform = (audioMeta['waveform'] as List)
          .whereType<num>()
          .map((n) => n.toInt())
          .toList();
    }
    if (waveform.isEmpty) {
      // Deterministic pseudo-waveform so the bubble still looks alive.
      var seed = event.eventId.hashCode;
      waveform = List.generate(28, (i) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        return 200 + seed % 800;
      });
    }

    return InkWell(
      onTap: () {
        final source = MatrixMedia.download(room.client, _mxcUri);
        final filename = _rawFilename.isNotEmpty && _rawFilename.contains('.')
            ? _rawFilename
            : 'audio_${event.eventId}.m4a';
        _downloadAndOpen(source, filename, isAudio: true);
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: isMe ? c.onAccent.withValues(alpha: 0.22) : c.surfaceAlt,
              shape: BoxShape.circle,
            ),
            child: _isDownloading 
                ? const Padding(
                    padding: EdgeInsets.all(8.0),
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : Icon(Icons.play_arrow_rounded, color: fg, size: 22),
          ),
          const SizedBox(width: 9),
          SizedBox(
            width: 120,
            height: 30,
            child: CustomPaint(
              painter: _WaveformPainter(
                waveform: waveform,
                color: fg.withValues(alpha: 0.85),
              ),
            ),
          ),
          const SizedBox(width: 9),
          Text(
            duration != null ? ChatTime.duration(duration) : 'Voice',
            style: TextStyle(
              fontSize: 12.5 * widget.fontScale,
              fontWeight: FontWeight.w600,
              color: fg.withValues(alpha: 0.9),
            ),
          ),
        ],
      ),
    );
  }

  Widget _videoContent(BuildContext context) {
    final info = event.content['info'];
    double aspect = 16 / 9;
    Duration? duration;
    String? thumbMxc;
    if (info is Map) {
      final w = (info['w'] as num?)?.toDouble();
      final h = (info['h'] as num?)?.toDouble();
      if (w != null && h != null && w > 0 && h > 0) {
        aspect = (w / h).clamp(0.55, 2.4);
      }
      if (info['duration'] is num) {
        duration = Duration(milliseconds: (info['duration'] as num).toInt());
      }
      if (info['thumbnail_url'] is String) {
        thumbMxc = info['thumbnail_url'] as String;
      }
    }
    final thumb = thumbMxc != null
        ? MatrixMedia.thumbnail(room.client, thumbMxc, width: 800, height: 800)
        : null;
    final source = MatrixMedia.download(room.client, _mxcUri);

    void play() {
      final filename = _rawFilename.isNotEmpty && _rawFilename.contains('.')
          ? _rawFilename
          : 'video_${event.eventId}.mp4';
      _downloadAndOpen(source, filename, isVideo: true);
    }

    return GestureDetector(
      onTap: widget.selectionMode ? widget.onTap : play,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: Stack(
          alignment: Alignment.center,
          children: [
            AspectRatio(
              aspectRatio: aspect,
              child: thumb == null
                  ? Container(color: Colors.black)
                  : Image.network(
                      thumb.url,
                      headers: thumb.headers,
                      fit: BoxFit.cover,
                      cacheWidth: 800,
                      errorBuilder: (_, __, ___) =>
                          Container(color: Colors.black),
                    ),
            ),
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                shape: BoxShape.circle,
              ),
              child: _isDownloading
                  ? const Padding(
                      padding: EdgeInsets.all(12.0),
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
                    )
                  : const Icon(Icons.play_arrow_rounded,
                      color: Colors.white, size: 34),
            ),
            if (duration != null)
              Positioned(
                right: 8,
                bottom: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    ChatTime.duration(duration),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _locationContent(BuildContext context) {
    final c = context.allora;
    final fg = isMe ? c.onAccent : c.text;
    final geo = event.content['geo_uri']?.toString() ?? '';
    final body = _cleanBody;
    final title = body.isNotEmpty && !body.startsWith('geo:') ? body : 'Location';

    return InkWell(
      onTap: () {
        if (geo.isNotEmpty) {
          launchUrl(Uri.parse(geo), mode: LaunchMode.externalApplication);
        } else if (body.startsWith('geo:')) {
          launchUrl(Uri.parse(body), mode: LaunchMode.externalApplication);
        }
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: isMe
                  ? c.onAccent.withValues(alpha: 0.22)
                  : const Color(0xFFE53935).withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(Icons.location_on_rounded,
                color: isMe ? c.onAccent : const Color(0xFFE53935), size: 24),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14 * widget.fontScale,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Tap to open in Maps',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: fg.withValues(alpha: 0.72),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _contactContent(BuildContext context) {
    final c = context.allora;
    final fg = isMe ? c.onAccent : c.text;

    String contactName = '';
    String phoneNumber = '';
    final rawText = event.text;
    if (rawText.contains('BEGIN:VCARD')) {
      for (final line in rawText.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.startsWith('FN:')) {
          contactName = trimmed.substring(3).trim();
        } else if (trimmed.startsWith('TEL') && trimmed.contains(':')) {
          phoneNumber = trimmed.split(':').last.trim();
        }
      }
    }
    if (contactName.isEmpty) {
      contactName = event.content['name']?.toString() ??
          (event.content['info'] is Map ? (event.content['info'] as Map)['name']?.toString() ?? '' : '');
    }
    if (contactName.isEmpty) contactName = 'Contact';
    if (phoneNumber.isEmpty) {
      phoneNumber = event.content['phone']?.toString() ?? '';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: isMe
                    ? c.onAccent.withValues(alpha: 0.22)
                    : c.accent.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.person_rounded,
                  color: isMe ? c.onAccent : c.accent, size: 26),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    contactName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14.5 * widget.fontScale,
                      fontWeight: FontWeight.w700,
                      color: fg,
                    ),
                  ),
                  if (phoneNumber.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      phoneNumber,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: fg.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        if (phoneNumber.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(height: 0.8, color: isMe ? Colors.white24 : c.outline),
          const SizedBox(height: 4),
          InkWell(
            onTap: () {
              launchUrl(Uri.parse('tel:$phoneNumber'));
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Center(
                child: Text(
                  'Message or Call',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isMe ? c.onAccent : c.accent,
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _fileLikeContent(BuildContext context,
      {required IconData icon, required String label}) {
    final c = context.allora;
    final fg = isMe ? c.onAccent : c.text;
    final filename = _resolveDocumentFilename();
    final meta = MediaLimits.documentMeta(filename);

    final info = event.content['info'];
    String? sizeStr;
    if (info is Map && info['size'] is num) {
      sizeStr = MediaLimits.formatBytes((info['size'] as num).toInt());
    }

    return InkWell(
      onTap: () {
        final geo = event.content['geo_uri'];
        if (geo is String && geo.isNotEmpty) {
          launchUrl(Uri.parse(geo), mode: LaunchMode.externalApplication);
          return;
        }
        final source = MatrixMedia.download(room.client, _mxcUri);
        _downloadAndOpen(source, filename);
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: isMe
                  ? c.onAccent.withValues(alpha: 0.22)
                  : meta.color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(13),
            ),
            child: _isDownloading
                ? Padding(
                    padding: const EdgeInsets.all(11.0),
                    child: CircularProgressIndicator(
                        color: isMe ? c.onAccent : meta.color, strokeWidth: 2.2),
                  )
                : Icon(meta.icon,
                    color: isMe ? c.onAccent : meta.color, size: 23),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  filename,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14 * widget.fontScale,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: (isMe ? c.onAccent : meta.color)
                            .withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        meta.badge,
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          color: isMe ? c.onAccent : meta.color,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      sizeStr != null ? '$sizeStr • Tap to open' : 'Tap to open',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: fg.withValues(alpha: 0.72),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Footer: time + edited + status ────────────────────────────────────────

  Widget _footer(BuildContext context) {
    final c = context.allora;
    final color = _isImage
        ? (isMe ? c.onAccent : c.textSecondary)
        : isMe
            ? c.onAccent.withValues(alpha: 0.75)
            : c.textTertiary;
    final edited =
        event.hasAggregatedEvents(widget.timeline, RelationshipTypes.edit);

    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (edited) ...[
          Text('edited',
              style: TextStyle(
                  fontSize: 10.5, fontStyle: FontStyle.italic, color: color)),
          const SizedBox(width: 4),
        ],
        Text(
          ChatTime.hourMinute(event.originServerTs),
          style: TextStyle(
              fontSize: 10.5, fontWeight: FontWeight.w500, color: color),
        ),
        if (isMe) ...[
          const SizedBox(width: 3),
          _StatusTicks(
            event: event,
            color: color,
            danger: c.danger,
            seenColor: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFFF0ABFC) // Bright glowing purple for dark theme
                : const Color(0xFFC026D3), // Vivid fuchsia-purple for light theme
          ),
        ],
      ],
    );
  }
}

/// sending → clock · offline/sent → single ✓ · online/delivered → double ✓✓ ·
/// seen → double ✓✓ in purple app color · error → red alert.
class _StatusTicks extends StatelessWidget {
  final Event event;
  final Color color;
  final Color danger;
  final Color seenColor;

  const _StatusTicks({
    required this.event,
    required this.color,
    required this.danger,
    required this.seenColor,
  });

  bool _isSeen(Event event) {
    try {
      final room = event.room;
      final receipts = room.receiptState;
      for (final entry in receipts.global.otherUsers.entries) {
        if (entry.key == event.senderId) continue;
        if (entry.value.eventId == event.eventId) return true;
        if (!entry.value.timestamp.isBefore(event.originServerTs)) {
          return true;
        }
      }
      final mainThread = receipts.mainThread?.otherUsers.entries;
      if (mainThread != null) {
        for (final entry in mainThread) {
          if (entry.key == event.senderId) continue;
          if (entry.value.eventId == event.eventId) return true;
          if (!entry.value.timestamp.isBefore(event.originServerTs)) {
            return true;
          }
        }
      }
    } catch (_) {}
    return false;
  }

  bool _isDelivered(Event event) {
    if (event.eventId.startsWith('AlloraClient-')) return false;
    try {
      final room = event.room;
      final myId = room.client.userID;
      bool hasOtherOnlineUser = false;
      for (final user in room.getParticipants()) {
        if (user.id == myId) continue;
        final localpart = user.id.split(':').first.toLowerCase();
        if (localpart.endsWith('bot') || localpart.contains('bridge') || localpart == '@allora') continue;
        final p = room.client.presences[user.id];
        if (p != null && p.presence == PresenceType.online) {
          hasOtherOnlineUser = true;
          break;
        }
      }
      
      if (hasOtherOnlineUser) return true;

      final last = room.lastEvent;
      if (last != null &&
          last.senderId != myId &&
          !last.originServerTs.isBefore(event.originServerTs)) {
        return true;
      }
    } catch (_) {}
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final status = event.status;
    final isUnconfirmed = event.eventId.startsWith('AlloraClient-');
    Widget icon;
    if (status == EventStatus.error) {
      icon = const SizedBox.shrink(key: ValueKey('err'));
    } else if (status == EventStatus.sending || isUnconfirmed) {
      icon = Icon(Icons.schedule_rounded, size: 12, color: color,
          key: const ValueKey('sending'));
    } else if (_isSeen(event)) {
      icon = Icon(
        Icons.done_all_rounded,
        size: 13.5,
        color: seenColor,
        shadows: const [
          Shadow(color: Colors.black45, blurRadius: 2.5, offset: Offset(0, 0.5))
        ],
        key: const ValueKey('seen'),
      );
    } else if (_isDelivered(event)) {
      icon = Icon(Icons.done_all_rounded, size: 13, color: color,
          key: const ValueKey('delivered'));
    } else {
      icon = Icon(Icons.check_rounded, size: 13, color: color,
          key: const ValueKey('sent_single'));
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      transitionBuilder: (child, anim) =>
          ScaleTransition(scale: anim, child: child),
      child: icon,
    );
  }
}

/// Quoted-message block shown inside a reply bubble.
class _ReplyPreview extends ConsumerWidget {
  final String replyId;
  final Event? Function(String) resolveEvent;
  final bool isMine;
  final bool inMediaBubble;
  final void Function(String eventId) onJumpTo;

  const _ReplyPreview({
    required this.replyId,
    required this.resolveEvent,
    required this.isMine,
    required this.onJumpTo,
    required this.inMediaBubble,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.allora;

    return GestureDetector(
      onTap: () => onJumpTo(replyId),
      child: Container(
        margin: EdgeInsets.only(
            bottom: 6, top: inMediaBubble ? 2 : 0,
            left: inMediaBubble ? 2 : 0, right: inMediaBubble ? 2 : 0),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: (isMine ? Colors.white : c.accent).withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(10),
        ),
        child: IntrinsicHeight(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 3, color: isMine ? c.onAccent : c.accent),
              const SizedBox(width: 7),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 6, 10, 6),
                  child: _replyBody(context, ref),
                ),
              ),
            ],
          ),
        ),

      ),
    );
  }

  Widget _replyBody(BuildContext context, WidgetRef ref) {
    final c = context.allora;
    final original = resolveEvent(replyId);
    final fg = isMine ? c.onAccent : c.text;
    
    String name;
    if (original == null) {
      name = 'Original message';
    } else {
      final room = original.room;
      final myId = room.client.userID;
      final isOriginalMine = original.senderId == myId ||
          (room.isDirectChat &&
              original.senderId != room.directChatMatrixID &&
              !original.senderId.split(':').first.toLowerCase().endsWith('bot') &&
              !original.senderId.split(':').first.toLowerCase().contains('bridge'));

      if (isOriginalMine) {
        name = 'You';
      } else if (BridgeRoomClassifier.isDirectChat(room, client: room.client)) {
        name = ref.read(contactsProvider.notifier).resolveContactHierarchy(room: room, senderId: original.senderId);
      } else {
        final fallback = original.senderFromMemoryOrFallback.calcDisplayname();
        name = ref.read(contactsProvider.notifier).resolveName(original.senderId, fallback);
      }
    }

    String body;
    if (original == null) {
      body = 'Tap to view';
    } else if (original.redacted) {
      body = 'Message deleted';
    } else {
      final msgtype = original.content['msgtype'] as String? ?? '';
      final info = original.content['info'];
      final mime = (info is Map && info['mimetype'] is String ? info['mimetype'] as String : '').toLowerCase();
      if (original.type == EventTypes.Sticker ||
          original.type == 'm.sticker' ||
          msgtype == 'm.sticker' ||
          mime == 'image/webp.sticker') {
        body = 'Sticker';
      } else if (msgtype == 'm.image' || mime.startsWith('image/')) {
        body = 'Photo';
      } else if (msgtype == 'm.video' || mime.startsWith('video/')) {
        body = 'Video';
      } else if (msgtype == 'm.audio' ||
          mime.startsWith('audio/') ||
          original.content['org.matrix.msc3245.voice'] != null) {
        body = 'Voice message';
      } else if (msgtype == 'm.location') {
        body = 'Location';
      } else if (msgtype == 'm.contact' || mime.contains('vcard')) {
        body = 'Contact';
      } else {
        final raw = original.text.trim();
        final clean = stripReplyFallback(raw);
        if (clean.isNotEmpty &&
            !clean.toLowerCase().startsWith('unknown message format') &&
            !clean.startsWith('m.room.')) {
          body = clean;
        } else if (msgtype == 'm.file' || MatrixMedia.mxcOf(original) != null) {
          body = 'Document';
        } else {
          body = 'Message';
        }
      }
    }
    return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: isMine ? c.onAccent : c.accent,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              body.replaceAll('\n', ' '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12.5, color: fg.withValues(alpha: 0.85)),
            ),
          ],
        );
  }
}

/// Aggregated reaction chips under a bubble; tap toggles your reaction.
class _ReactionsRow extends StatelessWidget {
  final Event event;
  final Timeline timeline;
  final bool isMe;
  final void Function(String key) onToggle;

  const _ReactionsRow({
    required this.event,
    required this.timeline,
    required this.isMe,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    final reactions =
        event.aggregatedEvents(timeline, RelationshipTypes.reaction);
    if (reactions.isEmpty) return const SizedBox.shrink();

    final myId = event.room.client.userID;
    final counts = <String, int>{};
    final mine = <String>{};
    for (final r in reactions) {
      if (r.redacted) continue;
      final relates = r.content['m.relates_to'];
      if (relates is! Map) continue;
      final key = relates['key']?.toString();
      if (key == null || key.isEmpty) continue;
      counts[key] = (counts[key] ?? 0) + 1;
      if (r.senderId == myId) mine.add(key);
    }
    if (counts.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final entry in counts.entries)
            GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                onToggle(entry.key);
              },
              child: TweenAnimationBuilder<double>(
                key: ValueKey('${entry.key}_${entry.value}'),
                tween: Tween(begin: 0.7, end: 1),
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutBack,
                builder: (context, t, child) =>
                    Transform.scale(scale: t, child: child),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: mine.contains(entry.key)
                        ? c.accent.withValues(alpha: 0.16)
                        : c.surfaceAlt,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: mine.contains(entry.key)
                          ? c.accent
                          : c.outline,
                      width: mine.contains(entry.key) ? 1.2 : 0.8,
                    ),
                  ),
                  child: Text(
                    entry.value > 1
                        ? '${entry.key} ${entry.value}'
                        : entry.key,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: c.text),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final List<int> waveform;
  final Color color;

  _WaveformPainter({required this.waveform, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (waveform.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round;

    const bars = 28;
    final step = size.width / bars;
    final maxVal =
        waveform.reduce((a, b) => a > b ? a : b).toDouble().clamp(1.0, 1024.0);

    for (var i = 0; i < bars; i++) {
      final sample = waveform[(i * waveform.length ~/ bars)
          .clamp(0, waveform.length - 1)];
      final h = ((sample / maxVal) * size.height * 0.9)
          .clamp(3.0, size.height);
      final x = i * step + step / 2;
      canvas.drawLine(
        Offset(x, size.height / 2 - h / 2),
        Offset(x, size.height / 2 + h / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.color != color || old.waveform != waveform;
}

/// Shown in place of an event whose Megolm session key is missing.
///
/// These messages are from the WhatsApp bridge backfill that occurred before
/// the device was fully registered. The encryption keys are permanently
/// unavailable from the client side. Instead of showing ugly errors,
/// we display a clean, minimal lock icon. The user can reconnect WhatsApp
/// from the Networks screen to get a fresh backfill with working keys.
class _EncryptedMessageWidget extends StatelessWidget {
  final Event event;
  final double fontScale;
  final bool isMe;

  const _EncryptedMessageWidget({
    required this.event,
    required this.fontScale,
    required this.isMe,
  });

  @override
  Widget build(BuildContext context) {
    // Hide undecryptable messages completely. This is a much better UX for 
    // enterprise users than showing a wall of "Encrypted message" locks which 
    // looks like a bug. If they reconnect WhatsApp, fresh readable messages
    // will populate the timeline.
    return const SizedBox.shrink();
  }
}

