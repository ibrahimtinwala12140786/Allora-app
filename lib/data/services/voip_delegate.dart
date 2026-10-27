import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:matrix/matrix.dart';
import 'package:webrtc_interface/webrtc_interface.dart' as webrtc_interface;
import 'dart:async';

class AlloraWebRTCDelegate implements WebRTCDelegate {
  final StreamController<CallSession> _newCallController = StreamController<CallSession>.broadcast();
  Stream<CallSession> get onNewCall => _newCallController.stream;

  final StreamController<CallSession> _callEndedController = StreamController<CallSession>.broadcast();
  Stream<CallSession> get onCallEnded => _callEndedController.stream;

  bool _inCall = false;

  @override
  webrtc_interface.MediaDevices get mediaDevices => webrtc.navigator.mediaDevices;

  @override
  bool get isWeb => kIsWeb;

  @override
  bool get canHandleNewCall => !_inCall;

  @override
  EncryptionKeyProvider? get keyProvider => null;

  @override
  Future<webrtc_interface.RTCPeerConnection> createPeerConnection(
      Map<String, dynamic> configuration,
      [Map<String, dynamic> constraints = const {}]) async {
    return await webrtc.createPeerConnection(configuration, constraints);
  }

  @override
  Future<void> handleCallEnded(CallSession session) async {
    _inCall = false;
    _callEndedController.add(session);
    await stopRingtone();
  }

  @override
  Future<void> handleGroupCallEnded(GroupCallSession groupCall) async {}

  @override
  Future<void> handleMissedCall(CallSession session) async {
    await stopRingtone();
  }

  @override
  Future<void> handleNewCall(CallSession session) async {
    _inCall = true;
    _newCallController.add(session);
    if (session.direction == CallDirection.kIncoming) {
      await playRingtone();
    }
  }

  @override
  Future<void> handleNewGroupCall(GroupCallSession groupCall) async {}

  @override
  Future<void> playRingtone() async {
    // Play ringing sound (placeholder)
  }

  @override
  Future<void> registerListeners(CallSession session) async {
    // Add custom listeners to session if needed
  }

  @override
  Future<void> stopRingtone() async {
    // Stop ringing sound (placeholder)
  }
}
