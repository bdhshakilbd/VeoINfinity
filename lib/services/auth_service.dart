import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:device_info_plus/device_info_plus.dart';

/// License verification service using MAC address / device ID
class AuthService {
  static const String whitelistUrl = "https://www.dropbox.com/scl/fi/fcgfbsbxp160lramvkuft/veo3_infinity.txt?rlkey=vc15uvo7hvfgt0vdnhfq63d96&st=2wcghjpa&dl=1";

  /// Check internet connectivity by attempting TCP connection to DNS servers
  static Future<bool> checkInternetConnection() async {
    try {
      final hosts = [
        InternetAddress('8.8.8.8'),    // Google DNS
        InternetAddress('1.1.1.1'),    // Cloudflare DNS
        InternetAddress('208.67.222.222'),  // OpenDNS
      ];
      for (var host in hosts) {
        try {
          final socket = await Socket.connect(host, 53, timeout: const Duration(seconds: 3));
          socket.destroy();
          return true;
        } catch (_) {}
      }
    } catch (_) {}
    return false;
  }

  /// Fetch whitelist from remote server
  static Future<Set<String>?> fetchWhitelist() async {
    try {
      final response = await http.get(Uri.parse(whitelistUrl)).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;

      final content = response.body;
      final validTokens = <String>{};

      // Regex for MAC Address (6 pairs)
      final macRegex = RegExp(r'([0-9A-Fa-f]{2}[-:][0-9A-Fa-f]{2}[-:][0-9A-Fa-f]{2}[-:][0-9A-Fa-f]{2}[-:][0-9A-Fa-f]{2}[-:][0-9A-Fa-f]{2})');
      
      // Regex for 16-hex Android simple ID
      final hexIdRegex = RegExp(r'\b[0-9a-fA-F]{16}\b');

      for (var line in LineSplitter.split(content)) {
        final trimmedLine = line.trim();
        if (trimmedLine.isEmpty || trimmedLine.startsWith('#')) continue;
        
        // Check MAC match - store first 5 segments (prefix)
        final macMatch = macRegex.firstMatch(trimmedLine);
        if (macMatch != null) {
          String mac = macMatch.group(1)!.replaceAll(':', '-').toUpperCase();
          final parts = mac.split('-');
          if (parts.length >= 5) {
            validTokens.add(parts.sublist(0, 5).join('-'));  // First 5 segments
          }
        }

        // Check 16-hex ID match - store exact lowercase
        final hexMatch = hexIdRegex.firstMatch(trimmedLine);
        if (hexMatch != null) {
          validTokens.add(hexMatch.group(0)!.toLowerCase());
        }
        
        // Also add the full line as-is (lowercase) for matching fingerprints or custom IDs
        validTokens.add(trimmedLine.toLowerCase());
      }
      
      print('[AUTH] Whitelist loaded with ${validTokens.length} entries');
      return validTokens;
    } catch (e) {
      print('Fetch whitelist error: $e');
      return null;
    }
  }

  /// Get local device IDs (MAC addresses for Windows, device ID for Android/iOS)
  static Future<List<String>> getLocalIds() async {
    final ids = <String>[];

    if (Platform.isWindows) {
      // Run 'getmac' command to get MAC addresses
      try {
        final result = await Process.run('getmac', []);
        final output = result.stdout.toString();
        // Match 6-pair MACs
        final regex = RegExp(r'([0-9A-Fa-f]{2}-[0-9A-Fa-f]{2}-[0-9A-Fa-f]{2}-[0-9A-Fa-f]{2}-[0-9A-Fa-f]{2}-[0-9A-Fa-f]{2})');
        for (var match in regex.allMatches(output)) {
          ids.add(match.group(1)!.toUpperCase());
        }
      } catch (e) {
        print('Error getting MAC: $e');
      }
    } else if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      // Use device_info_plus plugin
      try {
        final deviceInfo = DeviceInfoPlugin();
        if (Platform.isAndroid) {
          final androidInfo = await deviceInfo.androidInfo;
          // Use fingerprint as unique device identifier (format: brand/product/device:version/buildId/buildNumber:type/tags)
          // Or use the serialNumber if available, else use fingerprint hash
          final fingerprint = androidInfo.fingerprint;
          // Create a simpler ID from fingerprint for easier whitelist management
          final simpleId = fingerprint.hashCode.abs().toRadixString(16).padLeft(16, '0').substring(0, 16);
          print('[AUTH] Android fingerprint: "$fingerprint"');
          print('[AUTH] Android simple ID (for whitelist): "$simpleId"');
          ids.add(simpleId);
          // Also add the full fingerprint for matching
          ids.add(fingerprint.toLowerCase());
        } else if (Platform.isIOS) {
          final iosInfo = await deviceInfo.iosInfo;
          if (iosInfo.identifierForVendor != null) {
             final iosId = iosInfo.identifierForVendor!;
             print('[AUTH] iOS identifier: "$iosId"');
             ids.add(iosId);
          }
        } else if (Platform.isMacOS) {
          final macInfo = await deviceInfo.macOsInfo;
          // Use systemGUID as unique identifier (similar to Windows GUID)
          final macId = macInfo.systemGUID ?? 'unknown-mac';
          print('[AUTH] macOS system GUID: "$macId"');
          ids.add(macId);
        }
      } catch (e) {
        print('Error getting device info: $e');
      }
    }
    return ids;
  }

  /// Main verification function
  /// Returns: {authorized: bool, message: String, id: String}
  static Future<Map<String, dynamic>> verifyAccess() async {
    // 1. Check internet connection first
    if (!await checkInternetConnection()) {
      return {'authorized': false, 'message': 'NO_INTERNET_CONNECTION', 'id': 'Unknown'};
    }

    // 2. Fetch whitelist from Dropbox
    final whitelist = await fetchWhitelist();
    if (whitelist == null) {
      return {'authorized': false, 'message': 'AUTHORIZATION_SERVER_ERROR', 'id': 'Unknown'};
    }

    // 3. Get local device IDs
    final localIds = await getLocalIds();
    // For display, show only the first ID (the simple 16-char hex ID for Android)
    String displayId = localIds.isNotEmpty ? localIds.first : "No ID Found";
    
    print('[AUTH] Local IDs: $localIds');
    print('[AUTH] Whitelist count: ${whitelist.length}');
    print('[AUTH] Whitelist contains: $whitelist');
    
    bool authorized = false;

    // 4. Check each local ID against whitelist
    for (var id in localIds) {
      if (id.contains('-') && id.split('-').length == 6) {
        // MAC Address: Extract first 5 segments (prefix)
        final prefix = id.split('-').sublist(0, 5).join('-');
        print('[AUTH] Checking MAC prefix: $prefix');
        if (whitelist.contains(prefix)) {
          authorized = true;
          break;
        }
      } else {
        // Mobile ID: Exact match (lowercase)
        final lowerId = id.toLowerCase();
        print('[AUTH] Checking Android ID (lowercase): "$lowerId"');
        if (whitelist.contains(lowerId)) {
          print('[AUTH] MATCH FOUND!');
          authorized = true;
          break;
        } else {
          print('[AUTH] No match in whitelist');
        }
      }
    }

    if (!authorized) {
       return {
        'authorized': false, 
        'message': '⚠️ This device is not registered.\n\nContact support:\nWhatsApp: +8801705010632',
        'id': displayId
      };
    }

    return {'authorized': true, 'message': 'Authorized', 'id': displayId};
  }
}
