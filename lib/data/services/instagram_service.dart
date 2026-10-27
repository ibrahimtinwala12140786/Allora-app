import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../screens/networks/network_connection_cache.dart';
import '../../screens/networks/network_meta.dart';

class InstagramService {
  InstagramService._();
  static final InstagramService instance = InstagramService._();

  static const String webhookUrl =
      'https://rwkebciwvsmavsigdrfa.supabase.co/functions/v1/instagram-webhook';
  static const String webhookAliasUrl =
      'https://rwkebciwvsmavsigdrfa.supabase.co/functions/v1/webhook';
  static const String oauthRedirectUrl =
      'https://rwkebciwvsmavsigdrfa.supabase.co/functions/v1/instagram-auth';
  static const String defaultVerifyToken =
      'allora_the_universal_messaging_app';
  static const String instagramAppId = '2268420340658927';
  static const String instagramAppSecret = 'd94f52bb9d0a645b3b003c52993045d9';

  static String getOAuthLoginUrl() {
    return 'https://www.instagram.com/oauth/authorize'
        '?enable_fb_login=0'
        '&force_authentication=1'
        '&client_id=$instagramAppId'
        '&redirect_uri=${Uri.encodeComponent(oauthRedirectUrl)}'
        '&response_type=code'
        '&scope=instagram_business_basic,instagram_business_manage_messages,instagram_business_manage_comments';
  }

  static const String _prefKeyAccountId = 'instagram_account_id';
  static const String _prefKeyUsername = 'instagram_username';
  static const String _prefKeyAccessToken = 'instagram_access_token';

  SupabaseClient get _supabase => Supabase.instance.client;

  /// Tests the live webhook endpoint by simulating Meta's GET verification request
  Future<bool> testWebhookVerification() async {
    final challenge = 'test_${DateTime.now().millisecondsSinceEpoch}';
    final uri = Uri.parse(webhookUrl).replace(queryParameters: {
      'hub.mode': 'subscribe',
      'hub.challenge': challenge,
      'hub.verify_token': defaultVerifyToken,
    });

    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      return res.statusCode == 200 && res.body.trim() == challenge;
    } catch (e) {
      debugPrint('InstagramService: Webhook test error: $e');
      return false;
    }
  }

  /// Connect an Instagram account directly using an Access Token (generated in Meta Developer Console)
  Future<Map<String, dynamic>> connectWithAccessToken({
    required String accessToken,
    String? fallbackUsername,
  }) async {
    try {
      // 1. Fetch profile info from Instagram Graph API
      String igId = '';
      String username = fallbackUsername ?? '';
      String name = '';
      String? profilePic;

      try {
        final profileUri = Uri.parse(
          'https://graph.instagram.com/v21.0/me?fields=id,username,name,profile_picture_url&access_token=$accessToken',
        );
        final profileRes = await http.get(profileUri).timeout(const Duration(seconds: 10));
        if (profileRes.statusCode == 200) {
          final data = jsonDecode(profileRes.body) as Map<String, dynamic>;
          igId = data['id']?.toString() ?? '';
          username = data['username']?.toString() ?? username;
          name = data['name']?.toString() ?? '';
          profilePic = data['profile_picture_url']?.toString();
        }
      } catch (e) {
        debugPrint('InstagramService: Graph profile fetch warning: $e');
      }

      // If ID couldn't be resolved from Graph API (e.g. sandbox token restrictions), generate or use fallback
      if (igId.isEmpty) {
        igId = 'ig_${username.isNotEmpty ? username : DateTime.now().millisecondsSinceEpoch}';
      }
      if (username.isEmpty) {
        username = 'Instagram Business';
      }

      // 2. Persist in Supabase instagram_accounts table
      await _supabase.from('instagram_accounts').upsert({
        'id': igId,
        'username': username,
        'name': name,
        'profile_pic_url': profilePic,
        'access_token': accessToken,
        'updated_at': DateTime.now().toIso8601String(),
      });

      // 3. Cache locally in SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKeyAccountId, igId);
      await prefs.setString(_prefKeyUsername, username);
      await prefs.setString(_prefKeyAccessToken, accessToken);

      // 4. Mark connected in Allora NetworkConnectionCache
      await NetworkConnectionCache.markConnected(
        NetworkId.instagram,
        accountLabel: '@$username',
        lastSynced: 'Active',
        force: true,
      );

      return {
        'success': true,
        'id': igId,
        'username': username,
      };
    } catch (e) {
      debugPrint('InstagramService: Connect error: $e');
      return {
        'success': false,
        'error': e.toString(),
      };
    }
  }

  /// Get locally stored credentials
  Future<Map<String, String?>> getSavedAccount() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'accountId': prefs.getString(_prefKeyAccountId),
      'username': prefs.getString(_prefKeyUsername),
      'accessToken': prefs.getString(_prefKeyAccessToken),
    };
  }

  /// Fetch conversations from Supabase
  Future<List<Map<String, dynamic>>> getConversations([String? accountId]) async {
    try {
      var query = _supabase.from('instagram_conversations').select();
      if (accountId != null && accountId.isNotEmpty) {
        query = query.eq('account_id', accountId);
      }
      final data = await query.order('updated_at', ascending: false);
      return List<Map<String, dynamic>>.from(data);
    } catch (e) {
      debugPrint('InstagramService: Error fetching conversations: $e');
      return [];
    }
  }

  /// Stream messages in real-time from Supabase
  Stream<List<Map<String, dynamic>>> streamMessages(String conversationId) {
    return _supabase
        .from('instagram_messages')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', conversationId)
        .order('created_at', ascending: true);
  }

  /// Send outbound message via Instagram Graph API or Edge Function
  Future<bool> sendMessage({
    required String recipientId,
    required String text,
    String? accountId,
    String? accessToken,
  }) async {
    try {
      final saved = await getSavedAccount();
      final token = accessToken ?? saved['accessToken'];
      final accId = accountId ?? saved['accountId'];

      if (token == null || token.isEmpty) {
        throw Exception('No Instagram access token available.');
      }

      // Call the Edge Function outbound sender
      final sendUri = Uri.parse(
        'https://rwkebciwvsmavsigdrfa.supabase.co/functions/v1/instagram-webhook/send',
      );
      final res = await http.post(
        sendUri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'recipient_id': recipientId,
          'text': text,
          'access_token': token,
        }),
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final mid = data['message_id'] ?? 'mid_${DateTime.now().millisecondsSinceEpoch}';

        // Insert echo into Supabase
        if (accId != null) {
          final convId = 'conv_${accId}_$recipientId';
          final now = DateTime.now().toIso8601String();
          await _supabase.from('instagram_messages').upsert({
            'id': mid,
            'conversation_id': convId,
            'account_id': accId,
            'sender_id': accId,
            'recipient_id': recipientId,
            'text': text,
            'is_echo': true,
            'created_at': now,
          });

          await _supabase.from('instagram_conversations').upsert({
            'id': convId,
            'account_id': accId,
            'participant_id': recipientId,
            'last_message': text,
            'last_message_time': now,
            'unread_count': 0,
            'updated_at': now,
          });
        }
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('InstagramService: Send message error: $e');
      return false;
    }
  }

  /// Disconnect Instagram
  Future<void> disconnect() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKeyAccountId);
    await prefs.remove(_prefKeyUsername);
    await prefs.remove(_prefKeyAccessToken);
    await NetworkConnectionCache.markDisconnected(NetworkId.instagram);
  }
}
