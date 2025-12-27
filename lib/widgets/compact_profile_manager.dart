import 'package:flutter/material.dart';
import '../services/profile_manager_service.dart';

/// Compact multi-profile widget for integration into existing UI
class CompactProfileManagerWidget extends StatefulWidget {
  final Function(String, String)? onAutoLogin;
  final Function(int, String, String)? onLoginAll;
  final Function(int)? onConnectOpened;
  final Function(int)? onOpenWithoutLogin;
  final ProfileManagerService? profileManager;
  final String? initialEmail;
  final String? initialPassword;
  final Function(String email, String password)? onCredentialsChanged;

  const CompactProfileManagerWidget({
    Key? key,
    this.onAutoLogin,
    this.onLoginAll,
    this.onConnectOpened,
    this.onOpenWithoutLogin,
    this.profileManager,
    this.initialEmail,
    this.initialPassword,
    this.onCredentialsChanged,
  }) : super(key: key);

  @override
  State<CompactProfileManagerWidget> createState() => _CompactProfileManagerWidgetState();
}

class _CompactProfileManagerWidgetState extends State<CompactProfileManagerWidget> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  int _profileCount = 4;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    // Set initial values if provided
    if (widget.initialEmail != null) {
      _emailController.text = widget.initialEmail!;
    }
    if (widget.initialPassword != null) {
      _passwordController.text = widget.initialPassword!;
    }
    
    // Listen for changes and auto-save
    _emailController.addListener(_saveCredentials);
    _passwordController.addListener(_saveCredentials);
  }
  
  void _saveCredentials() {
    widget.onCredentialsChanged?.call(
      _emailController.text.trim(),
      _passwordController.text.trim(),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Row 1: Email + Password
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _emailController,
                enabled: !_isProcessing,
                decoration: InputDecoration(
                  labelText: 'Email',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  isDense: true,
                  labelStyle: TextStyle(fontSize: 11),
                ),
                style: TextStyle(fontSize: 11),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: _passwordController,
                enabled: !_isProcessing,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  isDense: true,
                  labelStyle: TextStyle(fontSize: 11),
                ),
                style: TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        
        // Row 2: Browser Count + Buttons
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
                        }
                      },
              ),
            ),
            const SizedBox(width: 6),
            
            // Auto Login button
            Expanded(
              child: SizedBox(
                height: 24,
                child: ElevatedButton(
                  onPressed: _isProcessing ? null : _handleAutoLogin,
                  child: Text('🔐 Auto', style: TextStyle(fontSize: 9)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(horizontal: 6),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            
            // Login All button
            Expanded(
              child: SizedBox(
                height: 24,
                child: ElevatedButton(
                  onPressed: _isProcessing ? null : _handleLoginAll,
                  child: Text('🚀 All', style: TextStyle(fontSize: 9)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(horizontal: 6),
                  ),
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
        
        // Status row (if profiles exist)
        if (widget.profileManager != null &&
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

  Future<void> _handleAutoLogin() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      _showError('Enter email and password');
      return;
    }

    setState(() => _isProcessing = true);

    try {
      await widget.onAutoLogin?.call(email, password);
      if (mounted) setState(() => _isProcessing = false);
    } catch (e) {
      if (mounted) {
        setState(() => _isProcessing = false);
        _showError('Auto login failed');
      }
    }
  }

  Future<void> _handleLoginAll() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      _showError('Enter email and password');
      return;
    }

    setState(() => _isProcessing = true);

    try {
      await widget.onLoginAll?.call(_profileCount, email, password);
      if (mounted) setState(() => _isProcessing = false);
    } catch (e) {
      if (mounted) {
        setState(() => _isProcessing = false);
        _showError('Login all failed');
      }
    }
  }

  Future<void> _handleConnectOpened() async {
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
        content: Text(message, style: TextStyle(fontSize: 12)),
        duration: Duration(seconds: 2),
      ),
    );
  }
}
