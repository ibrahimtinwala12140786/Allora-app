import 'dart:convert';
import 'dart:io';

/// Data class holding extracted Facebook GraphQL request parameters
class FacebookGraphQLParams {
  final String? fbDtsg;
  final String? jazoest;
  final String? spinR;
  final String? userId;
  final String? docId;
  final String? friendlyName;
  final String? lsd;

  const FacebookGraphQLParams({
    this.fbDtsg,
    this.jazoest,
    this.spinR,
    this.userId,
    this.docId,
    this.friendlyName,
    this.lsd,
  });
}

/// Utility class for extracting, parsing, and formatting Facebook / Messenger session cookies
/// and GraphQL requests copied directly from Browser DevTools (cURL Bash, cURL CMD, PowerShell, fetch, JSON, etc.).
class FacebookCookieExtractor {
  FacebookCookieExtractor._();

  /// Essential Facebook authentication cookies
  static const List<String> primaryCookieKeys = [
    'c_user',
    'xs',
    'fr',
    'datr',
    'sb',
    'i_user',
    'presence',
    'wd',
    'dpr',
    'ps_l',
    'ps_n',
  ];

  /// Canonical session keys required for persistent Messenger sessions
  static const List<String> canonicalSessionKeys = [
    'c_user',
    'xs',
    'fr',
    'datr',
    'sb',
  ];

  /// Checks if the input string is a cURL command
  static bool isCurlCommand(String input) {
    final lower = input.trim().toLowerCase();
    return lower.startsWith('curl') ||
        (lower.contains('curl ') &&
            (lower.contains('-h') ||
                lower.contains('--header') ||
                lower.contains('--data') ||
                lower.contains('-b') ||
                lower.contains('--cookie') ||
                lower.contains('--url')));
  }

