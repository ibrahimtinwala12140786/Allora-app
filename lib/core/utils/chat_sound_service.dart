import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

/// Sound and haptic feedback service for Allora chat messaging.
class ChatSoundService {
  static final ChatSoundService _instance = ChatSoundService._internal();
  factory ChatSoundService() => _instance;
  ChatSoundService._internal();

  Player? _player;

  Player get _safePlayer {
    _player ??= Player();
    return _player!;
  }

  /// Play sound when a message is successfully sent.
  static Future<void> playSentSound() async {
    try {
      HapticFeedback.lightImpact();
      SystemSound.play(SystemSoundType.click);
      await _instance._safePlayer.open(
        Media('asset:///assets/sounds/message_sent.wav'),
        play: true,
      );
    } catch (e) {
      debugPrint('playSentSound error: $e');
    }
  }

  /// Play sound when message sending fails or matrix server is offline.
  static Future<void> playFailSound() async {
    try {
      HapticFeedback.heavyImpact();
      SystemSound.play(SystemSoundType.alert);
      await _instance._safePlayer.open(
        Media('asset:///assets/sounds/message_fail.wav'),
        play: true,
      );
    } catch (e) {
      debugPrint('playFailSound error: $e');
    }
  }

  /// Play sound when a message is deleted.
  static Future<void> playDeleteSound() async {
    try {
      HapticFeedback.mediumImpact();
      await _instance._safePlayer.open(
        Media('asset:///assets/sounds/message_delete.wav'),
        play: true,
      );
    } catch (e) {
      debugPrint('playDeleteSound error: $e');
    }
  }
}
