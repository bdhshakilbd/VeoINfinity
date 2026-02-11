import 'package:flutter/material.dart';
import '../services/profile_manager_service.dart';

/// Widget for managing multiple Chrome profiles
class ProfileManagerWidget extends StatefulWidget {
  final Function(String, String)? onAutoLogin;
  final Function(int, String, String)? onLoginAll;
  final Function(int)? onConnectOpened;
  final Function(int)? onOpenWithoutLogin;
  final ProfileManagerService? profileManager;

  const ProfileManagerWidget({
    Key? key,
    this.onAutoLogin,
    this.onLoginAll,
    this.onConnectOpened,
    this.onOpenWithoutLogin,
    this.profileManager,
  }) : super(key: key);

  @override
  State<ProfileManagerWidget> createState() => _ProfileManagerWidgetState();
}

class _ProfileManagerWidgetState extends State<ProfileManagerWidget> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  int _profileCount = 4;
  bool _isProcessing = false;
  String _statusMessage = '';

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              children: [
                Icon(Icons.account_tree, color: Colors.blue),
                const SizedBox(width: 8),
                Text(
                  'Multi-Profile System',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            
            // Credentials row
            Row(
              children: [
                // Email
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _emailController,
                    enabled: !_isProcessing,
                    decoration: InputDecoration(
                      labelText: 'Google Email',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.email, size: 20),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      isDense: true,
                    ),
                    style: TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(width: 12),
                // Password
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _passwordController,
                    enabled: !_isProcessing,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.lock, size: 20),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      isDense: true,
                    ),
                    style: TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(width: 16),
                // Auto Login button (single profile)
                ElevatedButton.icon(
                  onPressed: _isProcessing ? null : _handleAutoLogin,
                  icon: Icon(Icons.lock_open, size: 18),
                  label: Text('🔐 Auto Login'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 16),
            
            // Separator
            Row(
              children: [
                Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'Multi-Browser',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[600],
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Expanded(child: Divider()),
              ],
            ),
            
            const SizedBox(height: 16),
            
            // Multi-browser controls
            Row(
              children: [
                Text('Browser Count:', style: TextStyle(fontSize: 13)),
                const SizedBox(width: 8),
                SizedBox(
                  width: 80,
                  child: DropdownButtonFormField<int>(
                    value: _profileCount,
                    decoration: InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      isDense: true,
                    ),
                    items: [1, 2, 3, 4, 5, 6, 8, 10]
                        .map((count) => DropdownMenuItem(
                              value: count,
                              child: Text('$count', style: TextStyle(fontSize: 13)),
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
                const SizedBox(width: 16),
                
                // Login All button
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _handleLoginAll,
                    icon: Icon(Icons.login, size: 18),
                    label: Text('🚀 Login All'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                
                // Connect All Opened button
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isProcessing ? null : _handleConnectOpened,
                    child: Text('Connect All Opened', style: TextStyle(fontSize: 12)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                
                // Open Without Login button
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isProcessing ? null : _handleOpenWithoutLogin,
                    child: Text('Open Without Login', style: TextStyle(fontSize: 12)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey[700],
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            
            // Status message
            if (_statusMessage.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: _isProcessing ? Colors.blue.shade50 : Colors.green.shade50,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: _isProcessing ? Colors.blue.shade200 : Colors.green.shade200,
                  ),
                ),
                child: Row(
                  children: [
                    if (_isProcessing)
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(Icons.check_circle, color: Colors.green, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _statusMessage,
                        style: TextStyle(
                          fontSize: 12,
                          color: _isProcessing ? Colors.blue.shade900 : Colors.green.shade900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            
            // Profile status list
            if (widget.profileManager != null &&
                widget.profileManager!.profiles.isNotEmpty) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    'Profile Status',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Spacer(),
                  Text(
                    '${widget.profileManager!.countConnectedProfiles()} / ${widget.profileManager!.profiles.length} connected',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                constraints: BoxConstraints(maxHeight: 200),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: ListView(
                  shrinkWrap: true,
                  children: widget.profileManager!.profiles
                      .map((profile) => _buildProfileStatusRow(profile))
                      .toList(),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildProfileStatusRow(ChromeProfile profile) {
    Color statusColor;
    IconData statusIcon;
    String statusText;

    switch (profile.status) {
      case ProfileStatus.connected:
        statusColor = Colors.green;
        statusIcon = Icons.check_circle;
        statusText = 'Connected';
        break;
      case ProfileStatus.launching:
        statusColor = Colors.orange;
        statusIcon = Icons.hourglass_empty;
        statusText = 'Launching';
        break;
      case ProfileStatus.relogging:
        statusColor = Colors.blue;
        statusIcon = Icons.refresh;
        statusText = 'Relogging';
        break;
      case ProfileStatus.error:
        statusColor = Colors.red;
        statusIcon = Icons.error;
        statusText = 'Error';
        break;
      default:
        statusColor = Colors.grey;
        statusIcon = Icons.cancel;
        statusText = 'Disconnected';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          Icon(statusIcon, color: statusColor, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              profile.name,
              style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
            ),
          ),
          Text(
            statusText,
            style: TextStyle(color: statusColor, fontSize: 11),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: profile.consecutive403Count >= 7
                  ? Colors.red.shade100
                  : Colors.grey.shade200,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '403: ${profile.consecutive403Count}/7',
              style: TextStyle(
                fontSize: 10,
                color: profile.consecutive403Count >= 7
                    ? Colors.red.shade900
                    : Colors.grey.shade700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Auto login (single profile)
  Future<void> _handleAutoLogin() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      _showError('Please enter email and password');
      return;
    }

    setState(() {
      _isProcessing = true;
      _statusMessage = 'Auto-logging in...';
    });

    try {
      await widget.onAutoLogin?.call(email, password);
      
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _statusMessage = '✓ Auto login complete';
        });
        Future.delayed(Duration(seconds: 3), () {
          if (mounted) setState(() => _statusMessage = '');
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _statusMessage = '';
        });
        _showError('Auto login failed: $e');
      }
    }
  }

  // Login all profiles
  Future<void> _handleLoginAll() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      _showError('Please enter email and password');
      return;
    }

    setState(() {
      _isProcessing = true;
      _statusMessage = 'Logging in to $_profileCount profiles...';
    });

    try {
      await widget.onLoginAll?.call(_profileCount, email, password);
      
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _statusMessage = '✓ Logged in to $_profileCount profiles';
        });
        Future.delayed(Duration(seconds: 3), () {
          if (mounted) setState(() => _statusMessage = '');
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _statusMessage = '';
        });
        _showError('Login all failed: $e');
      }
    }
  }

  // Connect to already-opened browsers
  Future<void> _handleConnectOpened() async {
    setState(() {
      _isProcessing = true;
      _statusMessage = 'Connecting to $_profileCount opened browsers...';
    });

    try {
      await widget.onConnectOpened?.call(_profileCount);
      
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _statusMessage = '✓ Connected to opened browsers';
        });
        Future.delayed(Duration(seconds: 3), () {
          if (mounted) setState(() => _statusMessage = '');
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _statusMessage = '';
        });
        _showError('Connect failed: $e');
      }
    }
  }

  // Open browsers without login
  Future<void> _handleOpenWithoutLogin() async {
    setState(() {
      _isProcessing = true;
      _statusMessage = 'Opening $_profileCount browsers...';
    });

    try {
      await widget.onOpenWithoutLogin?.call(_profileCount);
      
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _statusMessage = '✓ Opened $_profileCount browsers (manual login required)';
        });
        Future.delayed(Duration(seconds: 3), () {
          if (mounted) setState(() => _statusMessage = '');
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _statusMessage = '';
        });
        _showError('Open failed: $e');
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }
}

