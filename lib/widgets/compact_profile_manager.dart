import 'package:flutter/material.dart';
import '../services/profile_manager_service.dart';
import '../services/settings_service.dart';
import '../services/mobile/mobile_browser_service.dart';

/// Compact multi-profile widget for integration into existing UI
class CompactProfileManagerWidget extends StatefulWidget {
  final Function(int)? onLogin;           // Login SINGLE browser at count position
  final Function(int, String, String)? onLoginAll;  // Login ALL browsers from 1 to count
  final Function(int)? onConnectOpened;
  final Function(int)? onOpenWithoutLogin;
  final ProfileManagerService? profileManager;
  final MobileBrowserService? mobileBrowserService;  // For embedded webview browser status
  final VoidCallback? onStop;

  const CompactProfileManagerWidget({
    Key? key,
    this.onLogin,
    this.onLoginAll,
    this.onConnectOpened,
    this.onOpenWithoutLogin,
    this.profileManager,
    this.mobileBrowserService,
    this.onStop,
  }) : super(key: key);

  @override
  State<CompactProfileManagerWidget> createState() => _CompactProfileManagerWidgetState();
}

class _CompactProfileManagerWidgetState extends State<CompactProfileManagerWidget> {
  int _profileCount = 2;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Row 1: Browser Count + Buttons
        Row(
          children: [
            Text('Count:', style: TextStyle(fontSize: 10)),
            const SizedBox(width: 4),
            SizedBox(
              width: 50,
              height: 24,
              child: DropdownButtonFormField<int>(
                value: _profileCount,
                decoration: InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                  isDense: true,
                ),
                style: TextStyle(fontSize: 10, color: Colors.black),
                items: [1, 2, 3, 4, 5, 6, 8, 10]
                    .map((count) => DropdownMenuItem(
                          value: count,
                          child: Text('$count'),
                        ))
                    .toList(),
                onChanged: _isProcessing
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() => _profileCount = value);
                          // Don't auto-login on count change - user must click button
                        }
                      },
              ),
            ),
            const SizedBox(width: 6),
            
            // Login SINGLE browser (at count position)
            Expanded(
              child: SizedBox(
                height: 24,
                child: ElevatedButton(
                  onPressed: _isProcessing ? null : _handleLogin,
                  child: Text('🔐 Login', style: TextStyle(fontSize: 8)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepOrange,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(horizontal: 2),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            
            // Login ALL browsers (from 1 to count)
            Expanded(
              child: SizedBox(
                height: 24,
                child: ElevatedButton(
                  onPressed: _isProcessing ? null : _handleLoginAll,
                  child: Text('🚀 All', style: TextStyle(fontSize: 8)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(horizontal: 2),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),

            // STOP button
            SizedBox(
              height: 24,
              width: 28,
              child: ElevatedButton(
                onPressed: widget.onStop,
                child: Icon(Icons.stop, size: 12),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.zero,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        
        // Row 3: Connect buttons
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 22,
                child: ElevatedButton(
                  onPressed: _isProcessing ? null : _handleConnectOpened,
                  child: Text('Connect Opened', style: TextStyle(fontSize: 9)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(horizontal: 6),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: SizedBox(
                height: 22,
                child: ElevatedButton(
                  onPressed: _isProcessing ? null : _handleOpenWithoutLogin,
                  child: Text('Open No Login', style: TextStyle(fontSize: 9)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey[700],
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(horizontal: 6),
                  ),
                ),
              ),
            ),
          ],
        ),
        
        // Status row - Show embedded browser status if mobileBrowserService exists, otherwise CDP status
        if (widget.mobileBrowserService != null && widget.mobileBrowserService!.profiles.isNotEmpty) ...[
          const SizedBox(height: 4),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: Colors.blue.shade200),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.account_tree, size: 12, color: Colors.blue),
                const SizedBox(width: 4),
                Text(
                  '${widget.mobileBrowserService!.profiles.where((p) => p.status == MobileProfileStatus.ready).length}/${widget.mobileBrowserService!.profiles.length} Connected',
                  style: TextStyle(fontSize: 9, color: Colors.blue.shade900),
                ),
              ],
            ),
          ),
        ] else if (widget.profileManager != null &&
            widget.profileManager!.profiles.isNotEmpty) ...[
          const SizedBox(height: 4),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: Colors.blue.shade200),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.account_tree, size: 12, color: Colors.blue),
                const SizedBox(width: 4),
                Text(
                  '${widget.profileManager!.countConnectedProfiles()}/${widget.profileManager!.profiles.length} Connected',
                  style: TextStyle(fontSize: 9, color: Colors.blue.shade900),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // Login SINGLE browser at count position (e.g., count=4 means login ONLY Browser 4)
  Future<void> _handleLogin() async {
    // Check if accounts are configured in SettingsService
    if (SettingsService.instance.accounts.isEmpty) {
      _showError('⚠️ No accounts configured! Please add accounts in Settings first.');
      return;
    }
    
    setState(() => _isProcessing = true);

    try {
      await widget.onLogin?.call(_profileCount);
      if (mounted) setState(() => _isProcessing = false);
    } catch (e) {
      if (mounted) {
        setState(() => _isProcessing = false);
        _showError('Login failed');
      }
    }
  }

  // Login ALL browsers from 1 to count (e.g., count=4 means login 1, 2, 3, 4)
  Future<void> _handleLoginAll() async {
    // Check if accounts are configured in SettingsService
    if (SettingsService.instance.accounts.isEmpty) {
      _showError('⚠️ No accounts configured! Please add accounts in Settings first.');
      return;
    }
    
    setState(() => _isProcessing = true);

    try {
      await widget.onLoginAll?.call(_profileCount, '', '');
      if (mounted) setState(() => _isProcessing = false);
    } catch (e) {
      if (mounted) {
        setState(() => _isProcessing = false);
        _showError('Login all failed');
      }
    }
  }

  Future<void> _handleConnectOpened() async {
    // Check if accounts are configured in SettingsService
    if (SettingsService.instance.accounts.isEmpty) {
      _showError('⚠️ No accounts configured! Please add accounts in Settings first.');
      return;
    }
    
    setState(() => _isProcessing = true);

    try {
      await widget.onConnectOpened?.call(_profileCount);
      if (mounted) setState(() => _isProcessing = false);
    } catch (e) {
      if (mounted) {
        setState(() => _isProcessing = false);
        _showError('Connect failed');
      }
    }
  }

  Future<void> _handleOpenWithoutLogin() async {
    setState(() => _isProcessing = true);

    try {
      await widget.onOpenWithoutLogin?.call(_profileCount);
      if (mounted) setState(() => _isProcessing = false);
    } catch (e) {
      if (mounted) {
        setState(() => _isProcessing = false);
        _showError('Open failed');
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message, 
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        backgroundColor: message.contains('No accounts') ? Colors.orange.shade700 : Colors.red.shade700,
        duration: Duration(seconds: message.contains('No accounts') ? 4 : 2),
        behavior: SnackBarBehavior.floating,
        action: message.contains('No accounts') 
          ? SnackBarAction(
              label: 'Open Settings',
              textColor: Colors.white,
              onPressed: () {
                // Navigate to settings tab
                DefaultTabController.of(context).animateTo(6); // Settings is usually tab 6
              },
            )
          : null,
      ),
    );
  }
}
