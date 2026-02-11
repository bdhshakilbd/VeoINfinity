import 'dart:convert';
import 'package:http/http.dart' as http;

/// Service to fetch and manage authorization tokens from cookies
class SessionTokenService {
  static const String _sessionUrl = 'https://labs.google/fx/api/auth/session';
  
  /// Cached token data
  String? _cachedToken;
  DateTime? _tokenExpiry;
  
  /// Fetch a new access token using cookies
  Future<TokenResult> fetchToken(String rawCookie) async {
    try {
      // Parse cookie to standard format
      final cookie = parseCookieString(rawCookie);
      
      if (cookie.isEmpty) {
        return TokenResult.error('Invalid cookie format');
      }
      
      // Make request to session endpoint
      final response = await http.get(
        Uri.parse(_sessionUrl),
        headers: {
          'Cookie': cookie,
          'Content-Type': 'application/json',
          'Accept': '*/*',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        },
      );
      
      if (response.statusCode != 200) {
        return TokenResult.error('Session request failed: ${response.statusCode}');
      }
      
      // Parse response
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      
      final accessToken = json['access_token'] as String?;
      final expiresStr = json['expires'] as String?;
      
      if (accessToken == null || accessToken.isEmpty) {
        return TokenResult.error('No access_token in response');
      }
      
      // Parse expiry
      DateTime? expiry;
      if (expiresStr != null) {
        expiry = DateTime.tryParse(expiresStr);
      }
      
      // Cache the token
      _cachedToken = accessToken;
      _tokenExpiry = expiry;
      
      // Also extract user info for display
      final user = json['user'] as Map<String, dynamic>?;
      final userName = user?['name'] as String?;
      final userEmail = user?['email'] as String?;
      
      return TokenResult.success(
        token: accessToken,
        expiry: expiry,
        userName: userName,
        userEmail: userEmail,
      );
    } catch (e) {
      return TokenResult.error('Error fetching token: $e');
    }
  }
  
  /// Get a valid token, fetching new one if expired
  Future<TokenResult> getValidToken(String rawCookie) async {
    // Check if cached token is still valid
    if (_cachedToken != null && _tokenExpiry != null) {
      if (_tokenExpiry!.isAfter(DateTime.now())) {
        return TokenResult.success(
          token: _cachedToken!,
          expiry: _tokenExpiry,
        );
      }
    }
    
    // Token expired or not cached, fetch new one
    return fetchToken(rawCookie);
  }
  
  /// Check if current token is valid
  bool isTokenValid() {
    if (_cachedToken == null || _tokenExpiry == null) return false;
    return _tokenExpiry!.isAfter(DateTime.now());
  }
  
  /// Get remaining time until expiry
  Duration? getTimeRemaining() {
    if (_tokenExpiry == null) return null;
    final remaining = _tokenExpiry!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }
  
  /// Get expiry time as readable string
  String getExpiryText() {
    final remaining = getTimeRemaining();
    if (remaining == null) return 'Unknown';
    if (remaining == Duration.zero) return 'Expired';
    
    if (remaining.inHours > 0) {
      return '${remaining.inHours}h ${remaining.inMinutes % 60}m';
    } else if (remaining.inMinutes > 0) {
      return '${remaining.inMinutes}m';
    } else {
      return '${remaining.inSeconds}s';
    }
  }
  
  /// Parse various cookie formats to standard header format
  String parseCookieString(String input) {
    if (input.trim().isEmpty) return '';
    
    final trimmed = input.trim();
    
    // Try JSON array format: [{"name":"x","value":"y"}]
    if (trimmed.startsWith('[')) {
      return _parseJsonArray(trimmed);
    }
    
    // Try JSON object format: {"cookies":[...]}
    if (trimmed.startsWith('{')) {
      return _parseJsonObject(trimmed);
    }
    
    // Try Header format: Cookie: name=value; name2=value2
    if (trimmed.toLowerCase().startsWith('cookie:')) {
      return trimmed.substring(7).trim();
    }
    
    // Try Netscape format (tab-separated, multi-line)
    if (trimmed.contains('\t') && trimmed.contains('\n')) {
      return _parseNetscape(trimmed);
    }
    
    // Assume raw format: name=value; name2=value2
    return trimmed;
  }
  
  /// Parse JSON array cookie format
  String _parseJsonArray(String json) {
    try {
      final List<dynamic> cookies = jsonDecode(json);
      final parts = <String>[];
      
      for (final cookie in cookies) {
        if (cookie is Map<String, dynamic>) {
          final name = cookie['name'] ?? cookie['Name'];
          final value = cookie['value'] ?? cookie['Value'];
          if (name != null && value != null) {
            parts.add('$name=$value');
          }
        }
      }
      
      return parts.join('; ');
    } catch (e) {
      print('Error parsing JSON array cookies: $e');
      return '';
    }
  }
  
  /// Parse JSON object cookie format
  String _parseJsonObject(String json) {
    try {
      final Map<String, dynamic> data = jsonDecode(json);
      
      // Check for "cookies" array
      if (data.containsKey('cookies')) {
        return _parseJsonArray(jsonEncode(data['cookies']));
      }
      
      // Otherwise treat as key-value pairs
      final parts = <String>[];
      data.forEach((key, value) {
        parts.add('$key=$value');
      });
      
      return parts.join('; ');
    } catch (e) {
      print('Error parsing JSON object cookies: $e');
      return '';
    }
  }
  
  /// Parse Netscape cookie format
  String _parseNetscape(String content) {
    try {
      final lines = content.split('\n');
      final parts = <String>[];
      
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
        
        final fields = trimmed.split('\t');
        if (fields.length >= 7) {
          // Netscape: domain, flag, path, secure, expiry, name, value
          final name = fields[5];
          final value = fields[6];
          parts.add('$name=$value');
        }
      }
      
      return parts.join('; ');
    } catch (e) {
      print('Error parsing Netscape cookies: $e');
      return '';
    }
  }
  
  /// Clear cached token
  void clearCache() {
    _cachedToken = null;
    _tokenExpiry = null;
  }
}

/// Result of a token fetch operation
class TokenResult {
  final bool success;
  final String? token;
  final DateTime? expiry;
  final String? userName;
  final String? userEmail;
  final String? error;
  
  TokenResult._({
    required this.success,
    this.token,
    this.expiry,
    this.userName,
    this.userEmail,
    this.error,
  });
  
  factory TokenResult.success({
    required String token,
    DateTime? expiry,
    String? userName,
    String? userEmail,
  }) {
    return TokenResult._(
      success: true,
      token: token,
      expiry: expiry,
      userName: userName,
      userEmail: userEmail,
    );
  }
  
  factory TokenResult.error(String message) {
    return TokenResult._(
      success: false,
      error: message,
    );
  }
}
