import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../services/license_service.dart';

/// License activation and management screen
class LicenseScreen extends StatefulWidget {
  final bool isInitialSetup; // If true, user cannot close without valid license
  
  const LicenseScreen({Key? key, this.isInitialSetup = false}) : super(key: key);
  
  @override
  State<LicenseScreen> createState() => _LicenseScreenState();
}

class _LicenseScreenState extends State<LicenseScreen> {
  final _licenseController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  
  bool _isValidating = false;
  LicenseResult? _validationResult;
  String? _deviceId;
  int _retryCount = 0;
  static const int _maxRetries = 3;
  
  @override
  void initState() {
    super.initState();
    _loadExistingLicense();
  }
  
  @override
  void dispose() {
    _licenseController.dispose();
    super.dispose();
  }
  
  Future<void> _loadExistingLicense() async {
    final service = LicenseService.instance;
    await service.initialize();
    
    final deviceId = await service.getDeviceId();
    setState(() => _deviceId = deviceId);
    
    if (service.storedLicenseKey != null) {
      _licenseController.text = service.storedLicenseKey!;
      // Don't auto-validate - let user manually click activate
      // This prevents infinite retry loops
    }
  }
  
  Future<void> _validateLicense() async {
    // Prevent multiple simultaneous validations
    if (_isValidating) return;
    
    // Check retry limit
    if (_retryCount >= _maxRetries) {
      setState(() {
        _validationResult = LicenseResult(
          valid: false,
          error: 'MAX_RETRIES_EXCEEDED',
          message: 'Maximum retry attempts (${_maxRetries}) exceeded. Please check your license status or contact support.',
        );
      });
      return;
    }
    
    if (!_formKey.currentState!.validate()) return;
    
    setState(() {
      _isValidating = true;
      _validationResult = null;
      _retryCount++;
    });
    
    try {
      final service = LicenseService.instance;
      final result = await service.validateLicense(
        licenseKey: _licenseController.text.trim().toUpperCase(),
        forceOnline: true,
      );
      
      if (!mounted) return;
      
      // Debug logging
      debugPrint('[LICENSE_SCREEN] Validation result: valid=${result.valid}, error=${result.error}, message=${result.message}');
      debugPrint('[LICENSE_SCREEN] About to call setState with result');
      
      setState(() {
        _isValidating = false;
        _validationResult = result;
      });
      
      debugPrint('[LICENSE_SCREEN] setState completed. _validationResult is now: ${_validationResult?.error}');
      
      // Reset retry count on success
      if (result.valid) {
        _retryCount = 0;
        if (!widget.isInitialSetup) {
          // Show success and close
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) Navigator.pop(context, true);
          });
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isValidating = false;
        _validationResult = LicenseResult(
          valid: false,
          error: 'ERROR',
          message: 'Validation error: ${e.toString()}',
        );
      });
    }
  }
  
  void _copyDeviceId() {
    if (_deviceId != null) {
      Clipboard.setData(ClipboardData(text: _deviceId!));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Device ID copied to clipboard')),
      );
    }
  }
  
  Color _getStatusColor() {
    if (_validationResult == null) return Colors.grey;
    return _validationResult!.valid ? Colors.green : Colors.red;
  }
  
  IconData _getStatusIcon() {
    if (_validationResult == null) return Icons.info_outline;
    return _validationResult!.valid ? Icons.check_circle : Icons.error_outline;
  }
  
  String _getErrorTitle() {
    if (_validationResult?.error == null) return 'Activation Failed';
    
    switch (_validationResult!.error) {
      case 'LICENSE_DEACTIVATED':
        return '🚫 License Deactivated';
      case 'LICENSE_EXPIRED':
        return '⏰ License Expired';
      case 'DEVICE_LIMIT_REACHED':
        return '📱 Device Limit Reached';
      case 'DEVICE_REVOKED':
        return '❌ Device Revoked';
      case 'INVALID_LICENSE':
        return '🔑 Invalid License';
      case 'NETWORK_ERROR':
        return '🌐 Connection Error';
      case 'MAX_RETRIES_EXCEEDED':
        return '⚠️ Too Many Attempts';
      default:
        return '❌ Activation Failed';
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        // Prevent closing if initial setup and no valid license
        if (widget.isInitialSetup && !LicenseService.instance.isLicenseValid) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('A valid license is required to use this application'),
              backgroundColor: Colors.red,
            ),
          );
          return false;
        }
        return true;
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('License Activation'),
          automaticallyImplyLeading: !widget.isInitialSetup,
          centerTitle: true,
          elevation: 0,
        ),
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Theme.of(context).primaryColor.withOpacity(0.05),
                Colors.white,
              ],
            ),
          ),
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 600),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // App Icon
                      Icon(
                        Icons.vpn_key_rounded,
                        size: 80,
                        color: Theme.of(context).primaryColor,
                      ),
                      const SizedBox(height: 16),
                      
                      // Title
                      Text(
                        widget.isInitialSetup ? 'Activate VEO3 Infinity' : 'License Management',
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      
                      Text(
                        widget.isInitialSetup 
                            ? 'Enter your license key to get started'
                            : 'Manage your license information',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 32),
                      
                      // Device ID Card - REMOVED FOR SECURITY
                      // Users don't need to see their device ID
                      
                      // License Key Input
                      TextFormField(
                        controller: _licenseController,
                        decoration: InputDecoration(
                          labelText: 'License Key',
                          hintText: 'XXXX-XXXX-XXXX-XXXX',
                          prefixIcon: const Icon(Icons.vpn_key),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          filled: true,
                          fillColor: Colors.grey.shade50,
                        ),
                        textCapitalization: TextCapitalization.characters,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.5,
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter a license key';
                          }
                          return null;
                        },
                        onFieldSubmitted: (_) => _validateLicense(),
                      ),
                      const SizedBox(height: 24),
                      
                      // Retry count and reset button
                      if (_retryCount > 0) ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Retry attempts: $_retryCount/$_maxRetries',
                              style: TextStyle(
                                fontSize: 12,
                                color: _retryCount >= _maxRetries ? Colors.red : Colors.grey.shade600,
                                fontWeight: _retryCount >= _maxRetries ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                            if (_retryCount >= _maxRetries)
                              TextButton.icon(
                                onPressed: () {
                                  setState(() {
                                    _retryCount = 0;
                                    _validationResult = null;
                                  });
                                },
                                icon: const Icon(Icons.refresh, size: 16),
                                label: const Text('Reset'),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],
                      
                      // Validate Button
                      ElevatedButton.icon(
                        onPressed: (_isValidating || _retryCount >= _maxRetries) ? null : _validateLicense,
                        icon: _isValidating
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.check_circle),
                        label: Text(
                          _isValidating ? 'Validating...' : 'Activate License',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                      
                      // Debug indicator
                      if (_validationResult != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            'DEBUG: Result=${_validationResult!.valid}, Error=${_validationResult!.error}',
                            style: const TextStyle(fontSize: 10, color: Colors.purple),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      
                      // Validation Result
                      if (_validationResult != null) ...[
                        const SizedBox(height: 24),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: _getStatusColor().withOpacity(0.1),
                            border: Border.all(color: _getStatusColor()),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Icon(_getStatusIcon(), color: _getStatusColor(), size: 28),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      _validationResult!.valid ? '✅ License Activated' : _getErrorTitle(),
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: _getStatusColor(),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (_validationResult!.message != null) ...[
                                const SizedBox(height: 8),
                                Text(
                                  _validationResult!.message!,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.grey.shade800,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                              // Show error code for debugging/support
                              if (!_validationResult!.valid && _validationResult!.error != null) ...[
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.red.shade50,
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: Colors.red.shade200),
                                  ),
                                  child: Text(
                                    'Error Code: ${_validationResult!.error}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                      color: Colors.red.shade700,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                              if (_validationResult!.valid) ...[
                                const Divider(height: 24),
                                _buildInfoRow('Customer', _validationResult!.customerName ?? 'N/A'),
                                const SizedBox(height: 8),
                                _buildInfoRow(
                                  'Expires',
                                  _validationResult!.expiresAt != null
                                      ? '${_validationResult!.expiresAt!.toLocal().toString().split(' ')[0]} (${_validationResult!.daysRemaining} days)'
                                      : 'N/A',
                                ),
                                const SizedBox(height: 8),
                                _buildInfoRow(
                                  'Device Limit',
                                  '${_validationResult!.maxDevices ?? 'N/A'}',
                                ),
                                if (_validationResult!.isOfflineValidation) ...[
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Icon(Icons.wifi_off, size: 14, color: Colors.orange.shade700),
                                      const SizedBox(width: 6),
                                      Text(
                                        'Offline Mode - Connect to internet for full validation',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.orange.shade700,
                                          fontStyle: FontStyle.italic,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                            ],
                          ),
                        ),
                      ],
                      
                      const SizedBox(height: 32),
                      
                      // Help Text
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.blue.shade100),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.info_outline, size: 18, color: Colors.blue.shade700),
                                const SizedBox(width: 8),
                                Text(
                                  'Need Help?',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.blue.shade900,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '• Contact support to purchase a license\n'
                              '• Provide your Device ID when requesting a license\n'
                              '• Each license can be used on a limited number of devices\n'
                              '• Internet connection required for initial activation',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade700,
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
  
  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: Colors.black87,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
        ),
      ],
    );
  }
}
