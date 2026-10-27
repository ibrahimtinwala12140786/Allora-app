import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:matrix/matrix.dart';

class VoipCallScreen extends StatefulWidget {
  final CallSession session;

  const VoipCallScreen({super.key, required this.session});

  @override
  State<VoipCallScreen> createState() => _VoipCallScreenState();
}

class _VoipCallScreenState extends State<VoipCallScreen> {
  bool _isMuted = false;
  bool _isVideoEnabled = false;

  final webrtc.RTCVideoRenderer _localRenderer = webrtc.RTCVideoRenderer();
  final webrtc.RTCVideoRenderer _remoteRenderer = webrtc.RTCVideoRenderer();

  @override
  void initState() {
    super.initState();
    _initRenderers();
    _setupListeners();
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  void _setupListeners() {
    // Ideally we would listen to session state changes here
    // e.g. session.onCallStateChanged
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  Future<void> _toggleMute() async {
    setState(() {
      _isMuted = !_isMuted;
    });
    // In a full implementation we'd do session.setMicrophoneMuted(_isMuted);
  }

  Future<void> _toggleVideo() async {
    setState(() {
      _isVideoEnabled = !_isVideoEnabled;
    });
  }

  Future<void> _endCall() async {
    await widget.session.hangup(reason: CallErrorCode.userHangup);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.person,
                      size: 100,
                      color: Colors.white54,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      widget.session.room.getLocalizedDisplayname(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Calling...',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 40.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildButton(
                    icon: _isMuted ? Icons.mic_off : Icons.mic,
                    color: _isMuted ? Colors.white24 : Colors.white12,
                    onPressed: _toggleMute,
                  ),
                  _buildButton(
                    icon: Icons.call_end,
                    color: Colors.red,
                    iconColor: Colors.white,
                    onPressed: _endCall,
                    size: 64,
                  ),
                  _buildButton(
                    icon: _isVideoEnabled ? Icons.videocam : Icons.videocam_off,
                    color: _isVideoEnabled ? Colors.white24 : Colors.white12,
                    onPressed: _toggleVideo,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildButton({
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
    Color iconColor = Colors.white,
    double size = 56,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(icon, color: iconColor, size: size * 0.5),
        onPressed: onPressed,
      ),
    );
  }
}
