import 'package:flutter/material.dart';
import '../services/license_service.dart';
import '../screens/license_screen.dart';

/// Widget that wraps the app and enforces license validation
class LicenseGuard extends StatefulWidget {
  final Widget child;
  final bool enableLicensing; // Set to false during development
  
  const LicenseGuard({
    Key? key,
    required this.child,
    this.enableLicensing = true,
  }) : super(key: key);
  
  @override
  State<LicenseGuard> createState() => _LicenseGuardState();
}

class _LicenseGuardState extends State<LicenseGuard> {
  bool _isInitialized = false;
  bool _isValidating = true;
  bool _hasValidLicense = false;
  String? _errorMessage;
  DateTime? _lastCheck;
  
  @override
  void initState() {
    super.initState();
    _initializeLicense();
  }
  
  Future<void> _initializeLicense() async {
    if (!widget.enableLicensing) {
      setState(() {
        _isInitialized = true;
        _isValidating = false;
        _hasValidLicense = true;
      });
      return;
    }
    
    final service = LicenseService.instance;
    await service.initialize();
    
    // Set up callbacks
    service.onLicenseValidated = (result) {
      if (mounted) {
        setState(() {
          _hasValidLicense = result.valid;
          _errorMessage = result.valid ? null : result.message;
          _lastCheck = DateTime.now();
        });
      }
    };
    
    service.onLicenseError = (error) {
      if (mounted) {
        setState(() {
          _errorMessage = error;
        });
      }
    };
    
    setState(() => _isInitialized = true);
    
    // Initial validation
    await _validateLicense();
  }
  
  Future<void> _validateLicense() async {
    if (!widget.enableLicensing) return;
    
    setState(() => _isValidating = true);
    
    final service = LicenseService.instance;
    // Force online validation to immediately detect deactivated licenses
    final result = await service.validateLicense(forceOnline: true);
    
    if (mounted) {
      setState(() {
        _isValidating = false;
        _hasValidLicense = result.valid;
        _errorMessage = result.valid ? null : result.message;
        _lastCheck = DateTime.now();
      });
    }
  }
  
  void _showLicenseScreen() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => const LicenseScreen(isInitialSetup: true),
        fullscreenDialog: true,
      ),
    );
    
    if (result == true) {
      _validateLicense();
    }
  }
  
  @override
  Widget build(BuildContext context) {
    // Skip licensing in development mode
    if (!widget.enableLicensing) {
      return widget.child;
    }
    
    // While validating, show the app (with its own loading screen)
    // License check runs in background - no separate loading UI needed
    if (!_isInitialized || _isValidating) {
      // Return the child app which has its own loading animation
      return widget.child;
    }
    
    // Show license activation screen if no valid license
    if (!_hasValidLicense) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: LicenseScreen(
          isInitialSetup: true,
          key: ValueKey(_lastCheck), // Force rebuild on validation
        ),
      );
    }
    
    // Valid license - show the app
    return widget.child;
  }
}
