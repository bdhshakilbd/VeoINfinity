import 'dart:convert';
import 'package:http/http.dart' as http;

class SessionService {
  static const String sessionUrl = 'https://labs.google/fx/api/auth/session';
  
  Future<SessionResponse> checkSession(String cookie) async {
    try {
      final response = await http.get(
        Uri.parse(sessionUrl),
        headers: {
          'host': 'labs.google',
          'sec-ch-ua-platform': '"Windows"',
          'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36',
          'sec-ch-ua': '"Chromium";v="142", "Google Chrome";v="142", "Not_A Brand";v="99"',
          'content-type': 'application/json',
          'sec-ch-ua-mobile': '?0',
          'accept': '*/*',
          'sec-fetch-site': 'same-origin',
          'sec-fetch-mode': 'cors',
          'sec-fetch-dest': 'empty',
          'referer': 'https://labs.google/',
          'accept-encoding': 'gzip, deflate, br, zstd',
          'accept-language': 'en-US,en;q=0.9',
          'priority': 'u=1, i',
          'cookie': cookie,
        },
      );

      if (response.statusCode == 200) {
        final jsonResponse = jsonDecode(response.body);
        return SessionResponse.fromJson(jsonResponse);
      } else {
        throw Exception('Session check failed: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error checking session: $e');
    }
  }
}

class SessionResponse {
  final UserInfo? user;
  final DateTime? expires;
  final String? accessToken;

  SessionResponse({
    this.user,
    this.expires,
    this.accessToken,
  });

  factory SessionResponse.fromJson(Map<String, dynamic> json) {
    return SessionResponse(
      user: json['user'] != null ? UserInfo.fromJson(json['user']) : null,
      expires: json['expires'] != null ? DateTime.parse(json['expires']) : null,
      accessToken: json['access_token'],
    );
  }

  bool get isActive {
    if (expires == null) return false;
    return DateTime.now().isBefore(expires!);
  }

  Duration? get timeRemaining {
    if (expires == null) return null;
    final remaining = expires!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  String get timeRemainingFormatted {
    final remaining = timeRemaining;
    if (remaining == null) return 'Unknown';
    if (remaining == Duration.zero) return 'Expired';
    
    final hours = remaining.inHours;
    final minutes = remaining.inMinutes.remainder(60);
    
    return '${hours}h ${minutes}m';
  }
}

class UserInfo {
  final String name;
  final String email;
  final String image;

  UserInfo({
    required this.name,
    required this.email,
    required this.image,
  });

  factory UserInfo.fromJson(Map<String, dynamic> json) {
    return UserInfo(
      name: json['name'] ?? '',
      email: json['email'] ?? '',
      image: json['image'] ?? '',
    );
  }
}
