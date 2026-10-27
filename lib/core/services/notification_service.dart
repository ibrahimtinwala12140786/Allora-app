import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../screens/bridge/bridge_room_classifier.dart';
import '../../screens/networks/network_meta.dart';
import '../../features/chat_list/chat_list_providers.dart' show cleanRoomTitle;
import '../../data/services/contacts_service.dart';
import '../utils/chat_sound_service.dart';
import '../utils/matrix_media.dart';
import '../widgets/allora_avatar.dart';

/// Notification service that intercepts incoming messages from any platform
/// (WhatsApp, Telegram, Instagram, Signal, Messenger, etc.) and posts
/// native notifications titled "Allora • [Platform Name]" with:
///  - Contact display name and message preview
///  - AI Smart Reply suggestions (one-touch reply buttons & RemoteInput choices)
///  - Android Direct Reply action (RemoteInput)
///  - Quick "👍 Like" reaction action
///  - Active room suppression (no notifications if chat is currently open)
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const MethodChannel _channel =
      MethodChannel('app.allorachat.messenger/notifications');

  Client? _client;
  StreamSubscription<Event>? _timelineSub;
  StreamSubscription<SyncUpdate>? _syncSub;
  String? _activeRoomId;

  final Set<String> _notifiedEventIds = {};
  final Map<String, List<String>> _recentRoomImages = {};

  void init(Client client) {
    if (_client == client) return;
    _client = client;
    _timelineSub?.cancel();
    _syncSub?.cancel();

    _channel.setMethodCallHandler(_handleNativeCall);
    _timelineSub = client.onTimelineEvent.stream.listen(_onTimelineEvent);
    _syncSub = client.onSync.stream.listen(_onSyncUpdate);

    requestPermission();
  }

  Future<void> requestPermission() async {
    try {
      await Permission.notification.request();
    } catch (e) {
      debugPrint('NotificationService requestPermission error: $e');
    }
  }

  /// Sets the currently viewed room ID so incoming messages in this room
  /// don't trigger notification popups while the user is actively reading them.
  void setActiveRoom(String? roomId) {
    _activeRoomId = roomId;
    try {
      _channel.invokeMethod('setActiveRoom', {'roomId': roomId});
    } catch (_) {}
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onNotificationReply':
        final roomId = call.arguments['roomId'] as String?;
        final text = call.arguments['text'] as String?;
        if (roomId != null && text != null && text.trim().isNotEmpty) {
          await _sendReply(roomId, text.trim());
        }
        break;

      case 'onNotificationLike':
        final roomId = call.arguments['roomId'] as String?;
        final eventId = call.arguments['eventId'] as String?;
        if (roomId != null && eventId != null && eventId.isNotEmpty) {
          await _sendLike(roomId, eventId);
        }
        break;
    }
  }

  Future<void> _sendReply(String roomId, String text) async {
    final client = _client;
    if (client == null) return;
    final room = client.getRoomById(roomId);
    if (room == null) return;

    try {
      await room.sendTextEvent(text);
      await ChatSoundService.playSentSound();
    } catch (e) {
      debugPrint('NotificationService error sending reply: $e');
    }
  }

  Future<void> _sendLike(String roomId, String eventId) async {
    final client = _client;
    if (client == null) return;
    final room = client.getRoomById(roomId);
    if (room == null) return;

    try {
      // Send Matrix reaction annotation (👍)
      await room.sendEvent({
        'm.relates_to': {
          'rel_type': 'm.annotation',
          'event_id': eventId,
          'key': '👍',
        },
      }, type: EventTypes.Reaction);
      await ChatSoundService.playSentSound();
    } catch (e) {
      debugPrint('NotificationService error sending like: $e');
    }
  }

  void _onTimelineEvent(Event event) {
    final client = _client;
    if (client == null) return;
    final roomId = event.roomId;
    if (roomId == null) return;
    final room = client.getRoomById(roomId);
    if (room == null) return;
    if (isStatusOrStoryRoom(room, event: event)) return;

    _processEvent(room, event);
  }

  void _onSyncUpdate(SyncUpdate _) {
    final client = _client;
    if (client == null) return;

    for (final room in client.rooms) {
      if (isStatusOrStoryRoom(room)) continue;
      if (room.notificationCount > 0 && room.lastEvent != null) {
        final ev = room.lastEvent!;
        if (!_notifiedEventIds.contains(ev.eventId)) {
          _processEvent(room, ev);
        }
      }
    }
  }

  Future<void> _processEvent(Room room, Event event) async {
    final client = _client;
    if (client == null) return;

    // Never notify for status broadcast, stories, or status updates from any social media
    if (isStatusOrStoryRoom(room, event: event)) {
      return;
    }

    // Only notify on messages or stickers
    if (event.type != EventTypes.Message &&
        event.type != EventTypes.Encrypted &&
        event.type != 'm.sticker') {
      return;
    }

    // Ignore messages sent by ourselves
    if (event.senderId == client.userID) {
      return;
    }

    final roomId = room.id;
    // Don't show notification if the user is already viewing this room
    if (_activeRoomId != null && _activeRoomId == roomId) {
      return;
    }

    // Ignore bridge management bot rooms (e.g. WhatsApp bridge bot, Telegram bot status logs)
    if (BridgeRoomClassifier.isManagementRoom(room, client: client) ||
        BridgeRoomClassifier.isEmptyOrGhostRoom(room, client: client)) {
      return;
    }

    // Deduplicate
    if (_notifiedEventIds.contains(event.eventId)) {
      return;
    }
    _notifiedEventIds.add(event.eventId);
    if (_notifiedEventIds.length > 200) {
      _notifiedEventIds.remove(_notifiedEventIds.first);
    }

    // Ignore messages older than 10 minutes (prevents spam on backfill / sync)
    final age = DateTime.now().difference(event.originServerTs);
    if (age > const Duration(minutes: 10)) {
      return;
    }

    // Identify platform with robust fallbacks
    String platform = '';
    final netId = BridgeRoomClassifier.classify(room, client: client);
    if (netId != null) {
      platform = metaFor(netId).botAlias;
    } else {
      final lowerSender = event.senderId.toLowerCase();
      final lowerRoom = roomId.toLowerCase();
      if (lowerSender.contains('whatsapp') ||
          lowerSender.contains('wa_') ||
          lowerSender.contains('s.whatsapp.net') ||
          lowerRoom.contains('whatsapp') ||
          lowerRoom.contains('_wa_')) {
        platform = 'whatsapp';
      } else if (lowerSender.contains('telegram') ||
          lowerSender.contains('tg_') ||
          lowerRoom.contains('telegram') ||
          lowerRoom.contains('_tg_')) {
        platform = 'telegram';
      } else if (lowerSender.contains('instagram') ||
          lowerSender.contains('ig_') ||
          lowerRoom.contains('instagram') ||
          lowerRoom.contains('_ig_')) {
        platform = 'instagram';
      } else if (lowerSender.contains('messenger') ||
          lowerSender.contains('facebook') ||
          lowerSender.contains('fb_')) {
        platform = 'messenger';
      } else if (lowerSender.contains('discord')) {
        platform = 'discord';
      } else if (lowerSender.contains('slack')) {
        platform = 'slack';
      } else if (lowerSender.contains('twitter') ||
          lowerSender.contains('x_')) {
        platform = 'x';
      } else {
        for (final p in room.getParticipants()) {
          final pid = p.id.toLowerCase();
          if (pid.contains('whatsapp')) {
            platform = 'whatsapp';
            break;
          }
          if (pid.contains('telegram')) {
            platform = 'telegram';
            break;
          }
          if (pid.contains('instagram')) {
            platform = 'instagram';
            break;
          }
        }
      }
    }

    final netMeta = platform.isNotEmpty ? metaForAlias(platform) : null;
    final platformTitle = netMeta != null
        ? 'Allora • ${netMeta.displayName}'
        : 'Allora • Message';

    // Sender display name resolved strictly via contact hierarchy:
    // 1. Device Contacts -> 2. Social Contact Name -> 3. Social Push/Profile Name -> 4. Phone/Handle
    String senderName = ContactsNotifier.instance.resolveContactHierarchy(
      room: room,
      event: event,
    );
    if (senderName.trim().isEmpty || ContactsNotifier.isBotDisplayName(senderName)) {
      senderName = cleanRoomTitle(room.getLocalizedDisplayname());
      if (senderName.trim().isEmpty || ContactsNotifier.isBotDisplayName(senderName)) {
        senderName = netMeta != null ? '${netMeta.displayName} Message' : 'Message';
      }
    }

    // Snippet (kept clear and readable without blur per user request)
    final messageSnippet = _formatSnippet(event);
    if (messageSnippet.trim().isEmpty) return;

    // Detect OTP / verification codes and official account status
    final otpResult = _detectOtpAndSensitivity(
      messageSnippet,
      senderName,
      event.senderId,
      platform,
    );
    final isSensitive = otpResult.isSensitive;
    final otpCode = otpResult.otpCode;

    // Generate AI Smart Replies only if NOT sensitive/OTP
    final suggestions = isSensitive
        ? const <String>[]
        : _generateSmartReplies(messageSnippet);

    final brandColor = netMeta?.brandColor.toARGB32() ?? 0xFF00C853;
    final notifId = (roomId.hashCode ^ event.eventId.hashCode).abs() % 100000;

    // Resolve media & avatar attachments for rich notifications
    final msgType = event.content['msgtype'] as String? ?? '';
    final info = event.content['info'];
    String mimetype = '';
    if (info is Map && info['mimetype'] is String) {
      mimetype = (info['mimetype'] as String).toLowerCase();
    } else if (event.content['mimetype'] is String) {
      mimetype = (event.content['mimetype'] as String).toLowerCase();
    }

    String? imagePath;
    List<String> imagePaths = [];
    if (msgType == 'm.image' || mimetype.startsWith('image/')) {
      imagePath = await _downloadMediaAttachment(
        event,
        'img_${event.eventId.hashCode}.jpg',
      );
      if (imagePath != null) {
        final list = _recentRoomImages.putIfAbsent(roomId, () => []);
        list.add(imagePath);
        if (list.length > 5) list.removeAt(0);
        imagePaths = List<String>.from(list);
      }
    }

    String? audioPath;
    if (msgType == 'm.audio' ||
        mimetype.startsWith('audio/') ||
        event.content['org.matrix.msc3245.voice'] != null ||
        event.content['org.matrix.msc1767.audio'] != null) {
      audioPath = await _downloadMediaAttachment(
        event,
        'audio_${event.eventId.hashCode}.m4a',
      );
    }

    // Resolve sender's social avatar photo
    final avatarPath = await _resolveAndDownloadAvatar(room, event);

    debugPrint(
        '🔔 Posting notification: $platformTitle -> $senderName: $messageSnippet, otp: $otpCode, sensitive: $isSensitive');

    try {
      _channel.invokeMethod('showNotification', {
        'id': notifId,
        'title': platformTitle,
        'sender': senderName,
        'rawSenderId': event.senderId,
        'message': messageSnippet,
        'roomId': roomId,
        'eventId': event.eventId,
        'brandColor': brandColor,
        'platform': platform,
        'suggestions': suggestions,
        'avatarPath': avatarPath,
        'imagePath': imagePath,
        'imagePaths': imagePaths,
        'audioPath': audioPath,
        'isSensitive': isSensitive,
        'otpCode': otpCode,
      });
    } catch (e) {
      debugPrint('NotificationService showNotification error: $e');
    }
  }

  Future<String?> _downloadMediaAttachment(Event event, String filename) async {
    final client = _client;
    if (client == null) return null;
    try {
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/$filename');
      if (await file.exists() && (await file.length()) > 0) {
        return file.path;
      }

      final mxc = MatrixMedia.mxcOf(event);
      final source = MatrixMedia.download(client, mxc);
      if (event.isAttachmentEncrypted) {
        final matrixFile = await event.downloadAndDecryptAttachment();
        if (matrixFile.bytes.isNotEmpty) {
          await file.writeAsBytes(matrixFile.bytes);
          return file.path;
        }
      } else if (source != null) {
        final res = await http.get(Uri.parse(source.url), headers: source.headers);
        if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
          await file.writeAsBytes(res.bodyBytes);
          return file.path;
        }
      }
      final matrixFile = await event.downloadAndDecryptAttachment();
      if (matrixFile.bytes.isNotEmpty) {
        await file.writeAsBytes(matrixFile.bytes);
        return file.path;
      }
    } catch (e) {
      debugPrint('NotificationService _downloadMediaAttachment error: $e');
    }
    return null;
  }

  Future<String?> _resolveAndDownloadAvatar(Room room, Event event) async {
    final client = _client;
    if (client == null) return null;
    try {
      String? avatarMxc;
      final senderMember = room.getState('m.room.member', event.senderId);
      final memberAvatar = senderMember?.content['avatar_url'];
      if (memberAvatar is String && memberAvatar.isNotEmpty) {
        avatarMxc = memberAvatar;
      }
      avatarMxc ??= event.senderFromMemoryOrFallback.avatarUrl?.toString();
      avatarMxc ??= AlloraAvatar.resolveUri(room)?.toString();
      avatarMxc ??= room.avatar?.toString();
      final roomStateAvatar = room.getState('m.room.avatar')?.content['url'];
      if (roomStateAvatar is String && roomStateAvatar.isNotEmpty) {
        avatarMxc ??= roomStateAvatar;
      }
      if (avatarMxc == null) {
        for (final user in room.getParticipants()) {
          if (user.id == client.userID) continue;
          if (user.id.startsWith('@whatsappbot') ||
              user.id.startsWith('@telegrambot') ||
              user.id.startsWith('@bridge')) {
            continue;
          }
          if (user.avatarUrl != null) {
            avatarMxc = user.avatarUrl.toString();
            break;
          }
        }
      }
      if (avatarMxc == null || avatarMxc.isEmpty) return null;

      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/avatar_${event.senderId.hashCode}.jpg');
      if (await file.exists() && (await file.length()) > 0) {
        return file.path;
      }

      final src = MatrixMedia.thumbnail(client, avatarMxc, width: 256, height: 256) ??
          MatrixMedia.download(client, avatarMxc);
      if (src != null) {
        final res = await http.get(Uri.parse(src.url), headers: src.headers);
        if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
          await file.writeAsBytes(res.bodyBytes);
          return file.path;
        }
      }

      // Homeserver direct fallback
      if (avatarMxc.startsWith('mxc://')) {
        final parts = avatarMxc.substring(6).split('/');
        if (parts.length >= 2) {
          final server = parts[0];
          final mediaId = parts[1];
          final base = client.homeserver?.toString().replaceAll(RegExp(r'/+$'), '') ?? '';
          if (base.isNotEmpty) {
            final fallbackUrl = '$base/_matrix/media/v3/download/$server/$mediaId';
            final res2 = await http.get(Uri.parse(fallbackUrl), headers: {
              if (client.accessToken != null) 'Authorization': 'Bearer ${client.accessToken}'
            });
            if (res2.statusCode == 200 && res2.bodyBytes.isNotEmpty) {
              await file.writeAsBytes(res2.bodyBytes);
              return file.path;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('NotificationService _resolveAndDownloadAvatar error: $e');
    }
    return null;
  }

  /// Context-aware AI smart replies for incoming messages
  List<String> _generateSmartReplies(String message) {
    final lower = message.trim().toLowerCase();
    if (lower.isEmpty) return const ['Okay 👍', 'Thanks!'];

    if (lower == 'hi' ||
        lower == 'hello' ||
        lower == 'hey' ||
        lower.startsWith('hi ') ||
        lower.startsWith('hey ') ||
        lower.startsWith('hello ')) {
      return const ['Hey! 👋', 'Hello! How are you?', 'Hi, what\'s up?'];
    }

    if (lower.contains('how are you') ||
        lower.contains('kaisa') ||
        lower.contains('how r u') ||
        lower.contains('whats up') ||
        lower.contains("what's up")) {
      return const ['I\'m good, thanks! 😊', 'All good! You?', 'Doing great!'];
    }

    if (lower.contains('thank') ||
        lower.contains('thx') ||
        lower.contains('shukriya')) {
      return const ['You\'re welcome! 😊', 'Anytime!', 'No problem!'];
    }

    if (lower.contains('where are you') ||
        lower.contains('kaha ho') ||
        lower.contains('where r u')) {
      return const ['On my way! 🏃', 'At home', 'Almost there'];
    }

    if (lower.contains('ok') ||
        lower.contains('okay') ||
        lower.contains('done') ||
        lower.contains('sure') ||
        lower.contains('theek')) {
      return const ['Sounds good! 👍', 'Great!', 'Perfect'];
    }

    if (lower.contains('yes') ||
        lower.contains('ha') ||
        lower.contains('haa') ||
        lower.contains('yeah')) {
      return const ['Great! 👍', 'Sure thing!', 'Awesome'];
    }

    if (lower.contains('no') ||
        lower.contains('nahi') ||
        lower.contains('nah')) {
      return const ['Understood 👍', 'No worries!', 'Okay'];
    }

    if (lower.contains('?')) {
      return const ['Yes 👍', 'No', 'Let me check!'];
    }

    return const ['Okay 👍', 'Got it!', 'Sure!'];
  }

  String _formatSnippet(Event event) {
    final msgType = event.content['msgtype'] as String? ?? '';
    final info = event.content['info'];
    String mimetype = '';
    if (info is Map && info['mimetype'] is String) {
      mimetype = (info['mimetype'] as String).toLowerCase();
    } else if (event.content['mimetype'] is String) {
      mimetype = (event.content['mimetype'] as String).toLowerCase();
    }

    var body = event.content['body']?.toString().trim() ?? '';
    if (body.isEmpty) {
      final mscText = event.content['org.matrix.msc1767.text'];
      if (mscText is String) body = mscText.trim();
    }
    if (body.toLowerCase().startsWith('unknown message format')) body = '';
    if (body.startsWith('m.room.')) body = '';

    // Stickers
    if (event.type == EventTypes.Sticker ||
        event.type == 'm.sticker' ||
        msgType == 'm.sticker' ||
        mimetype == 'image/webp.sticker') {
      return '🎨 Sticker';
    }

    // Photos
    if (msgType == 'm.image' || mimetype.startsWith('image/')) {
      return body.isNotEmpty ? '📷 $body' : '📷 Photo';
    }

    // Videos
    if (msgType == 'm.video' || mimetype.startsWith('video/')) {
      return body.isNotEmpty ? '🎥 $body' : '🎥 Video';
    }

    // Audio & Voice Notes
    if (msgType == 'm.audio' ||
        mimetype.startsWith('audio/') ||
        event.content['org.matrix.msc3245.voice'] != null ||
        event.content['org.matrix.msc1767.audio'] != null) {
      return '🎤 Voice message';
    }

    // Locations
    if (msgType == 'm.location' ||
        (event.content['geo_uri'] is String && (event.content['geo_uri'] as String).isNotEmpty)) {
      return '📍 Location';
    }

    // Contacts
    if (msgType == 'm.contact' || mimetype.contains('vcard') || body.startsWith('BEGIN:VCARD')) {
      return '👤 Contact';
    }

    // Documents & Files
    if (msgType == 'm.file' || event.content['url'] != null || event.content['file'] != null) {
      String fn = event.content['filename']?.toString().trim() ??
          (info is Map ? info['name']?.toString().trim() ?? '' : '');
      if (fn.isEmpty && body.isNotEmpty && !body.contains('\n') && body.length < 40) {
        fn = body;
      }
      return fn.isNotEmpty ? '📄 $fn' : '📄 Document';
    }

    if (event.type == EventTypes.Encrypted) {
      return '🔒 Encrypted message';
    }

    if (body.isEmpty) return 'Message';
    return body;
  }

  /// Never notify for status broadcast or stories from any social media
  /// (WhatsApp status broadcast, Telegram stories, Instagram stories, etc.)
  static bool isStatusOrStoryRoom(Room room, {Event? event}) {
    final localized = room.getLocalizedDisplayname().toLowerCase().trim();
    final rawName = localized;
    final roomId = room.id.toLowerCase().trim();
    final topic = room.topic.toLowerCase().trim();
    final canonical = room.canonicalAlias.toLowerCase().trim();

    // 1. Direct name checks for WhatsApp, Telegram, Instagram status/stories
    if (localized.contains('status broadcast') ||
        localized.contains('whatsapp status') ||
        localized.contains('status_broadcast') ||
        rawName.contains('status broadcast') ||
        rawName.contains('whatsapp status') ||
        rawName.contains('status_broadcast')) {
      return true;
    }

    if (localized == 'status' ||
        localized == 'statuses' ||
        localized == 'stories' ||
        localized == 'story' ||
        localized == 'my status' ||
        rawName == 'status' ||
        rawName == 'statuses' ||
        rawName == 'stories' ||
        rawName == 'story') {
      return true;
    }

    // 2. Room ID checks (e.g. @broadcast:whatsapp.net, _status_broadcast, etc.)
    if (roomId.contains('status') &&
        (roomId.contains('broadcast') || roomId.contains('whatsapp'))) {
      return true;
    }
    if (roomId.contains('status_broadcast') ||
        roomId.contains('status@broadcast') ||
        roomId.contains('@broadcast')) {
      return true;
    }

    // 3. Canonical alias checks
    if (canonical.contains('status') &&
        (canonical.contains('broadcast') || canonical.contains('wa'))) {
      return true;
    }

    // 4. Topic checks
    if (topic.contains('status broadcast') || topic.contains('whatsapp status')) {
      return true;
    }

    // 5. Event sender checks
    if (event != null) {
      final sender = event.senderId.toLowerCase();
      if (sender.contains('status@broadcast') ||
          sender.contains('broadcast:whatsapp') ||
          sender.contains('status_broadcast')) {
        return true;
      }
    }

    return false;
  }

  /// Detects sensitive messages (OTPs, 2FA codes, security codes, official platform messages)
  /// and extracts the OTP code without blurring the notification text.
  static ({bool isSensitive, String? otpCode}) _detectOtpAndSensitivity(
    String message,
    String senderName,
    String rawSenderId,
    String platform,
  ) {
    final lowerMsg = message.toLowerCase();
    final lowerSenderName = senderName.toLowerCase().trim();
    final lowerRaw = rawSenderId.toLowerCase().trim();

    final isOfficial = lowerSenderName == 'whatsapp' ||
        lowerSenderName == 'whatsapp official' ||
        lowerSenderName == 'telegram' ||
        lowerSenderName == 'telegram service' ||
        lowerSenderName == 'instagram' ||
        lowerSenderName.contains('official') ||
        lowerSenderName.contains('security') ||
        lowerSenderName.contains('verify') ||
        lowerRaw.contains('777000') ||
        lowerRaw.contains('0@s.whatsapp.net') ||
        lowerRaw.contains('official');

    final sensitiveKeywords = [
      'otp',
      'verification code',
      'verify code',
      'security code',
      'login code',
      'auth code',
      'authentication code',
      'confirmation code',
      'secret code',
      'password reset',
      'reset password',
      'one-time password',
      'one time password',
      'do not share',
      'never share',
      'don\'t share',
      'temporary code',
      'passcode',
    ];

    final hasSensitiveKeyword =
        sensitiveKeywords.any((kw) => lowerMsg.contains(kw));

    String? extractedOtp;

    // Pattern 1: WhatsApp style code with hyphen: e.g. 123-456 or 123 456
    final hyphenOtpRegex = RegExp(r'\b([0-9]{3})[- ]([0-9]{3})\b');
    final mHyphen = hyphenOtpRegex.firstMatch(message);
    if (mHyphen != null) {
      extractedOtp = '${mHyphen.group(1)}${mHyphen.group(2)}';
    }

    // Pattern 2: (code|otp|pin|is|:)\s*([0-9]{4,8})
    if (extractedOtp == null) {
      final keywordOtpRegex = RegExp(
        r'(?:code|otp|pin|is|passcode|token|key)[:\s]+([0-9]{4,8})\b',
        caseSensitive: false,
      );
      final mKey = keywordOtpRegex.firstMatch(message);
      if (mKey != null) {
        extractedOtp = mKey.group(1);
      }
    }

    // Pattern 3: e.g. "123456 is your verification code"
    if (extractedOtp == null) {
      final beforeRegex = RegExp(
        r'(\b[0-9]{4,8}\b)[^0-9\n]{0,25}(?:is\s+your|is\s+the|code|otp|verification)',
        caseSensitive: false,
      );
      final mBefore = beforeRegex.firstMatch(message);
      if (mBefore != null) {
        extractedOtp = mBefore.group(1);
      }
    }

    // Pattern 4: If sensitive keyword or official sender, extract any standalone 4-8 digit number
    if (extractedOtp == null && (hasSensitiveKeyword || isOfficial)) {
      final standaloneCodeRegex = RegExp(r'\b([0-9]{4,8})\b');
      final mStand = standaloneCodeRegex.firstMatch(message);
      if (mStand != null) {
        extractedOtp = mStand.group(1);
      }
    }

    final isSensitive = isOfficial || hasSensitiveKeyword || extractedOtp != null;
    return (isSensitive: isSensitive, otpCode: extractedOtp);
  }

  void dispose() {
    _timelineSub?.cancel();
    _timelineSub = null;
    _syncSub?.cancel();
    _syncSub = null;
    _client = null;
  }
}
