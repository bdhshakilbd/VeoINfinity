import 'dart:convert';

/// Represents a user account profile with credentials
class AccountProfile {
  final String id;
  String name;
  String authToken; // Manual token (legacy, now auto-generated)
  String cookie;
  bool isActive;
  final DateTime createdAt;
  
  // Auto-generated token fields
  String? cachedAuthToken;
  DateTime? tokenExpiry;

  AccountProfile({
    required this.id,
    required this.name,
    this.authToken = '',
    this.cookie = '',
    this.isActive = false,
    DateTime? createdAt,
    this.cachedAuthToken,
    this.tokenExpiry,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Create a new profile with generated ID
  factory AccountProfile.create(String name) {
    return AccountProfile(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      isActive: false,
    );
  }

  /// Get the best available auth token (cached or manual)
  String getAuthToken() {
    // Prefer cached token if valid
    if (cachedAuthToken != null && cachedAuthToken!.isNotEmpty) {
      if (tokenExpiry == null || tokenExpiry!.isAfter(DateTime.now())) {
        return cachedAuthToken!;
      }
    }
    // Fall back to manual token
    return authToken;
  }

  /// Check if token is valid
  bool isTokenValid() {
    if (cachedAuthToken == null || cachedAuthToken!.isEmpty) {
      return authToken.isNotEmpty;
    }
    if (tokenExpiry == null) return true;
    return tokenExpiry!.isAfter(DateTime.now());
  }

  /// Get token status: 'valid', 'expiring', 'expired', 'none'
  String getTokenStatus() {
    if (cachedAuthToken == null || cachedAuthToken!.isEmpty) {
      return authToken.isNotEmpty ? 'manual' : 'none';
    }
    
    if (tokenExpiry == null) return 'valid';
    
    final now = DateTime.now();
    if (tokenExpiry!.isBefore(now)) return 'expired';
    
    final minutesRemaining = tokenExpiry!.difference(now).inMinutes;
    if (minutesRemaining < 10) return 'expiring';
    
    return 'valid';
  }

  /// Get token expiry as readable string
  String getTokenExpiryText() {
    if (cachedAuthToken == null || cachedAuthToken!.isEmpty) {
      return authToken.isNotEmpty ? 'Manual token' : 'No token';
    }
    
    if (tokenExpiry == null) return 'Valid';
    
    final now = DateTime.now();
    if (tokenExpiry!.isBefore(now)) return 'Expired';
    
    final diff = tokenExpiry!.difference(now);
    if (diff.inHours > 0) return '${diff.inHours}h ${diff.inMinutes % 60}m';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m';
    return '${diff.inSeconds}s';
  }

  /// Parse cookie expiry from __Secure-next-auth.session-token
  DateTime? getCookieExpiry() {
    if (cookie.isEmpty) return null;
    
    try {
      // Look for expires= in the cookie string
      final expiresMatch = RegExp(r'expires=([^;]+)').firstMatch(cookie);
      if (expiresMatch != null) {
        final expiresStr = expiresMatch.group(1);
        if (expiresStr != null) {
          return DateTime.tryParse(expiresStr);
        }
      }
      
      // Try to decode JWT from session token to get expiry
      final sessionMatch = RegExp(r'__Secure-next-auth\.session-token=([^;]+)').firstMatch(cookie);
      if (sessionMatch != null) {
        final token = sessionMatch.group(1);
        if (token != null && token.contains('.')) {
          final parts = token.split('.');
          if (parts.length >= 2) {
            try {
              final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
              final json = jsonDecode(payload) as Map<String, dynamic>;
              if (json.containsKey('exp')) {
                return DateTime.fromMillisecondsSinceEpoch((json['exp'] as int) * 1000);
              }
            } catch (_) {
              // JWT decode failed, continue
            }
          }
        }
      }
    } catch (e) {
      print('Error parsing cookie expiry: $e');
    }
    
    return null;
  }

  /// Get cookie status: 'valid', 'expiring', 'expired', or 'unknown'
  String getCookieStatus() {
    if (cookie.isEmpty) return 'unknown';
    
    final expiry = getCookieExpiry();
    if (expiry == null) return 'unknown';
    
    final now = DateTime.now();
    if (expiry.isBefore(now)) return 'expired';
    
    final hoursRemaining = expiry.difference(now).inHours;
    if (hoursRemaining < 24) return 'expiring';
    
    return 'valid';
  }

  /// Get remaining time as human-readable string
  String getExpiryText() {
    final expiry = getCookieExpiry();
    if (expiry == null) return 'Unknown';
    
    final now = DateTime.now();
    if (expiry.isBefore(now)) return 'Expired';
    
    final diff = expiry.difference(now);
    if (diff.inDays > 0) return '${diff.inDays}d remaining';
    if (diff.inHours > 0) return '${diff.inHours}h remaining';
    return '${diff.inMinutes}m remaining';
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'authToken': authToken,
      'cookie': cookie,
      'isActive': isActive,
      'createdAt': createdAt.toIso8601String(),
      'cachedAuthToken': cachedAuthToken,
      'tokenExpiry': tokenExpiry?.toIso8601String(),
    };
  }

  factory AccountProfile.fromJson(Map<String, dynamic> json) {
    return AccountProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      authToken: json['authToken'] as String? ?? '',
      cookie: json['cookie'] as String? ?? '',
      isActive: json['isActive'] as bool? ?? false,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
      cachedAuthToken: json['cachedAuthToken'] as String?,
      tokenExpiry: json['tokenExpiry'] != null 
          ? DateTime.tryParse(json['tokenExpiry'] as String)
          : null,
    );
  }
}
