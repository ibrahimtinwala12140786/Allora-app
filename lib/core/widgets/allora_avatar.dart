// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../utils/matrix_media.dart';
import '../../screens/networks/network_meta.dart';

/// Deterministic pastel color for a name/id so placeholder avatars stay
/// stable between rebuilds and app launches.
Color colorForId(String id, {required bool dark}) {
  const palette = [
    Color(0xFF3A6FF8), Color(0xFF7C5CFC), Color(0xFF00A3AD),
    Color(0xFFE45794), Color(0xFFE8930C), Color(0xFF1FA45B),
    Color(0xFFDB5C5C), Color(0xFF5C7CDB),
  ];
  var hash = 0;
  for (final unit in id.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  final base = palette[hash % palette.length];
  return dark ? Color.lerp(base, Colors.white, 0.08)! : base;
}

/// Unified avatar for rooms and users.
///
/// * Uses the Matrix thumbnail endpoint with an explicit `cacheWidth`
///   so decoded bitmaps stay small — Flutter's [ImageCache] then keeps them
///   in memory, which is what makes fast scrolling smooth.
/// * Falls back to colored initials (never a broken-image glyph).
/// * Optionally overlays the source-network badge (WhatsApp, Telegram, …).
class AlloraAvatar extends StatelessWidget {
  final Uri? mxcUri;
  final Client? client;
  final String name;
  final double size;
  final NetworkMeta? network;
  final bool showNetworkBadge;

  const AlloraAvatar({
    super.key,
    required this.name,
    this.mxcUri,
    this.client,
    this.size = 52,
    this.network,
    this.showNetworkBadge = true,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final initial = _initials(name);
    final bg = colorForId(name.isEmpty ? '?' : name, dark: dark);

    Widget avatar = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [bg.withValues(alpha: 0.95), Color.lerp(bg, Colors.black, 0.18)!],
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: _thumbnail(initial),
    );

    if (network != null && showNetworkBadge) {
      final badgeSize = (size * 0.38).clamp(17.0, 21.0);
      avatar = Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: badgeSize + 4,
              height: badgeSize + 4,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: dark ? const Color(0xFF17181D) : Colors.white,
                shape: BoxShape.circle,
              ),
              child: ClipOval(
                child: _buildNetworkBadge(network!, badgeSize),
              ),
            ),
          ),
        ],
      );
    }
    return avatar;
  }

  Widget _buildNetworkBadge(NetworkMeta network, double badgeSize) {
    if (network.id == NetworkId.whatsapp) {
      // Official WhatsApp icon (green circle with crisp vector white phone bubble)
      return Container(
        color: const Color(0xFF25D366),
        alignment: Alignment.center,
        child: const CustomPaint(
          size: Size.infinite,
          painter: WhatsAppBadgePainter(),
        ),
      );
    }

    if (network.id == NetworkId.telegram) {
      // Telegram iconic white paper airplane on Telegram blue circle
      return Container(
        color: const Color(0xFF29A9EA),
        alignment: Alignment.center,
        child: Transform.rotate(
          angle: -0.2,
          child: Icon(
            Icons.send_rounded,
            size: badgeSize * 0.54,
            color: Colors.white,
          ),
        ),
      );
    }

    if (network.id == NetworkId.instagram) {
      return Image.asset(
        'assets/images/instagram.png',
        width: badgeSize,
        height: badgeSize,
        fit: BoxFit.cover,
      );
    }

    if (network.id == NetworkId.messenger) {
      return Image.asset(
        'assets/images/messenger.png',
        width: badgeSize,
        height: badgeSize,
        fit: BoxFit.cover,
      );
    }

    if (network.asset != null) {
      return Image.asset(
        network.asset!,
        width: badgeSize,
        height: badgeSize,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          color: network.brandColor,
          alignment: Alignment.center,
          child: Icon(
            network.icon ?? Icons.chat_bubble_rounded,
            size: badgeSize * 0.54,
            color: Colors.white,
          ),
        ),
      );
    }

    return Container(
      color: network.brandColor,
      alignment: Alignment.center,
      child: Icon(
        network.icon ?? Icons.chat_bubble_rounded,
        size: badgeSize * 0.54,
        color: Colors.white,
      ),
    );
  }

  Widget _thumbnail(String initial) {
    final fallback = Center(
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.38,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
      ),
    );

    if (mxcUri == null || client == null) return fallback;

    final source = MatrixMedia.download(client!, mxcUri.toString()) ??
        MatrixMedia.thumbnail(client!, mxcUri.toString(),
            width: 512, height: 512);
    if (source == null) return fallback;

    return Image.network(
      source.url,
      headers: source.headers,
      fit: BoxFit.cover,
      width: size,
      height: size,
      filterQuality: FilterQuality.high,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => fallback,
      frameBuilder: (context, child, frame, wasSync) {
        if (wasSync || frame != null) return child;
        return fallback;
      },
    );
  }

  static String _initials(String name) {
    final cleaned = name.trim();
    if (cleaned.isEmpty) return '?';
    final parts = cleaned.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first).toUpperCase();
  }

  static Uri? resolveUri(Room room) {
    if (room.avatar != null) return room.avatar;
    try {
      final stateAvatar = room.getState('m.room.avatar')?.content['url'];
      if (stateAvatar is String && stateAvatar.startsWith('mxc://')) {
        final parsed = Uri.tryParse(stateAvatar);
        if (parsed != null) return parsed;
      }
    } catch (_) {}
    
    try {
      // For group chats without an avatar, return null to show colored initials
      // instead of a random participant's profile image.
      final memberCount = room.summary.mJoinedMemberCount ?? room.getParticipants().length;
      final isDirect = room.isDirectChat || memberCount <= 2;
      
      // If there are 3 participants, check if one is a bot (bridged 1:1 chat with bot + puppet + you)
      bool isBridgedDirect = isDirect;
      if (memberCount == 3) {
        for (final p in room.getParticipants()) {
          final id = p.id.toLowerCase();
          final localpart = id.startsWith('@') ? id.substring(1).split(':').first : id;
          if (localpart.endsWith('bot') ||
              localpart.contains('bridge') ||
              localpart.startsWith('whatsappbot') ||
              localpart.startsWith('telegrambot') ||
              localpart.startsWith('instagrambot') ||
              localpart.startsWith('messengerbot')) {
            isBridgedDirect = true;
            break;
          }
        }
      }

      if (!isBridgedDirect) {
        return null;
      }

      final myId = room.client.userID;
      final partnerId = room.directChatMatrixID;
      if (partnerId != null && partnerId != myId) {
        final partnerAvatar =
            room.getState('m.room.member', partnerId)?.content['avatar_url'];
        if (partnerAvatar is String && partnerAvatar.startsWith('mxc://')) {
          final parsed = Uri.tryParse(partnerAvatar);
          if (parsed != null) return parsed;
        }
      }
      final memberStates = room.states['m.room.member']?.values;
      if (memberStates != null) {
        for (final state in memberStates) {
          final stateKey = state.stateKey;
          if (stateKey == myId || stateKey == null) continue;
          if (stateKey.startsWith('@whatsappbot') ||
              stateKey.startsWith('@telegrambot') ||
              stateKey.startsWith('@bridge')) continue;
          final memberAvatar = state.content['avatar_url'];
          if (memberAvatar is String && memberAvatar.startsWith('mxc://')) {
            final parsed = Uri.tryParse(memberAvatar);
            if (parsed != null) return parsed;
          }
        }
      }
      for (final user in room.getParticipants()) {
        if (user.id == myId) continue;
        if (user.id.startsWith('@whatsappbot') ||
            user.id.startsWith('@telegrambot') ||
            user.id.startsWith('@bridge')) continue;
        if (user.avatarUrl != null) {
          return user.avatarUrl;
        }
        final memberAvatar =
            room.getState('m.room.member', user.id)?.content['avatar_url'];
        if (memberAvatar is String && memberAvatar.startsWith('mxc://')) {
          final parsed = Uri.tryParse(memberAvatar);
          if (parsed != null) return parsed;
        }
      }
      for (final user in room.getParticipants()) {
        if (user.id == myId) continue;
        if (user.avatarUrl != null) {
          return user.avatarUrl;
        }
        final memberAvatar =
            room.getState('m.room.member', user.id)?.content['avatar_url'];
        if (memberAvatar is String && memberAvatar.startsWith('mxc://')) {
          final parsed = Uri.tryParse(memberAvatar);
          if (parsed != null) return parsed;
        }
      }
    } catch (_) {}
    return null;
  }
}

