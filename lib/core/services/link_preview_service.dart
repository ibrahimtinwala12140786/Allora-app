import 'dart:convert';
import 'package:http/http.dart' as http;

/// Cached metadata model for URL link previews.
class LinkPreviewData {
  final String url;
  final String? title;
  final String? description;
  final String? imageUrl;
  final String domain;

  const LinkPreviewData({
    required this.url,
    this.title,
    this.description,
    this.imageUrl,
    required this.domain,
  });

  bool get hasContent =>
      (title != null && title!.trim().isNotEmpty) ||
      (description != null && description!.trim().isNotEmpty) ||
      (imageUrl != null && imageUrl!.trim().isNotEmpty);
}

/// Service that fetches Open Graph and HTML metadata with memory caching.
class LinkPreviewService {
  LinkPreviewService._();
  static final LinkPreviewService instance = LinkPreviewService._();

  static final Map<String, LinkPreviewData?> _cache = {};

  static final _urlPattern = RegExp(
    r'(https?://[^\s<>"]+|www\.[^\s<>"]+\.[a-z]{2,})',
    caseSensitive: false,
  );

  /// Extracts the first valid HTTP/HTTPS or WWW URL from a message text.
  static String? extractFirstUrl(String text) {
    final match = _urlPattern.firstMatch(text);
    if (match == null) return null;
    var url = match.group(0)!;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    return url;
  }

  /// Fetches preview metadata for a URL or returns cached data immediately.
  Future<LinkPreviewData?> getPreview(String rawUrl) async {
    var url = rawUrl.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }

    if (_cache.containsKey(url)) {
      return _cache[url];
    }

    try {
      final uri = Uri.parse(url);
      final client = http.Client();
      final request = http.Request('GET', uri)
        ..headers['User-Agent'] =
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Allora/2.0'
        ..headers['Accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9';

      final response = await client.send(request).timeout(const Duration(seconds: 4));
      if (response.statusCode >= 400) {
        _cache[url] = null;
        return null;
      }

      // Stream only up to 48 KB of HTML to avoid downloading entire media files
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        bytes.addAll(chunk);
        if (bytes.length >= 48 * 1024) break;
      }
      client.close();

      final html = utf8.decode(bytes, allowMalformed: true);

      final title = _extractMeta(html, 'og:title') ??
          _extractMeta(html, 'twitter:title') ??
          _extractTitleTag(html);

      final description = _extractMeta(html, 'og:description') ??
          _extractMeta(html, 'twitter:description') ??
          _extractMeta(html, 'description');

      var imageUrl = _extractMeta(html, 'og:image') ??
          _extractMeta(html, 'twitter:image');

      if (imageUrl != null && imageUrl.isNotEmpty && !imageUrl.startsWith('http')) {
        imageUrl = uri.resolve(imageUrl).toString();
      }

      final domain = uri.host.replaceFirst(RegExp(r'^www\.'), '');

      final preview = LinkPreviewData(
        url: url,
        title: title?.trim(),
        description: description?.trim(),
        imageUrl: imageUrl?.trim(),
        domain: domain,
      );

      if (preview.hasContent) {
        _cache[url] = preview;
        return preview;
      } else {
        _cache[url] = null;
        return null;
      }
    } catch (_) {
      _cache[url] = null;
      return null;
    }
  }

  static String? _extractMeta(String html, String propertyName) {
    final escapedName = RegExp.escape(propertyName);
    final regExp = RegExp(
      '<meta\\s+[^>]*(?:property|name)=["\']$escapedName["\'][^>]*content=["\']([^"\']*)["\']',
      caseSensitive: false,
    );
    final match = regExp.firstMatch(html);
    if (match != null) return _unescape(match.group(1));

    final reverseRegExp = RegExp(
      '<meta\\s+[^>]*content=["\']([^"\']*)["\'][^>]*(?:property|name)=["\']$escapedName["\']',
      caseSensitive: false,
    );
    final reverseMatch = reverseRegExp.firstMatch(html);
    if (reverseMatch != null) return _unescape(reverseMatch.group(1));

    return null;
  }

  static String? _extractTitleTag(String html) {
    final match = RegExp(r'<title[^>]*>(.*?)</title>',
            caseSensitive: false, dotAll: true)
        .firstMatch(html);
    return match != null ? _unescape(match.group(1)!) : null;
  }

  static String _unescape(String? text) {
    if (text == null) return '';
    return text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .trim();
  }
}
