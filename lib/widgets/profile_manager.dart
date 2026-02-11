import 'package:flutter/material.dart';
import 'dart:io';
import 'package:path/path.dart' as path;
import '../utils/config.dart';

class ProfileManagerWidget extends StatefulWidget {
  final String selectedProfile;
  final Function(String) onProfileChanged;
  final VoidCallback onLaunchChrome;

  const ProfileManagerWidget({
    super.key,
    required this.selectedProfile,
    required this.onProfileChanged,
    required this.onLaunchChrome,
  });

  @override
  State<ProfileManagerWidget> createState() => _ProfileManagerWidgetState();
}

class _ProfileManagerWidgetState extends State<ProfileManagerWidget> {
  List<String> profiles = [];

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  Future<void> _loadProfiles() async {
    final profilesDir = Directory(AppConfig.profilesDir);
    if (await profilesDir.exists()) {
      final dirs = await profilesDir.list().where((entity) => entity is Directory).toList();
      setState(() {
        profiles = dirs.map((d) => path.basename(d.path)).toList()..sort();
        if (profiles.isEmpty) {
          profiles = ['Default'];
        }
      });
    } else {
      setState(() {
        profiles = ['Default'];
      });
    }
  }

  Future<void> _createNewProfile() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Profile'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Profile name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      final cleanName = result.replaceAll(RegExp(r'[^\w\s.-]'), '');
      if (cleanName.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Invalid profile name')),
          );
        }
        return;
      }

      final profilePath = path.join(AppConfig.profilesDir, cleanName);
      final dir = Directory(profilePath);

      if (await dir.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Profile already exists')),
          );
        }
        return;
      }

      try {
        await dir.create(recursive: true);
        await _loadProfiles();
        widget.onProfileChanged(cleanName);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Created profile: $cleanName')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to create profile: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Text('Select Profile:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            DropdownButton<String>(
              value: profiles.contains(widget.selectedProfile) ? widget.selectedProfile : profiles.first,
              items: profiles.map((profile) {
                return DropdownMenuItem(
                  value: profile,
                  child: Text(profile),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  widget.onProfileChanged(value);
                }
              },
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: widget.onLaunchChrome,
              icon: const Icon(Icons.rocket_launch, size: 16),
              label: const Text('Launch Chrome'),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: _createNewProfile,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('New Profile'),
            ),
            const SizedBox(width: 16),
            const Expanded(
              child: Text(
                '(Launch Chrome first, log in, then start generation)',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
