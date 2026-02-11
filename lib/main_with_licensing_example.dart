// Example: How to integrate the licensing system into your main.dart

import 'package:flutter/material.dart';
import 'widgets/license_guard.dart';
import 'screens/character_studio_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Wrap your entire app with LicenseGuard
    return LicenseGuard(
      enableLicensing: true, // Set to false during development/testing
      child: MaterialApp(
        title: 'VEO3 Infinity',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          primarySwatch: Colors.blue,
          useMaterial3: true,
        ),
        // Your existing app goes here
        home: const CharacterStudioScreen(),
      ),
    );
  }
}

// ============================================
// Optional: Add license menu item to settings
// ============================================

import 'package:flutter/material.dart';
import '../screens/license_screen.dart';
import '../services/license_service.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // ... other settings ...
          
          ListTile(
            leading: const Icon(Icons.vpn_key),
            title: const Text('License Information'),
            subtitle: FutureBuilder<Map<String, dynamic>>(
              future: _getLicenseInfo(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Text('Loading...');
                final info = snapshot.data!;
                return Text(
                  info['valid'] == true 
                      ? 'Active (${info['days_remaining']} days remaining)'
                      : 'No active license',
                );
              },
            ),
            trailing: const Icon(Icons.arrow_forward_ios, size: 16),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const LicenseScreen(),
                ),
              );
            },
          ),
          
          // ... other settings ...
        ],
      ),
    );
  }
  
  Future<Map<String, dynamic>> _getLicenseInfo() async {
    final service = LicenseService.instance;
    await service.initialize();
    return service.licenseInfo;
  }
}

// ============================================
// Optional: Manual license check before expensive operations
// ============================================

Future<void> startVideoGeneration() async {
  final licenseService = LicenseService.instance;
  
  // Force online validation before expensive operation
  final result = await licenseService.validateLicense(forceOnline: true);
  
  if (!result.valid) {
    // Show error and open license screen
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('License Required'),
        content: Text(result.message ?? 'Please activate a valid license to continue.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const LicenseScreen(),
                ),
              );
            },
            child: const Text('Activate License'),
          ),
        ],
      ),
    );
    return;
  }
  
  // License valid - proceed with operation
  // ... your video generation code ...
}