/// Vector painter for the official WhatsApp logo badge (crisp white phone inside
/// speech bubble, scales perfectly to any size with no pixelation or edge clipping).
class WhatsAppBadgePainter extends CustomPainter {
  const WhatsAppBadgePainter();

  @override
  void paint(Canvas canvas, Size size) {
    // Original viewBox is 448 x 512.
    // Scale down slightly (0.72) to leave a balanced green margin inside the badge circle.
    final s = size.shortestSide / 512.0 * 0.72;
    final dx = (size.width - 448 * s) / 2;
    final dy = (size.height - 512 * s) / 2;

    canvas.save();
    canvas.translate(dx, dy);

    final p = Path()..fillType = PathFillType.evenOdd;
    // Outer speech bubble
    p.moveTo(s * 380.9, s * 97.1);
    p.cubicTo(s * 339.0, s * 55.1, s * 283.2, s * 32.0, s * 223.9, s * 32.0);
    p.cubicTo(s * 101.50, s * 32.00, s * 1.90, s * 131.60, s * 1.90, s * 254.00);
    p.cubicTo(s * 1.90, s * 293.10, s * 12.10, s * 331.30, s * 31.50, s * 365.00);
    p.lineTo(s * 0.0, s * 480.0);
    p.lineTo(s * 117.70, s * 449.10);
    p.cubicTo(s * 150.10, s * 466.80, s * 186.60, s * 476.10, s * 223.80, s * 476.10);
    p.lineTo(s * 223.90, s * 476.10);
    p.cubicTo(s * 346.20, s * 476.10, s * 448.00, s * 376.50, s * 448.00, s * 254.10);
    p.cubicTo(s * 448.00, s * 194.80, s * 422.80, s * 139.10, s * 380.90, s * 97.10);
    p.close();

    // Inner bubble cutout (reveals the green circle background inside the bubble)
    p.moveTo(s * 223.9, s * 438.7);
    p.cubicTo(s * 190.70, s * 438.70, s * 158.20, s * 429.80, s * 129.90, s * 413.00);
    p.lineTo(s * 123.20, s * 409.00);
    p.lineTo(s * 53.40, s * 427.30);
    p.lineTo(s * 72.0, s * 359.2);
    p.lineTo(s * 67.60, s * 352.20);
    p.cubicTo(s * 49.10, s * 322.80, s * 39.40, s * 288.90, s * 39.40, s * 254.00);
    p.cubicTo(s * 39.40, s * 152.30, s * 122.20, s * 69.50, s * 224.00, s * 69.50);
    p.cubicTo(s * 273.30, s * 69.50, s * 319.60, s * 88.70, s * 354.40, s * 123.60);
    p.cubicTo(s * 389.20, s * 158.50, s * 410.60, s * 204.80, s * 410.50, s * 254.10);
    p.cubicTo(s * 410.50, s * 355.90, s * 325.60, s * 438.70, s * 223.90, s * 438.70);
    p.close();

    // White phone handset inside the bubble
    p.moveTo(s * 325.1, s * 300.5);
    p.cubicTo(s * 319.60, s * 297.70, s * 292.30, s * 284.30, s * 287.20, s * 282.50);
    p.cubicTo(s * 282.10, s * 280.60, s * 278.40, s * 279.70, s * 274.70, s * 285.30);
    p.cubicTo(s * 271.00, s * 290.90, s * 260.40, s * 303.30, s * 257.10, s * 307.10);
    p.cubicTo(s * 253.90, s * 310.80, s * 250.60, s * 311.30, s * 245.10, s * 308.50);
    p.cubicTo(s * 212.50, s * 292.20, s * 191.10, s * 279.40, s * 169.60, s * 242.50);
    p.cubicTo(s * 163.90, s * 232.70, s * 175.30, s * 233.40, s * 185.90, s * 212.20);
    p.cubicTo(s * 187.70, s * 208.50, s * 186.80, s * 205.30, s * 185.40, s * 202.50);
    p.cubicTo(s * 184.00, s * 199.70, s * 172.90, s * 172.40, s * 168.30, s * 161.30);
    p.cubicTo(s * 163.80, s * 150.50, s * 159.20, s * 152.00, s * 155.80, s * 151.80);
    p.cubicTo(s * 152.60, s * 151.60, s * 148.90, s * 151.60, s * 145.20, s * 151.60);
    p.cubicTo(s * 141.50, s * 151.60, s * 135.50, s * 153.00, s * 130.40, s * 158.50);
    p.cubicTo(s * 125.30, s * 164.10, s * 111.00, s * 177.50, s * 111.00, s * 204.80);
    p.cubicTo(s * 111.00, s * 232.10, s * 130.90, s * 258.50, s * 133.60, s * 262.20);
    p.cubicTo(s * 136.40, s * 265.90, s * 172.70, s * 321.90, s * 228.40, s * 346.00);
    p.cubicTo(s * 263.60, s * 361.20, s * 277.40, s * 362.50, s * 295.00, s * 359.90);
    p.cubicTo(s * 305.70, s * 358.30, s * 327.80, s * 346.50, s * 332.40, s * 333.50);
    p.cubicTo(s * 337.00, s * 320.50, s * 337.00, s * 309.40, s * 335.60, s * 307.10);
    p.cubicTo(s * 334.30, s * 304.60, s * 330.60, s * 303.20, s * 325.10, s * 300.50);
    p.close();

    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    canvas.drawPath(p, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

