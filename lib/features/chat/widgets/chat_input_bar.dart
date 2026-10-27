import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:matrix/matrix.dart';
import 'package:file_picker/file_picker.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/chat_time.dart';
import '../../../data/services/ai_service.dart';
import '../../../data/services/contacts_service.dart';
import '../../../data/services/scheduled_message_service.dart';
import '../../../data/settings/app_settings.dart';
import '../../../screens/bridge/bridge_room_classifier.dart';
import '../../ai/ai_assistant_sheet.dart';
import '../../../core/utils/media_limits.dart';
import 'emoji_picker_sheet.dart';
import 'voice_recorder_dialog.dart';
import 'sticker_picker_sheet.dart';
import 'message_bubble.dart' show stripReplyFallback;
import '../../../core/utils/chat_sound_service.dart';

/// The message composer: expanding text field, emoji picker, attachment
/// sheet (gallery/camera), Allora AI assist, animated send button with
/// long-press scheduling, and reply/edit banners.
class ChatInputBar extends ConsumerStatefulWidget {
  final Room room;
  final Event? replyTo;
  final Event? editing;
  final bool disabled;
  final VoidCallback onCancelReply;
  final VoidCallback onCancelEdit;
  final Future<void> Function(String text) onSend;
  final List<AiMessage> Function() aiContextBuilder;

  const ChatInputBar({
    super.key,
    required this.room,
    required this.replyTo,
    required this.editing,
    this.disabled = false,
    required this.onCancelReply,
    required this.onCancelEdit,
    required this.onSend,
    required this.aiContextBuilder,
  });


  @override
  ConsumerState<ChatInputBar> createState() => ChatInputBarState();
}

class ChatInputBarState extends ConsumerState<ChatInputBar> {
  final controller = TextEditingController();
  final _focus = FocusNode();
  final _picker = ImagePicker();
  Timer? _typingStop;
  bool _typingSent = false;
  bool _sending = false;

  final stt.SpeechToText _speechToText = stt.SpeechToText();
  bool _isListening = false;

