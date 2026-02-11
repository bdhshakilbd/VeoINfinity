import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import '../services/update_service.dart';

/// Dialog shown when app update is available
class UpdateDialog extends StatefulWidget {
  final UpdateInfo updateInfo;
  final bool canDismiss; // If false, user must update
  
  const UpdateDialog({
    Key? key,
    required this.updateInfo,
    this.canDismiss = true,
  }) : super(key: key);

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
  
  /// Show update dialog
  static Future<void> show(BuildContext context, UpdateInfo updateInfo, {bool canDismiss = true}) {
    return showDialog(
      context: context,
      barrierDismissible: canDismiss,
      builder: (context) => UpdateDialog(
        updateInfo: updateInfo,
        canDismiss: canDismiss,
      ),
    );
  }
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String _statusMessage = '';
  
  Future<void> _downloadAndInstall() async {
    if (widget.updateInfo.downloadUrl == null) {
      setState(() => _statusMessage = 'No download URL available');
      return;
    }
    
    setState(() {
      _isDownloading = true;
      _statusMessage = 'Starting download...';
      _downloadProgress = 0.0;
    });
    
    try {
      final url = widget.updateInfo.downloadUrl!;
      final fileName = url.split('/').last;
      
      // Get downloads directory
      final downloadsDir = await getDownloadsDirectory();
      final filePath = '${downloadsDir?.path ?? Directory.current.path}\\$fileName';
      
      setState(() => _statusMessage = 'Downloading to: $filePath');
      
      // Use HttpClient with SSL certificate bypass for compatibility
      // This handles cases where system root certificates are outdated
      final httpClient = HttpClient()
        ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
      
      final request = await httpClient.getUrl(Uri.parse(url));
      final response = await request.close();
      
      if (response.statusCode != 200) {
        throw Exception('Failed to download: ${response.statusCode}');
      }
      
      final file = File(filePath);
      final sink = file.openWrite();
      final total = response.contentLength;
      int received = 0;
      
      await for (var chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          setState(() {
            _downloadProgress = received / total;
            _statusMessage = 'Downloading... ${(received / 1024 / 1024).toStringAsFixed(1)} MB / ${(total / 1024 / 1024).toStringAsFixed(1)} MB';
          });
        }
      }
      
      await sink.close();
      httpClient.close();
      
      setState(() {
        _statusMessage = '✅ Downloaded! Launching installer...';
        _downloadProgress = 1.0;
      });
      
      // Auto-run installer for Windows .exe
      if (fileName.toLowerCase().endsWith('.exe')) {
        // Launch installer detached from this process
        await Process.start(filePath, [], mode: ProcessStartMode.detached);
        
        setState(() => _statusMessage = '✅ Installer launched! App will close in 2 seconds...');
        
        // Wait 2 seconds then close the app so installer can proceed
        await Future.delayed(const Duration(seconds: 2));
        
        // Close the app to allow installer to replace files
        exit(0);
      } else {
        // For other files, just open the folder
        await Process.run('explorer', ['/select,', filePath]);
        setState(() => _statusMessage = '✅ Download complete! File saved to Downloads.');
      }
      
    } catch (e) {
      setState(() {
        _statusMessage = '❌ Error: $e';
        _isDownloading = false;
      });
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(Icons.system_update, color: Theme.of(context).primaryColor, size: 28),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Update Available',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Version info
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Current',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      ),
                      Text(
                        widget.updateInfo.currentVersion,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const Icon(Icons.arrow_forward, color: Colors.blue),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'Latest',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      ),
                      Text(
                        widget.updateInfo.latestVersion,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.green,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            
            const SizedBox(height: 16),
            
            // Release notes
            const Text(
              'What\'s New:',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Text(
                widget.updateInfo.releaseNotes,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            
            // Download progress
            if (_isDownloading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _downloadProgress),
              const SizedBox(height: 8),
              Text(
                _statusMessage,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
            ] else if (_statusMessage.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                _statusMessage,
                style: TextStyle(
                  fontSize: 12,
                  color: _statusMessage.contains('✅') ? Colors.green : Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (widget.canDismiss && !_isDownloading)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Later'),
          ),
        if (!_isDownloading)
          ElevatedButton.icon(
            onPressed: _downloadAndInstall,
            icon: const Icon(Icons.download),
            label: const Text('Auto Download & Install'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
          ),
      ],
    );
  }
}

/// Update indicator icon for menu bar
class UpdateIndicator extends StatelessWidget {
  final VoidCallback? onTap;
  
  const UpdateIndicator({Key? key, this.onTap}) : super(key: key);
  
  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Stack(
        children: [
          const Icon(Icons.system_update_alt),
          Positioned(
            right: 0,
            top: 0,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: Colors.red,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
            ),
          ),
        ],
      ),
      tooltip: 'Update Available',
      onPressed: () {
        final updateInfo = UpdateService.instance.updateInfo;
        if (updateInfo != null) {
          UpdateDialog.show(context, updateInfo);
        }
        onTap?.call();
      },
    );
  }
}
