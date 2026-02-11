
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';

class ProcessingMonitor extends StatefulWidget {
  final Future<String> expectedPathFuture;
  final Function(File) onFileFound;

  const ProcessingMonitor({
    Key? key,
    required this.expectedPathFuture,
    required this.onFileFound,
  }) : super(key: key);

  @override
  State<ProcessingMonitor> createState() => _ProcessingMonitorState();
}

class _ProcessingMonitorState extends State<ProcessingMonitor> {
  Timer? _timer;
  String? _resolvedPath;
  int _checks = 0;
  // Stop after 60 seconds (60 checks at 1s interval)
  static const int _maxChecks = 60;

  @override
  void initState() {
    super.initState();
    _startMonitoring();
  }

  void _startMonitoring() async {
    try {
      _resolvedPath = await widget.expectedPathFuture;
      if (!mounted) return;
      
      print('   🕵️ Monitor started for: $_resolvedPath');
      
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        _checkFile();
      });
      // Initial check immediately
      _checkFile();
      
    } catch (e) {
      print('   ⚠️ Monitor failed to resolve path: $e');
    }
  }

  void _checkFile() {
    if (_resolvedPath == null) return;
    
    _checks++;
    final file = File(_resolvedPath!);
    if (file.existsSync()) {
      // Double check size to ensure it's not 0 bytes (write in progress)
      if (file.lengthSync() > 0) {
        print('   ✅ Monitor FOUND file: $_resolvedPath');
        _timer?.cancel();
        if (mounted) {
            widget.onFileFound(file);
        }
      }
    } else {
      if (_checks >= _maxChecks) {
        print('   ❌ Monitor timed out searching for: $_resolvedPath');
        _timer?.cancel();
      } else if (_checks % 5 == 0) {
        print('   ... Monitor still searching (${_checks}/$_maxChecks)');
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Extract filename for debug display
    final filename = _resolvedPath?.split(Platform.pathSeparator).last ?? 'Resolving...';
    
    return Container(
      color: Colors.grey.shade100,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 24, 
              height: 24, 
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.purple.shade300,
              )
            ),
            const SizedBox(height: 8),
            Text(
              'Generating...',
              style: TextStyle(
                color: Colors.purple.shade300,
                fontSize: 10,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 4),
            // Debug info text
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4.0),
              child: Text(
                filename,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.grey.shade400,
                  fontSize: 7,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Manual controls if stuck
            if (_checks > 5) ...[
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                   // Force Check
                   InkWell(
                     onTap: () {
                       _checkFile();
                       // Also trigger parent reload?
                     },
                     child: Icon(Icons.refresh, size: 14, color: Colors.grey.shade500),
                   ),
                   const SizedBox(width: 8),
                   // Cancel / Force file path
                   InkWell(
                     onTap: () {
                         // Force assume file exists if user clicks this
                         if (_resolvedPath != null) {
                           widget.onFileFound(File(_resolvedPath!));
                         }
                     },
                     child: Icon(Icons.check_circle_outline, size: 14, color: Colors.green.shade300),
                   ),
                ],
              )
            ]
          ],
        ),
      ),
    );
  }
}