  bool get _hasText => controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _typingStop?.cancel();
    controller.removeListener(_onChanged);
    controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ChatInputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.editing != null && oldWidget.editing != widget.editing) {
      controller.text = stripReplyFallback(widget.editing!.body);
      controller.selection =
          TextSelection.collapsed(offset: controller.text.length);
      _focus.requestFocus();
    }
    if (widget.replyTo != null && oldWidget.replyTo != widget.replyTo) {
      _focus.requestFocus();
    }
  }

  void _onChanged() {
    setState(() {}); // cheap: only this bar rebuilds
    if (_hasText) {
      _setTyping(true);
      _typingStop?.cancel();
      _typingStop = Timer(const Duration(seconds: 6), () => _setTyping(false));
    } else {
      _setTyping(false);
    }
  }

  void _setTyping(bool typing) {
    if (!mounted) return;
    if (ref.read(settingsProvider).effectiveHideTyping) {
      debugPrint('Incognito: typing indicator suppressed');
      return;
    }
    if (typing == _typingSent) return;
    _typingSent = typing;
    widget.room.setTyping(typing).catchError((_) {});
  }

  Future<void> _send() async {
    final text = controller.text.trim();
    if (text.isEmpty || _sending) return;
    if (text.length > MediaLimits.maxMessageCharacterLimit) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Message exceeds limit of ${MediaLimits.maxMessageCharacterLimit} characters (${text.length} chars).'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }
    setState(() => _sending = true);
    HapticFeedback.lightImpact();
    controller.clear();
    _setTyping(false);
    try {
      await widget.onSend(text);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // ── Scheduling ────────────────────────────────────────────────────────────

  Future<void> _scheduleSend() async {
    final text = controller.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.mediumImpact();

    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Schedule message',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
      helpText: 'Send at',
    );
    if (time == null || !mounted) return;

    final sendAt =
        DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (sendAt.isBefore(now)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That time is in the past.')));
      return;
    }

    await ScheduledMessageService.schedule(
      widget.room.client,
      roomId: widget.room.id,
      roomName: widget.room.displayname,
      body: text,
      sendAt: sendAt,
    );
    controller.clear();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Scheduled for ${ChatTime.dayHeader(sendAt)} at ${ChatTime.hourMinute(sendAt)}')));
    }
  }

  // ── Attachments ───────────────────────────────────────────────────────────

  Future<void> _openAttachSheet() async {
    final c = context.allora;
    HapticFeedback.selectionClick();
    await showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: c.textTertiary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Wrap(
                alignment: WrapAlignment.spaceEvenly,
                spacing: 12,
                runSpacing: 16,
                children: [
                  _attachOption(ctx, Icons.photo_library_rounded, 'Gallery',
                      const Color(0xFF3A6FF8), _pickAndSendGallery),
                  _attachOption(ctx, Icons.photo_camera_rounded, 'Camera',
                      const Color(0xFF1FA45B), _pickAndSendCamera),
                  _attachOption(ctx, Icons.insert_drive_file_rounded, 'Document\n(≤2 GB)',
                      const Color(0xFF007AFF), _pickAndSendDocument),
                  _attachOption(ctx, Icons.audiotrack_rounded, 'Audio\n(≤16 MB)',
                      const Color(0xFFE91E63), _pickAndSendAudio),
                  _attachOption(ctx, Icons.mic_rounded, 'Voice Note',
                      const Color(0xFFFF9500), _recordAndSendVoiceNote),
                  _attachOption(ctx, Icons.emoji_emotions_rounded, 'Stickers\n(WebP)',
                      const Color(0xFF00BFA5), _openStickers),
                  _attachOption(ctx, Icons.auto_awesome_rounded, 'Allora AI',
                      const Color(0xFF7C5CFC), _openAi),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _attachOption(BuildContext sheetContext, IconData icon, String label,
      Color color, VoidCallback onTap) {
    final c = context.allora;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        Navigator.pop(sheetContext);
        onTap();
      },
      child: Container(
        width: 76,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(icon, color: color, size: 26),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: c.textSecondary,
                height: 1.15,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 1. Document (All Formats, ≤2 GB) ───────────────────────────────────────

  Future<void> _pickAndSendDocument() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null || !mounted) return;

      final error = MediaLimits.validateFile(
        filename: file.name,
        sizeBytes: bytes.length,
        category: 'document',
      );
      if (error != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(error), backgroundColor: Colors.redAccent),
          );
        }
        return;
      }

      final messenger = ScaffoldMessenger.of(context);
      try {
        final mimeType = MediaLimits.resolveMimeType(file.name);
        final matrixFile = MatrixFile(
          bytes: bytes,
          name: file.name,
          mimeType: mimeType,
        );
        await widget.room.sendFileEvent(
          matrixFile,
          inReplyTo: widget.replyTo,
        );
        ChatSoundService.playSentSound();
        widget.onCancelReply();
      } catch (e) {
        ChatSoundService.playFailSound();
        messenger.showSnackBar(
            const SnackBar(content: Text('Document upload failed. Try again.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open file picker.')));
      }
    }
  }

  // ── 2. Gallery (Images ≤16 MB, Videos ≤16 MB / ≤2 GB Document) ───────────

  Future<void> _pickAndSendGallery() async {
    try {
      final file = await _picker.pickMedia();
      if (file == null || !mounted) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;

      final isVideo = MediaLimits.isVideo(file.name) || file.mimeType?.startsWith('video/') == true;
      final size = bytes.length;

      if (isVideo) {
        if (size > MediaLimits.maxDocumentVideoBytes) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Video exceeds 2 GB limit (${MediaLimits.formatBytes(size)}).'),
              backgroundColor: Colors.redAccent,
            ),
          );
          return;
        }

        final caption = await _confirmMediaPreview(bytes, file.name, isVideo: true);
        if (caption == null || !mounted) return;

        final messenger = ScaffoldMessenger.of(context);
        try {
          if (size <= MediaLimits.maxMediaVideoBytes) {
            final matrixFile = MatrixVideoFile(bytes: bytes, name: file.name);
            await widget.room.sendFileEvent(matrixFile, inReplyTo: widget.replyTo);
          } else {
            // Send as high quality video document
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                    'Sending video as document (${MediaLimits.formatBytes(size)}).'),
              ),
            );
            final matrixFile = MatrixFile(
              bytes: bytes,
              name: file.name,
              mimeType: MediaLimits.resolveMimeType(file.name, defaultMime: 'video/mp4'),
            );
            await widget.room.sendFileEvent(matrixFile, inReplyTo: widget.replyTo);
          }

          if (caption.trim().isNotEmpty) {
            await widget.room.sendTextEvent(caption.trim());
          }
          ChatSoundService.playSentSound();
          widget.onCancelReply();
        } catch (e) {
          ChatSoundService.playFailSound();
          messenger.showSnackBar(
              const SnackBar(content: Text('Video upload failed. Try again.')));
        }
      } else {
        // Image
        if (size > MediaLimits.maxImageBytes) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Image exceeds 16 MB limit (${MediaLimits.formatBytes(size)}).'),
              backgroundColor: Colors.redAccent,
            ),
          );
          return;
        }

        final caption = await _confirmMediaPreview(bytes, file.name, isVideo: false);
        if (caption == null || !mounted) return;

        final messenger = ScaffoldMessenger.of(context);
        try {
          final matrixFile = MatrixImageFile(bytes: bytes, name: file.name);
          await widget.room.sendFileEvent(matrixFile, inReplyTo: widget.replyTo);
          if (caption.trim().isNotEmpty) {
            await widget.room.sendTextEvent(caption.trim());
          }
          ChatSoundService.playSentSound();
          widget.onCancelReply();
        } catch (e) {
          ChatSoundService.playFailSound();
          messenger.showSnackBar(
              const SnackBar(content: Text('Image upload failed. Try again.')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open gallery.')));
      }
    }
  }

  // ── 3. Camera (Photo & Video Capture) ─────────────────────────────────────

  Future<void> _pickAndSendCamera() async {
    final c = context.allora;
    final mode = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: c.accent.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.camera_alt_rounded, color: c.accent),
                ),
                title: const Text('Take Photo', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Capture picture (≤16 MB)', style: TextStyle(fontSize: 12)),
                onTap: () => Navigator.pop(ctx, 'photo'),
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.deepOrange.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.videocam_rounded, color: Colors.deepOrange),
                ),
                title: const Text('Record Video', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Capture video (≤16 MB media / ≤2 GB doc)', style: TextStyle(fontSize: 12)),
                onTap: () => Navigator.pop(ctx, 'video'),
              ),
            ],
          ),
        ),
      ),
    );

    if (mode == null || !mounted) return;

    try {
      XFile? file;
      if (mode == 'photo') {
        file = await _picker.pickImage(source: ImageSource.camera, imageQuality: 88);
      } else {
        file = await _picker.pickVideo(source: ImageSource.camera);
      }

      if (file == null || !mounted) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;

      final isVideo = mode == 'video';
      final caption = await _confirmMediaPreview(bytes, file.name, isVideo: isVideo);
      if (caption == null || !mounted) return;

      final messenger = ScaffoldMessenger.of(context);
      try {
        if (isVideo) {
          final matrixFile = bytes.length <= MediaLimits.maxMediaVideoBytes
              ? MatrixVideoFile(bytes: bytes, name: file.name)
              : MatrixFile(
                  bytes: bytes,
                  name: file.name,
                  mimeType: MediaLimits.resolveMimeType(file.name, defaultMime: 'video/mp4'));
          await widget.room.sendFileEvent(matrixFile, inReplyTo: widget.replyTo);
        } else {
          final matrixFile = MatrixImageFile(bytes: bytes, name: file.name);
          await widget.room.sendFileEvent(matrixFile, inReplyTo: widget.replyTo);
        }

        if (caption.trim().isNotEmpty) {
          await widget.room.sendTextEvent(caption.trim());
        }
        ChatSoundService.playSentSound();
        widget.onCancelReply();
      } catch (e) {
        ChatSoundService.playFailSound();
        messenger.showSnackBar(
            const SnackBar(content: Text('Upload failed. Try again.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Camera unavailable.')));
      }
    }
  }

  // ── 4. Audio Files (AAC, MP3, AMR, M4A, OGG, WAV, ≤16 MB) ─────────────────

  Future<void> _pickAndSendAudio() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['aac', 'mp3', 'amr', 'm4a', 'ogg', 'opus', 'wav', 'flac', 'wma'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null || !mounted) return;

      final error = MediaLimits.validateFile(
        filename: file.name,
        sizeBytes: bytes.length,
        category: 'audio',
      );
      if (error != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(error), backgroundColor: Colors.redAccent),
          );
        }
        return;
      }

      final messenger = ScaffoldMessenger.of(context);
      try {
        final matrixFile = MatrixAudioFile(bytes: bytes, name: file.name);
        await widget.room.sendFileEvent(matrixFile, inReplyTo: widget.replyTo);
        ChatSoundService.playSentSound();
        widget.onCancelReply();
        messenger.showSnackBar(
          SnackBar(content: Text('Audio "${file.name}" sent.')),
        );
      } catch (e) {
        ChatSoundService.playFailSound();
        messenger.showSnackBar(
            const SnackBar(content: Text('Audio upload failed. Try again.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open audio picker.')));
      }
    }
  }

  // ── 5. Voice Note (Live Mic, ≤16 MB) ──────────────────────────────────────

  Future<void> _recordAndSendVoiceNote() async {
    final result = await VoiceRecorderDialog.show(context);
    if (result == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final matrixFile = MatrixAudioFile(
        bytes: result.bytes,
        name: result.filename,
      );

      await widget.room.sendFileEvent(
        matrixFile,
        inReplyTo: widget.replyTo,
        extraContent: {
          'org.matrix.msc1767.audio': {
            'duration': result.duration.inMilliseconds,
            'waveform': result.waveform,
          },
          'org.matrix.msc3245.voice': {},
        },
      );
      ChatSoundService.playSentSound();
      widget.onCancelReply();
    } catch (e) {
      ChatSoundService.playFailSound();
      messenger.showSnackBar(
        const SnackBar(content: Text('Failed to send voice note. Try again.')),
      );
    }
  }

  // ── 6. Stickers (WebP Static ≤100 KB / Animated ≤500 KB) ───────────────────

  Future<void> _openStickers() async {
    final sticker = await StickerPickerSheet.show(context);
    if (sticker == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final mxcUri = await widget.room.client.uploadContent(
        sticker.bytes,
        filename: sticker.filename,
        contentType: 'image/webp',
      );

      await widget.room.sendEvent(
        {
          'body': sticker.filename,
          'url': mxcUri.toString(),
          'info': {
            'mimetype': 'image/webp',
            'size': sticker.bytes.length,
          },
        },
        type: EventTypes.Sticker,
        inReplyTo: widget.replyTo,
      );
      ChatSoundService.playSentSound();
      widget.onCancelReply();
    } catch (e) {
      ChatSoundService.playFailSound();
      messenger.showSnackBar(
        const SnackBar(content: Text('Failed to send sticker. Try again.')),
      );
    }
  }

  /// Preview dialog before sending image or video; returns caption or null.
  Future<String?> _confirmMediaPreview(Uint8List bytes, String name, {bool isVideo = false}) {
    final captionController = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = ctx.allora;
        return Dialog(
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(ctx).size.height * 0.45),
                child: isVideo
                    ? Container(
                        color: Colors.black,
                        height: 220,
                        alignment: Alignment.center,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.videocam_rounded, color: Colors.white, size: 54),
                            const SizedBox(height: 8),
                            Text(
                              name,
                              style: const TextStyle(color: Colors.white, fontSize: 13),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              MediaLimits.formatBytes(bytes.length),
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                          ],
                        ),
                      )
                    : Image.memory(bytes, fit: BoxFit.contain),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: captionController,
                        decoration:
                            const InputDecoration(hintText: 'Add a caption…'),
                        maxLines: 2,
                        minLines: 1,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      style: IconButton.styleFrom(backgroundColor: c.accent),
                      onPressed: () =>
                          Navigator.pop(ctx, captionController.text),
                      icon: const Icon(Icons.send_rounded,
                          color: Colors.white, size: 20),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }


  // ── AI & emoji ────────────────────────────────────────────────────────────

  Future<void> _openAi() async {
    final settings = ref.read(settingsProvider);
    if (!settings.aiEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Allora AI is turned off in Settings → AI Assistant.')));
      return;
    }
    final result = await showAiAssistantSheet(
      context,
      draft: controller.text,
      contextBuilder: widget.aiContextBuilder,
      translateLanguage: settings.aiTranslateLanguage,
    );
    if (result != null && result.trim().isNotEmpty) {
      controller.text = result.trim();
      controller.selection =
          TextSelection.collapsed(offset: controller.text.length);
      _focus.requestFocus();
    }
  }

  Future<void> _openEmoji() async {
    final emoji = await showEmojiPicker(context);
    if (emoji == null) return;
    final sel = controller.selection;
    final text = controller.text;
    final insertAt = sel.isValid ? sel.start : text.length;
    controller.text = text.replaceRange(insertAt, sel.isValid ? sel.end : insertAt, emoji);
    controller.selection =
        TextSelection.collapsed(offset: insertAt + emoji.length);
    _focus.requestFocus();
  }

  Future<void> _toggleListening() async {
    if (_isListening) {
      await _speechToText.stop();
      if (mounted) setState(() => _isListening = false);
    } else {
      bool available = await _speechToText.initialize();
      if (available) {
        if (mounted) setState(() => _isListening = true);
        final currentText = controller.text;
        final prefix = currentText.isNotEmpty && !currentText.endsWith(' ') ? '$currentText ' : currentText;
        _speechToText.listen(onResult: (result) {
          if (!mounted) return;
          controller.text = prefix + result.recognizedWords;
          controller.selection = TextSelection.collapsed(offset: controller.text.length);
          if (result.finalResult) {
            setState(() => _isListening = false);
          }
        });
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Speech recognition not available')),
          );
        }
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  String _getReplyTitle(Event replyTo) {
    final myId = widget.room.client.userID;
    final isMe = replyTo.senderId == myId ||
        (widget.room.isDirectChat &&
            replyTo.senderId != widget.room.directChatMatrixID &&
            !replyTo.senderId.split(':').first.toLowerCase().endsWith('bot') &&
            !replyTo.senderId.split(':').first.toLowerCase().contains('bridge'));
    if (isMe) {
      return 'Replying to yourself';
    }
    if (BridgeRoomClassifier.isDirectChat(widget.room, client: widget.room.client)) {
      final name = ref.read(contactsProvider.notifier).resolveContactHierarchy(
        room: widget.room,
        senderId: replyTo.senderId,
      );
      return 'Replying to $name';
    }
    final fallback = replyTo.senderFromMemoryOrFallback.calcDisplayname();
    final name = ref.read(contactsProvider.notifier).resolveName(replyTo.senderId, fallback);
    return 'Replying to $name';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.allora;

    final canSend = widget.room.canSendEvent(EventTypes.Message);
    final isJoined = widget.room.membership == Membership.join;
    final isReadOnlyGroup = !canSend || !isJoined;

    if (widget.disabled || isReadOnlyGroup) {
      final message = !isJoined
          ? 'You are not a member of this chat'
          : !canSend
              ? 'Only admins can send messages'
              : 'Sending unavailable';
      final icon = !isJoined
          ? Icons.group_off_outlined
          : !canSend
              ? Icons.lock_outline_rounded
              : Icons.cloud_off_rounded;

      return Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(top: BorderSide(color: c.outline, width: 0.8)),
        ),
        padding: EdgeInsets.only(
          top: 14,
          bottom: 14 + MediaQuery.of(context).padding.bottom,
          left: 16,
          right: 16,
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: c.textTertiary),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: c.textSecondary,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final banner = widget.editing != null

        ? _banner(
            icon: Icons.edit_rounded,
            title: 'Editing message',
            body: stripReplyFallback(widget.editing!.body),
            onCancel: () {
              controller.clear();
              widget.onCancelEdit();
            },
          )
        : widget.replyTo != null
            ? _banner(
                icon: Icons.reply_rounded,
                title: _getReplyTitle(widget.replyTo!),
                body: stripReplyFallback(widget.replyTo!.body),
                onCancel: widget.onCancelReply,
              )
            : null;

    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.outline)),
      ),
      padding: EdgeInsets.only(
        left: 6,
        right: 8,
        top: 6,
        bottom: 6 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (banner != null) banner,
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Attach',
                onPressed: _openAttachSheet,
                icon: Icon(Icons.add_circle_outline_rounded,
                    color: c.textSecondary, size: 24),
              ),
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 140),
                  decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: controller,
                          focusNode: _focus,
                          minLines: 1,
                          maxLines: 5,
                          maxLength: MediaLimits.maxMessageCharacterLimit,
                          buildCounter: (context, {required currentLength, required isFocused, maxLength}) {
                            if (currentLength > 60000) {
                              return Padding(
                                padding: const EdgeInsets.only(right: 8, bottom: 4),
                                child: Text(
                                  '${maxLength! - currentLength} chars left',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: c.danger,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              );
                            }
                            return null;
                          },
                          textCapitalization: TextCapitalization.sentences,
                          keyboardType: TextInputType.multiline,
                          style: TextStyle(fontSize: 15.5, color: c.text),
                          decoration: const InputDecoration(
                            hintText: 'Message',
                            counterText: '',
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: EdgeInsets.fromLTRB(16, 10, 4, 10),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Emoji',
                        onPressed: _openEmoji,
                        icon: Icon(Icons.emoji_emotions_outlined,
                            color: c.textTertiary, size: 22),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              if (!_hasText && ref.watch(settingsProvider.select((s) => s.voiceAiEnabled)))
                IconButton(
                  tooltip: 'Voice AI Dictation',
                  onPressed: _toggleListening,
                  icon: Icon(_isListening ? Icons.mic_rounded : Icons.mic_none_rounded,
                      color: _isListening ? c.danger : c.textSecondary, size: 24),
                ),
              _hasText
                  ? GestureDetector(
                      onLongPress: _scheduleSend,
                      child: AnimatedScale(
                        scale: 1,
                        duration: const Duration(milliseconds: 150),
                        child: IconButton.filled(
                          tooltip: 'Send (hold to schedule)',
                          style: IconButton.styleFrom(
                            backgroundColor: c.accent,
                            minimumSize: const Size(44, 44),
                          ),
                          onPressed: _sending ? null : _send,
                          icon: const Icon(Icons.arrow_upward_rounded,
                              color: Colors.white, size: 22),
                        ),
                      ),
                    )
                  : IconButton(
                      tooltip: 'Allora AI',
                      onPressed: _openAi,
                      icon: ShaderMask(
                        shaderCallback: (r) => LinearGradient(
                                colors: [c.accent, c.bubbleMineDeep])
                            .createShader(r),
                        child: const Icon(Icons.auto_awesome_rounded,
                            color: Colors.white, size: 24),
                      ),
                    ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _banner({
    required IconData icon,
    required String title,
    required String body,
    required VoidCallback onCancel,
  }) {
    final c = context.allora;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: c.accent.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 17, color: c.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: c.accent)),
                Text(body.replaceAll('\n', ' '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(fontSize: 12.5, color: c.textSecondary)),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: onCancel,
            icon: Icon(Icons.close_rounded, size: 18, color: c.textSecondary),
          ),
        ],
      ),
    );
  }
}
