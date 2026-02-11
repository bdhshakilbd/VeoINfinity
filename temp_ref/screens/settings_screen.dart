import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import '../services/settings_service.dart';
import '../services/session_token_service.dart';
import '../models/account_profile.dart';

class SettingsScreen extends StatefulWidget {
  final String? currentAuthToken;
  final String? currentCookie;
  final String? currentAspectRatio;
  final Function(String authToken, String cookie, String aspectRatio)? onSave;

  const SettingsScreen({
    super.key,
    this.currentAuthToken,
    this.currentCookie,
    this.currentAspectRatio,
    this.onSave,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final SettingsService _settingsService = SettingsService();
  final SessionTokenService _tokenService = SessionTokenService();
  
  List<AccountProfile> _profiles = [];
  String? _expandedProfileId;
  String _settingsPath = '';
  bool _isLoading = false;
  Map<String, bool> _fetchingTokens = {};
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadProfiles();
    // Refresh UI every 30 seconds to update countdown
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadProfiles() async {
    setState(() => _isLoading = true);
    
    try {
      final profiles = await _settingsService.loadProfiles();
      final path = await _settingsService.getSettingsPath();
      
      setState(() {
        _profiles = profiles;
        _settingsPath = path;
        _isLoading = false;
      });

      // If no profiles exist, create a default one
      if (_profiles.isEmpty) {
        await _createDefaultProfile();
      }
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnackBar('Error loading profiles: $e', isError: true);
    }
  }

  Future<void> _createDefaultProfile() async {
    final profile = AccountProfile.create('Default Account');
    profile.cookie = widget.currentCookie ?? '';
    profile.isActive = true;
    
    await _settingsService.addProfile(profile);
    await _loadProfiles();
  }

  Future<void> _showCreateProfileDialog() async {
    final nameController = TextEditingController();
    
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Profile'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(
            labelText: 'Profile Name',
            hintText: 'e.g., Work Account, Personal...',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, nameController.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    
    if (result != null && result.trim().isNotEmpty) {
      final profile = AccountProfile.create(result.trim());
      await _settingsService.addProfile(profile);
      await _loadProfiles();
      _showSnackBar('Profile "${result.trim()}" created!');
    }
  }

  Future<void> _deleteProfile(AccountProfile profile) async {
    if (_profiles.length <= 1) {
      _showSnackBar('Cannot delete the last profile', isError: true);
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Profile'),
        content: Text('Are you sure you want to delete "${profile.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _settingsService.deleteProfile(profile.id);
      await _loadProfiles();
      _showSnackBar('Profile deleted');
    }
  }

  Future<void> _setActiveProfile(AccountProfile profile) async {
    await _settingsService.setActiveProfile(profile.id);
    await _loadProfiles();
    
    // Notify parent about credential change
    if (widget.onSave != null) {
      widget.onSave!(
        profile.getAuthToken(),
        profile.cookie,
        widget.currentAspectRatio ?? 'IMAGE_ASPECT_RATIO_LANDSCAPE',
      );
    }
    _showSnackBar('Switched to "${profile.name}"');
  }

  Future<void> _fetchTokenForProfile(AccountProfile profile) async {
    if (profile.cookie.isEmpty) {
      _showSnackBar('Please enter cookies first', isError: true);
      return;
    }

    setState(() {
      _fetchingTokens[profile.id] = true;
    });

    try {
      final result = await _tokenService.fetchToken(profile.cookie);
      
      if (result.success) {
        profile.cachedAuthToken = result.token;
        profile.tokenExpiry = result.expiry;
        await _settingsService.updateProfile(profile);
        await _loadProfiles();
        
        // If active profile, update parent
        if (profile.isActive && widget.onSave != null) {
          widget.onSave!(
            result.token!,
            profile.cookie,
            widget.currentAspectRatio ?? 'IMAGE_ASPECT_RATIO_LANDSCAPE',
          );
        }
        
        _showSnackBar('Token fetched! Expires: ${profile.getTokenExpiryText()}');
      } else {
        _showSnackBar('Failed: ${result.error}', isError: true);
      }
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    } finally {
      setState(() {
        _fetchingTokens[profile.id] = false;
      });
    }
  }

  Future<void> _updateProfileCookie(AccountProfile profile, String cookie) async {
    profile.cookie = cookie;
    // Clear cached token when cookie changes
    profile.cachedAuthToken = null;
    profile.tokenExpiry = null;
    await _settingsService.updateProfile(profile);
    await _loadProfiles();
  }

  void _showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Create Profile',
            onPressed: _showCreateProfileDialog,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header
                  Card(
                    color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(Icons.account_circle, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Account Profiles',
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  '${_profiles.length} profile${_profiles.length == 1 ? '' : 's'} • Paste cookies to auto-generate token',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          ElevatedButton.icon(
                            onPressed: _showCreateProfileDialog,
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('New'),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 12),
                  
                  // Profile Cards
                  ..._profiles.map((profile) => _buildProfileCard(profile)),
                  
                  const SizedBox(height: 16),
                  
                  // Settings Path
                  if (_settingsPath.isNotEmpty)
                    Card(
                      elevation: 1,
                      color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.folder_outlined, size: 16, color: Colors.grey[600]),
                                const SizedBox(width: 8),
                                Text(
                                  'Settings Location:',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            SelectableText(
                              _settingsPath,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                                color: Colors.grey[700],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _buildProfileCard(AccountProfile profile) {
    final isExpanded = _expandedProfileId == profile.id;
    final tokenStatus = profile.getTokenStatus();
    final isFetching = _fetchingTokens[profile.id] ?? false;
    
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: profile.isActive ? 3 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: profile.isActive 
            ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: Column(
        children: [
          // Header row
          InkWell(
            onTap: () {
              setState(() {
                _expandedProfileId = isExpanded ? null : profile.id;
              });
            },
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  // Active radio button
                  Radio<String>(
                    value: profile.id,
                    groupValue: _profiles.firstWhere((p) => p.isActive, orElse: () => _profiles[0]).id,
                    onChanged: (value) {
                      if (value != null) _setActiveProfile(profile);
                    },
                  ),
                  
                  // Profile info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              profile.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                            if (profile.isActive) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.green.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  'Active',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.green,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        // Token status row
                        Row(
                          children: [
                            _buildTokenStatusIndicator(tokenStatus),
                            const SizedBox(width: 6),
                            Text(
                              'Token: ${profile.getTokenExpiryText()}',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  
                  // Fetch token button
                  if (isFetching)
                    const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 20),
                      tooltip: 'Fetch Token',
                      onPressed: () => _fetchTokenForProfile(profile),
                    ),
                  
                  // Expand/collapse icon
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    color: Colors.grey[600],
                  ),
                ],
              ),
            ),
          ),
          
          // Expanded credentials section
          if (isExpanded)
            _buildExpandedCredentials(profile),
        ],
      ),
    );
  }

  Widget _buildTokenStatusIndicator(String status) {
    Color color;
    IconData icon;
    
    switch (status) {
      case 'valid':
        color = Colors.green;
        icon = Icons.check_circle;
        break;
      case 'expiring':
        color = Colors.orange;
        icon = Icons.warning;
        break;
      case 'expired':
        color = Colors.red;
        icon = Icons.error;
        break;
      case 'manual':
        color = Colors.blue;
        icon = Icons.edit;
        break;
      default:
        color = Colors.grey;
        icon = Icons.help_outline;
    }
    
    return Icon(icon, size: 14, color: color);
  }

  Widget _buildExpandedCredentials(AccountProfile profile) {
    final cookieController = TextEditingController(text: profile.cookie);
    
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        children: [
          const Divider(),
          
          // Cookie input - multi-line, compact
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.cookie, size: 16, color: Colors.grey[600]),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: cookieController,
                  maxLines: 3,
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    labelText: 'Cookies (any format: raw, JSON, header, netscape)',
                    labelStyle: const TextStyle(fontSize: 12),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    hintText: 'Paste cookies here...',
                    hintStyle: TextStyle(fontSize: 10, color: Colors.grey[500]),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.content_paste, size: 16),
                      tooltip: 'Paste',
                      onPressed: () async {
                        final data = await Clipboard.getData('text/plain');
                        if (data?.text != null) {
                          cookieController.text = data!.text!;
                        }
                      },
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(maxWidth: 32, maxHeight: 32),
                    ),
                  ),
                ),
              ),
            ],
          ),
          
          const SizedBox(height: 12),
          
          // Action buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // Delete button
              TextButton.icon(
                onPressed: () => _deleteProfile(profile),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Delete'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.red,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
              ),
              const SizedBox(width: 8),
              // Save & Fetch button
              ElevatedButton.icon(
                onPressed: () async {
                  await _updateProfileCookie(profile, cookieController.text.trim());
                  await _fetchTokenForProfile(profile);
                },
                icon: const Icon(Icons.key, size: 18),
                label: const Text('Save & Fetch Token'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