  /// Normalizes any cURL command (POSIX Bash or Windows CMD) into clean, standard Bash format.
  /// If it is already a valid cURL (bash) command, it returns the trimmed command verbatim.
  static String normalizeToBashCurl(String input) {
    var trimmed = input.trim();
    if (!isCurlCommand(trimmed)) return trimmed;

    // If it is Windows CMD format (contains ^ escapes), normalize to standard Bash
    if (trimmed.contains('^')) {
      trimmed = trimmed
          .replaceAll('^\r\n', ' \\\n')
          .replaceAll('^\n', ' \\\n')
          .replaceAll('^"', '"')
          .replaceAll(r'^\', r'\')
          .replaceAll('^&', '&')
          .replaceAll('^|', '|');
    }

    return trimmed;
  }

  /// Parses any raw string input copied from browser devtools:
  /// - POSIX / Bash cURL (`curl --url 'https://...' -b '...'`)
  /// - Windows CMD cURL (`curl ^"https://...^" -H ^"cookie: ...^"`)
  /// - PowerShell `Invoke-WebRequest`
  /// - JavaScript `fetch(...)`
  /// - Direct HTTP `Cookie: ...` header
  /// - JSON Object (`{"c_user": "...", "xs": "..."}`)
  /// - JSON Array (`[{"name": "c_user", "value": "..."}, ...]`)
  /// - Deep regular expression scan across the raw text
  ///
  /// Returns a standardized key-value map of cookies.
  static Map<String, String> parseCookies(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return {};

    final Map<String, String> extracted = {};

    // 1. Try parsing as JSON Object or Array
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (key != null && value != null) {
              final k = key.toString().trim();
              final v = _stripQuotes(value.toString().trim());
              if (k.isNotEmpty && v.isNotEmpty) {
                extracted[k] = v;
              }
            }
          });
          if (hasValidSession(extracted)) return extracted;
        } else if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              final name = item['name'] ?? item['key'] ?? item['Name'];
              final value = item['value'] ?? item['Value'];
              if (name != null && value != null) {
                final k = name.toString().trim();
                final v = _stripQuotes(value.toString().trim());
                if (k.isNotEmpty && v.isNotEmpty) {
                  extracted[k] = v;
                }
              }
            }
          }
          if (hasValidSession(extracted)) return extracted;
        }
      } catch (_) {
        // Fall through to other formats
      }
    }

    // Normalize Windows CMD caret escaping
    final normalized = trimmed
        .replaceAll('^\r\n', '\n')
        .replaceAll('^\n', '\n')
        .replaceAll('^"', '"')
        .replaceAll(r'^\', r'\')
        .replaceAll('^&', '&')
        .replaceAll('^|', '|');

    // 2. Extract from -b / --cookie or -H / --header Cookie headers
    final headerPatterns = [
      // cURL -b / --cookie '...'
      RegExp(r'''(?:^|\s)(?:-b|--cookie)\s+[\^'"]*([^'"]+)[\^'"]*''', caseSensitive: false),
      // cURL -H / --header 'Cookie: ...'
      RegExp(r'''(?:^|\s)(?:-H|--header)\s+[\^'"]*(?:Cookie|cookie):\s*([^'"]+)[\^'"]*''', caseSensitive: false),
      // PowerShell Header @"cookie" = "..."@
      RegExp(r'''["'](?:Cookie|cookie)["']\s*=\s*["']([^"']+)["']''', caseSensitive: false),
      // Fetch / JSON Header "cookie": "..."
      RegExp(r'''["'](?:Cookie|cookie)["']\s*:\s*["']([^"']+)["']''', caseSensitive: false),
      // Raw HTTP Cookie: ... line
      RegExp(r'''(?:^|\n)(?:Cookie|cookie):\s*([^\r\n]+)''', caseSensitive: false),
    ];

    for (final pattern in headerPatterns) {
      final matches = pattern.allMatches(normalized);
      for (final match in matches) {
        final captured = match.group(1);
        if (captured != null && captured.contains('=')) {
          final parsed = parseCookieHeader(captured);
          extracted.addAll(parsed);
        }
      }
    }

    if (hasValidSession(extracted)) {
      return extracted;
    }

    // 3. Fallback: Parse line-by-line as standard `cookie1=val1; cookie2=val2`
    final headerFallback = parseCookieHeader(normalized);
    if (headerFallback.isNotEmpty) {
      extracted.addAll(headerFallback);
    }

    if (hasValidSession(extracted)) {
      return extracted;
    }

    // 4. Deep Regex Scanner: Search for all primary Facebook cookie tokens across raw text
    final cookieRegex = RegExp(
      r'''(?:^|[;,\s&"'\\])(c_user|xs|fr|datr|sb|i_user|presence|wd|dpr|ps_l|ps_n)=([^;,\s&"'\\]+)''',
      caseSensitive: false,
    );

    final deepMatches = cookieRegex.allMatches(normalized);
    for (final match in deepMatches) {
      final key = match.group(1)?.trim();
      final val = match.group(2)?.trim();
      if (key != null && val != null && key.isNotEmpty && val.isNotEmpty) {
        extracted[key.toLowerCase()] = _stripQuotes(val);
      }
    }

    return extracted;
  }

  /// Parses standard HTTP `Cookie: name=val; name2=val2` format
  static Map<String, String> parseCookieHeader(String cookieString) {
    final Map<String, String> map = {};
    String raw = cookieString.trim();
    if (raw.toLowerCase().startsWith('cookie:')) {
      raw = raw.substring(7).trim();
    }

    final pairs = raw.split(';');
    for (final pair in pairs) {
      final eqIdx = pair.indexOf('=');
      if (eqIdx != -1) {
        final key = pair.substring(0, eqIdx).trim();
        final val = pair.substring(eqIdx + 1).trim();
        if (key.isNotEmpty) {
          final cleanVal = _stripQuotes(val);
          if (cleanVal.isNotEmpty) {
            map[key] = cleanVal;
          }
        }
      }
    }
    return map;
  }

  /// Extracts Facebook GraphQL request parameters (such as `fb_dtsg`, `jazoest`, `__spin_r`, `userId`)
  /// from cURL `--data-raw`, `--data`, `-d`, or URL query strings.
  static FacebookGraphQLParams extractGraphQLParams(String input) {
    final normalized = input
        .replaceAll('^\r\n', '\n')
        .replaceAll('^\n', '\n')
        .replaceAll('^"', '"')
        .replaceAll(r'^\', r'\')
        .replaceAll('^&', '&');

    String? fbDtsg;
    String? jazoest;
    String? spinR;
    String? userId;
    String? docId;
    String? friendlyName;

    // fb_dtsg or dtsg
    final dtsgMatch = RegExp(r'''(?:fb_dtsg|dtsg)[=:]\s*["']?([^&"'\s\r\n\\]+)''', caseSensitive: false).firstMatch(normalized);
    if (dtsgMatch != null) {
      fbDtsg = dtsgMatch.group(1)!;
    }

    // jazoest
    final jazoestMatch = RegExp(r'''jazoest[=:]\s*["']?(\d+)''', caseSensitive: false).firstMatch(normalized);
    if (jazoestMatch != null) {
      jazoest = jazoestMatch.group(1);
    }

    // __spin_r or __rev or spinR
    final spinMatch = RegExp(r'''(?:__spin_r|__rev|spinR)[=:]\s*["']?(\d+)''', caseSensitive: false).firstMatch(normalized);
    if (spinMatch != null) {
      spinR = spinMatch.group(1);
    }

    // __user or av or userId
    final userMatch = RegExp(r'''(?:__user|av|userId)[=:]\s*["']?(\d+)''', caseSensitive: false).firstMatch(normalized);
    if (userMatch != null) {
      userId = userMatch.group(1);
    }

    // doc_id
    final docMatch = RegExp(r'''doc_id[=:]\s*["']?(\d+)''', caseSensitive: false).firstMatch(normalized);
    if (docMatch != null) {
      docId = docMatch.group(1);
    }

    // fb_api_req_friendly_name or x-fb-friendly-name
    final friendlyMatch = RegExp(r'''(?:fb_api_req_friendly_name|x-fb-friendly-name)[=:]\s*["']?([^&"'\s\r\n\\]+)''', caseSensitive: false).firstMatch(normalized);
    if (friendlyMatch != null) {
      friendlyName = friendlyMatch.group(1);
    }

    // lsd
    String? lsd;
    final lsdMatch = RegExp(r'''(?:lsd)[=:]\s*["']?([^&"'\s\r\n\\]+)''', caseSensitive: false).firstMatch(normalized);
    if (lsdMatch != null) {
      lsd = lsdMatch.group(1);
    }

    return FacebookGraphQLParams(
      fbDtsg: fbDtsg,
      jazoest: jazoest,
      spinR: spinR,
      userId: userId,
      docId: docId,
      friendlyName: friendlyName,
      lsd: lsd,
    );
  }

  /// Strips leading/trailing single or double quotes
  static String _stripQuotes(String s) {
    var str = s.trim();
    if ((str.startsWith('"') && str.endsWith('"')) ||
        (str.startsWith("'") && str.endsWith("'"))) {
      if (str.length >= 2) {
        str = str.substring(1, str.length - 1);
      }
    }
    return str;
  }

  /// Formats a cookie map into the clean JSON object string containing the essential session cookies.
  static String formatCleanSessionJson(Map<String, String> cookies) {
    final Map<String, String> cleaned = {};
    for (final key in canonicalSessionKeys) {
      if (cookies.containsKey(key)) {
        final val = cookies[key]?.trim() ?? '';
        if (val.isNotEmpty) {
          cleaned[key] = val;
        }
      }
    }
    if (cookies.containsKey('i_user') && (cookies['i_user']?.isNotEmpty ?? false)) {
      cleaned['i_user'] = cookies['i_user']!.trim();
    }
    return jsonEncode(cleaned);
  }

  /// Formats a cookie map into JSON format.
  static String formatToJson(Map<String, String> cookies) {
    return formatCleanSessionJson(cookies);
  }

  /// Formats cookies into a standard DevTools cURL command for Messenger GraphQL.
  static String formatToCurl(
    Map<String, String> cookies, {
    String? fbDtsg,
    String? jazoest,
    String? spinR,
    String? userId,
  }) {
    return formatDeepGraphQlCurl(
      cookies: cookies,
      fbDtsg: fbDtsg,
      jazoest: jazoest,
      spinR: spinR,
      userId: userId,
    );
  }

  /// Computes Facebook's mathematical jazoest token from fb_dtsg (starts with '2' followed by sum of ASCII char codes)
  static String computeJazoest(String fbDtsg) {
    final trimmed = fbDtsg.trim();
    if (trimmed.isEmpty) return '25577';
    var sum = 0;
    for (var i = 0; i < trimmed.length; i++) {
      sum += trimmed.codeUnitAt(i);
    }
    return '2$sum';
  }

  /// Extracts Facebook GraphQL tokens (fb_dtsg, jazoest, spinR, userId, lsd) from raw HTML/script content
  static FacebookGraphQLParams extractFromHtml(String html) {
    String? fbDtsg;
    String? jazoest;
    String? spinR;
    String? userId;
    String? lsd;

    // fb_dtsg patterns in Comet / Relay Modern scripts & JSON responses
    final dtsgPatterns = [
      RegExp(r'\["DTSGInitialData",\s*(?:\[\s*\]|\{\s*\}),\s*\{\s*"token"\s*:\s*"([^"]+)"'),
      RegExp(r'\["DTSGInitData",\s*(?:\[\s*\]|\{\s*\}),\s*\{\s*"token"\s*:\s*"([^"]+)"'),
      RegExp(r'\["DTSGPreloadData",\s*(?:\[\s*\]|\{\s*\}),\s*\{\s*"token"\s*:\s*"([^"]+)"'),
      RegExp(r'\["DTSGAsyncGetTokenData",\s*(?:\[\s*\]|\{\s*\}),\s*\{\s*"token"\s*:\s*"([^"]+)"'),
      RegExp(r'\\"token\\":\\"([^\\]+)\\"'),
      RegExp(r'"token"\s*:\s*"(NA[a-zA-Z0-9_\-:]+)"'),
      RegExp(r'"dtsg"\s*:\s*\{\s*"token"\s*:\s*"([^"]+)"'),
      RegExp(r'''(?:fb_dtsg|dtsg)[=:]\s*["\\]*([^&"'\s\r\n\\]+)'''),
      RegExp(r'"async_get_token"\s*:\s*"([^"]+)"'),
    ];

    for (final pattern in dtsgPatterns) {
      final match = pattern.firstMatch(html);
      if (match != null && match.group(1) != null && match.group(1)!.isNotEmpty) {
        fbDtsg = match.group(1)!;
        break;
      }
    }

    // LSD token
    final lsdMatch = RegExp(r'\["LSD",\s*\[\s*\],\s*\{\s*"token"\s*:\s*"([^"]+)"').firstMatch(html) ??
        RegExp(r'"LSD",\[\],\{"token":"([^"]+)"').firstMatch(html) ??
        RegExp(r'name="lsd" value="([^"]+)"').firstMatch(html);
    if (lsdMatch != null) {
      lsd = lsdMatch.group(1);
    }

    // Spin revision
    final spinMatch = RegExp(r'"server_revision":(\d+)').firstMatch(html) ??
        RegExp(r'"__spin_r":(\d+)').firstMatch(html);
    if (spinMatch != null) {
      spinR = spinMatch.group(1);
    }

    // User ID
    final userMatch = RegExp(r'"USER_ID":"(\d+)"').firstMatch(html) ??
        RegExp(r'"ACCOUNT_ID":"(\d+)"').firstMatch(html) ??
        RegExp(r'"user":"(\d+)"').firstMatch(html);
    if (userMatch != null) {
      userId = userMatch.group(1);
    }

    if (fbDtsg != null && fbDtsg.isNotEmpty) {
      jazoest = computeJazoest(fbDtsg);
    }

    return FacebookGraphQLParams(
      fbDtsg: fbDtsg,
      jazoest: jazoest,
      spinR: spinR,
      userId: userId,
      docId: '26996952523264441',
      friendlyName: 'OhaiWebPublicKeyConfigQuery',
      lsd: lsd,
    );
  }

  /// Proactively fetches messenger.com with active cookies to extract authentic live fb_dtsg and jazoest tokens
  static Future<FacebookGraphQLParams> fetchGraphQLParamsFromWeb(Map<String, String> cookies) async {
    final cookieHeader = cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    final urls = [
      Uri.parse('https://www.messenger.com/?no_redirect=true'),
      Uri.parse('https://www.facebook.com/'),
      Uri.parse('https://m.facebook.com/'),
      Uri.parse('https://www.messenger.com/t'),
    ];

    for (final uri in urls) {
      try {
        final client = HttpClient();
        client.userAgent =
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36';
        client.connectionTimeout = const Duration(seconds: 8);

        final request = await client.getUrl(uri);
        request.headers.set('accept', 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8');
        request.headers.set('accept-language', 'en-US,en;q=0.9');
        request.headers.set('cookie', cookieHeader);
        request.headers.set('sec-ch-ua', '"Chromium";v="152", "Not?A_Brand";v="24", "Google Chrome";v="152"');
        request.headers.set('sec-ch-ua-mobile', '?0');
        request.headers.set('sec-ch-ua-platform', '"Windows"');
        request.headers.set('sec-fetch-dest', 'document');
        request.headers.set('sec-fetch-mode', 'navigate');
        request.headers.set('sec-fetch-site', 'none');
        request.headers.set('upgrade-insecure-requests', '1');

        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        client.close();

        final parsed = extractFromHtml(body);
        if (parsed.fbDtsg != null && parsed.fbDtsg!.isNotEmpty) {
          return parsed;
        }
      } catch (_) {}
    }
    return const FacebookGraphQLParams();
  }

  /// Constructs an authentic, POSIX/Bash GraphQL API cURL command matching
  /// exactly what Chrome DevTools produces when selecting "Copy as cURL (bash)"
  /// on https://www.messenger.com/api/graphql/
  static String formatDeepGraphQlCurl({
    required Map<String, String> cookies,
    String? fbDtsg,
    String? jazoest,
    String? spinR,
    String? userId,
  }) {
    final cookieParts = <String>[];
    for (final e in cookies.entries) {
      final k = e.key.trim();
      final v = e.value.trim();
      if (k.isNotEmpty && v.isNotEmpty) {
        cookieParts.add('$k=$v');
      }
    }
    final cookieHeader = cookieParts.join('; ');

    final resolvedUser = userId ?? getUserId(cookies) ?? cookies['c_user'] ?? '';
    final rawDtsg = fbDtsg ?? '';
    final dtsgVal = rawDtsg.contains('%') ? rawDtsg : Uri.encodeQueryComponent(rawDtsg);
    final jazoestVal = (fbDtsg != null && fbDtsg.isNotEmpty)
        ? computeJazoest(fbDtsg)
        : (jazoest ?? '25577');
    final spinVal = spinR ?? '1046380673';
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final dataRaw =
        'av=$resolvedUser&__aaid=0&__user=$resolvedUser&__a=1&__req=2&__hs=20695.HYP%3Amessengerdotcom_comet_pkg.2.1...0&dpr=1&__ccg=EXCELLENT&__rev=$spinVal&__s=0fyq7k%3A4sv9mw%3Ah675wc&__hsi=7679822777349020891&__dyn=7xeUjGU5a5Q1hyoyEqxemh0noeEb8nwgU7SbzEdE98K360CEboG0x8bo6u3y4o2Gwfi0LVEtwMw6ywMwto88422y11wBz81s8hwGxu782lwv89kbxS1Fwc60D85m1mzXw8W58jwGzEjxq0AEbrwh8lwqUW4-5o4q3y1EzovUaU1aoG2-azo2NwkQ0Lo4u2ubwHwKG2-2B08-Utyo6O1FwlUcEeE-12DzU4yUoU5y2-7o3Mw5fwHwOwCxG0HEC0QUqwRyGw&__csr=g4p4MLn2WqLbFi4b9mG_AK_p6RJF8QKOVtibYBlZbtZltfrsINtOmxitjQyjKFGYzFdyAXHGW9hbDRAmJJD9hay2eZoBfAF6qBAvszQRiQSJ-daJ2bhb8mXBAgH9QrJpaajAQ9H8lVbHypKGWuVJoGqt17h8OiBwdC0zF9u1k-2i0Am0C82wwcDo2sg18oC0F5AwlUK1dw8i08pwaC58rBw5nx501Wu0Nqw3XE0OC09Ew2BUyrm7ouwNwaR05GzmEpwbC05Ao0tCc789i2822yQ0X8mw4Rw6kKfw3eouw2mU0pZw45w4pwn40E8mwlEgxG0PEK360o214gdo0ntwbm04w87609ZF1e0ia0TQ19yVk0iC0py2MU1zEixS4o3hw3xLwrS0b4xem3Ki04co0qhw5mw2sU0ZS1Nw5Qq9F03xqG09BA9o4q04jo0Bi06n8KbgjU14k04a8520lq5U17E0vb80lu1Mwa-byRza4w0Cog1gQ8u0g623g0ye0fJyE0Q217wbGkM0C27U0Ce04lo0lUyU0CC056EW08Lw1ARo0kbw2oU0i4w5Ng0B60lV056c0aDU11XCwjE2Bw3Kk1gg452F9AeyU8C08Ww7SCFw9V03Wk1Qzo2cwjy0Gw5zwww6bw7Iw6VxF1-3u0GQ0hmeyA02CWQS0aCxW7E21gsw9y1yw8O0q60Eo5508gdzEww0wl1C4o0Mu0jK19wGw4sobU3oo9oW4Vagf40GE1GESkKEqwYoCa8dKgKbzIkO389JyEK4epx2mbge41tEwiyUG8xOsJ3hiC9gGNE6mbw7AwWo4i0ra0laE3tmE5a1PweS0oh3bw2cU0wW1hwi8hwuiwxxW78aE8Fu5C22xl2B4a89orO3O9dxmF7KdBx1xibyB4wDojym2qup03m81Eo14U0AWii58tG6EEw4R08W0-3qw36E2Vw8Z0Gwcp0gK2R63oWaiwrQ1OxQwpcqbmy6C81ig1k84q0qOeg9o15EG3m4omwr86iag2UwjE3bym4o4p0m87-1Awc608fwt809NK0gGC2x00Aqyo982KG17w0zLxS3y1Nw2g80aHE0aP8Lc07N40cbw4Sw4mo054Aw0Qe0pCyAyQ0tC07aE0oh6P0be1Kw3zE&__hsdp=l0IQwgMEwGg2hFE2rE4ch1hcgt2FAw_p-Cn2kT6Qgrb0g2gocEk5l4MjppDh8J2khAcEC5k6N0C1hxbGUTWBqgaE7kwS1fgsGVky274d28rx2Q8IEN0goG6qxy8xinW41G4onDAjXBDopES2C2yXJ1sMGUbpEf8yXKawDKbyia4ECaDWgCh0dqcap1FV8bkaBVGwjU71ogxR1W7K2C0FU3jw4Exqu11x2682rzo2fw9m2W1HwJwEwqU4e0lp1S0RU2Cw8G1sw9-1CwGway7U8okxi6FE3nwnoeE2ywlEek0Ponwjogw821fg5y3-1jwpUS2a1ayWxK1mwd-2m1JyE4G1EwEg4W8wg84-1dwae2-1Hw&__hblp=0HxO1dw864EyexVwn87Hwq88E5q3Gu8Bx63i0xoKiUSq7UmwtlwnrxHJ6UK9gO68pzo4a1KBV88ohxyqm-URxCV4axeUCbXxeuh2oMwgwJCgowyybAGaG4oizU-cBiGEShAGGAgKawvUdQqdx64ooVuUR92FtWQ13ACAz9FuFU9oC9GXyp-4EgxC7K2C2u2adyEowbiq12w4Exp6wSyEgxy0wEozo2fw9m2W48523u2y1HxC5VUC49ofU3_gtw9C4U8pU2Cw8G0_86qm2i3a1DyGwgoapoK8CwTwVxeq482nwHzEW0AUowTwCxx0Jwm8bonhU-68Ku2edxufwm84Z4w9e363KfwZGaxKq2iaxF2GwrWw4WwgUeGG8gd8cU9qggz9o9Hy8yEcbyofVorgce9wqEozXwLxG1gw&__sjsp=l0IQwgMEwGg2gjE2rE4ch1hcgt2FAw_p-Cn2kT6Qgrb0g2goc5Nlhc4SeQ2wMO38g1Mxy0iW09kw3tA014Hw7fw2ho&__comet_req=105&fb_dtsg=$dtsgVal&jazoest=$jazoestVal&lsd=85SGwA9jPaFaPZfwAtABvh&__spin_r=$spinVal&__spin_b=trunk&__spin_t=$timestamp&__jssesw=1&__crn=comet.messenger.MWInboxHomeRoute&fb_api_caller_class=RelayModern&fb_api_req_friendly_name=OhaiWebPublicKeyConfigQuery&server_timestamps=true&variables=%7B%7D&doc_id=26996952523264441';

    return "curl --url 'https://www.messenger.com/api/graphql/' \\\n"
        "  -H 'accept: */*' \\\n"
        "  -H 'accept-language: en-US,en;q=0.9' \\\n"
        "  -H 'content-type: application/x-www-form-urlencoded' \\\n"
        "  -b '$cookieHeader' \\\n"
        "  -H 'origin: https://www.messenger.com' \\\n"
        "  -H 'priority: u=1, i' \\\n"
        "  -H 'referer: https://www.messenger.com/?no_redirect=true' \\\n"
        "  -H 'sec-ch-prefers-color-scheme: light' \\\n"
        "  -H 'sec-ch-ua: \"Chromium\";v=\"152\", \"Not?A_Brand\";v=\"24\", \"Google Chrome\";v=\"152\"' \\\n"
        "  -H 'sec-ch-ua-full-version-list: \"Chromium\";v=\"152.0.7977.64\", \"Not?A_Brand\";v=\"24.0.0.0\", \"Google Chrome\";v=\"152.0.7977.64\"' \\\n"
        "  -H 'sec-ch-ua-mobile: ?0' \\\n"
        "  -H 'sec-ch-ua-model: \"\"' \\\n"
        "  -H 'sec-ch-ua-platform: \"Windows\"' \\\n"
        "  -H 'sec-ch-ua-platform-version: \"19.0.0\"' \\\n"
        "  -H 'sec-fetch-dest: empty' \\\n"
        "  -H 'sec-fetch-mode: cors' \\\n"
        "  -H 'sec-fetch-site: same-origin' \\\n"
        "  -H 'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36' \\\n"
        "  -H 'x-asbd-id: 359341' \\\n"
        "  -H 'x-fb-friendly-name: OhaiWebPublicKeyConfigQuery' \\\n"
        "  -H 'x-fb-lsd: 85SGwA9jPaFaPZfwAtABvh' \\\n"
        "  --data-raw '$dataRaw'";
  }

  /// Checks if the cookies contain the minimum required Facebook session tokens:
  /// `c_user` (user ID) and `xs` (session token)
  static bool hasValidSession(Map<String, String> cookies) {
    final hasUser = cookies.containsKey('c_user') && (cookies['c_user']?.isNotEmpty ?? false);
    final hasXs = cookies.containsKey('xs') && (cookies['xs']?.isNotEmpty ?? false);
    return hasUser && hasXs;
  }

  /// Extracts user ID from `c_user` cookie if available
  static String? getUserId(Map<String, String> cookies) {
    return cookies['c_user'] ?? cookies['i_user'];
  }

  /// Summarizes captured cookies for user display (e.g. "c_user, xs, datr, sb, fr")
  static String summarizeKeys(Map<String, String> cookies) {
    final keys = cookies.keys.toList();
    if (keys.isEmpty) return 'No cookies';
    return keys.take(6).join(', ') + (keys.length > 6 ? ' +${keys.length - 6} more' : '');
  }

  /// Extracts the Login URL from the bridge bot's prompt message.
  static String? extractLoginUrl(String botMessage) {
    if (botMessage.trim().isEmpty) return null;

    String? rawUrl;

    // 1. Check for "Login URL: <url>"
    final match = RegExp(r'Login URL:\s*<?\s*(https?://[^\s\)>\]"]+)', caseSensitive: false).firstMatch(botMessage);
    if (match != null) {
      rawUrl = match.group(1);
    }

    // 2. Check for markdown link [Messenger](https://...)
    if (rawUrl == null) {
      final mdMatch = RegExp(r'\[(?:Messenger|Facebook|Login)[^\]]*\]\((https?://[^\)]+)\)', caseSensitive: false).firstMatch(botMessage);
      if (mdMatch != null) {
        rawUrl = mdMatch.group(1);
      }
    }

    // 3. Match any https URL on messenger.com or facebook.com
    if (rawUrl == null) {
      final generalMatch = RegExp(r'(https?://(?:www\.|m\.)?(?:messenger|facebook)\.com[^\s\)>\]"]*)', caseSensitive: false).firstMatch(botMessage);
      if (generalMatch != null) {
        rawUrl = generalMatch.group(1);
      }
    }

    if (rawUrl == null) return null;

    var cleaned = rawUrl.trim();
    while (cleaned.endsWith('>') ||
        cleaned.endsWith(')') ||
        cleaned.endsWith(']') ||
        cleaned.endsWith('"') ||
        cleaned.endsWith("'") ||
        cleaned.endsWith('.')) {
      cleaned = cleaned.substring(0, cleaned.length - 1).trim();
    }
    return cleaned.isNotEmpty ? cleaned : null;
  }
}
