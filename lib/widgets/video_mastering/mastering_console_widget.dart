/// Console Log Widget for Video Mastering Screen
/// A dedicated embedded console panel that displays real-time logs

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';

/// Global log controller for the mastering console
class MasteringConsole {
  static final MasteringConsole _instance = MasteringConsole._internal();
  factory MasteringConsole() => _instance;
  MasteringConsole._internal();
  
  final List<ConsoleLogEntry> _logs = [];
  final StreamController<List<ConsoleLogEntry>> _logController = 
      StreamController<List<ConsoleLogEntry>>.broadcast();
  
  static const int maxLogs = 500; // Keep last 500 entries
  
  /// Stream of log entries
  Stream<List<ConsoleLogEntry>> get logStream => _logController.stream;
  
  /// Current logs
  List<ConsoleLogEntry> get logs => List.unmodifiable(_logs);
  
  /// Add a log entry
  static void log(String message, {LogLevel level = LogLevel.info}) {
    _instance._addLog(message, level);
  }
  
  /// Convenience methods
  static void info(String message) => log(message, level: LogLevel.info);
  static void success(String message) => log(message, level: LogLevel.success);
  static void warning(String message) => log(message, level: LogLevel.warning);
  static void error(String message) => log(message, level: LogLevel.error);
  static void debug(String message) => log(message, level: LogLevel.debug);
  static void ffmpeg(String message) => log(message, level: LogLevel.ffmpeg);
  
  void _addLog(String message, LogLevel level) {
    final entry = ConsoleLogEntry(
      timestamp: DateTime.now(),
      message: message,
      level: level,
    );
    
    _logs.add(entry);
    
    // Trim old logs
    if (_logs.length > maxLogs) {
      _logs.removeRange(0, _logs.length - maxLogs);
    }
    
    _logController.add(List.from(_logs));
    
    // Also print to system console for debugging
    print('[Mastering] [${level.name.toUpperCase()}] $message');
  }
  
  /// Clear all logs
  static void clear() {
    _instance._logs.clear();
    _instance._logController.add([]);
  }
  
  void dispose() {
    _logController.close();
  }
}

/// Log level enum
enum LogLevel {
  debug,
  info,
  success,
  warning,
  error,
  ffmpeg,
}

/// Single log entry
class ConsoleLogEntry {
  final DateTime timestamp;
  final String message;
  final LogLevel level;
  
  ConsoleLogEntry({
    required this.timestamp,
    required this.message,
    required this.level,
  });
  
  Color get color {
    switch (level) {
      case LogLevel.debug:
        return Colors.grey;
      case LogLevel.info:
        return Colors.white70;
      case LogLevel.success:
        return Colors.greenAccent;
      case LogLevel.warning:
        return Colors.orangeAccent;
      case LogLevel.error:
        return Colors.redAccent;
      case LogLevel.ffmpeg:
        return Colors.cyanAccent;
    }
  }
  
  String get prefix {
    switch (level) {
      case LogLevel.debug:
        return '[DEBUG]';
      case LogLevel.info:
        return '[INFO]';
      case LogLevel.success:
        return '[✓]';
      case LogLevel.warning:
        return '[WARN]';
      case LogLevel.error:
        return '[ERROR]';
      case LogLevel.ffmpeg:
        return '[FFMPEG]';
    }
  }
}

/// Console Panel Widget
class MasteringConsolePanel extends StatefulWidget {
  final double height;
  final bool showHeader;
  
  const MasteringConsolePanel({
    super.key,
    this.height = 200,
    this.showHeader = true,
  });
  
  @override
  State<MasteringConsolePanel> createState() => _MasteringConsolePanelState();
}

class _MasteringConsolePanelState extends State<MasteringConsolePanel> {
  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;
  bool _isExpanded = true;
  StreamSubscription<List<ConsoleLogEntry>>? _subscription;
  List<ConsoleLogEntry> _logs = [];
  
  @override
  void initState() {
    super.initState();
    _logs = MasteringConsole().logs;
    _subscription = MasteringConsole().logStream.listen((logs) {
      setState(() {
        _logs = logs;
      });
      if (_autoScroll) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 100),
              curve: Curves.easeOut,
            );
          }
        });
      }
    });
  }
  
  @override
  void dispose() {
    _subscription?.cancel();
    _scrollController.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return Container(
      height: _isExpanded ? widget.height : 36,
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D14),
        border: Border(
          top: BorderSide(color: Colors.grey.shade800, width: 1),
        ),
      ),
      child: Column(
        children: [
          // Header
          if (widget.showHeader)
            Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A24),
                border: Border(
                  bottom: BorderSide(color: Colors.grey.shade800, width: 1),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.terminal,
                    size: 16,
                    color: Colors.grey.shade400,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Console',
                    style: TextStyle(
                      color: Colors.grey.shade300,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.blueGrey.shade800,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${_logs.length}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 10,
                      ),
                    ),
                  ),
                  const Spacer(),
                  // Auto-scroll toggle
                  Tooltip(
                    message: 'Auto-scroll',
                    child: IconButton(
                      icon: Icon(
                        _autoScroll ? Icons.vertical_align_bottom : Icons.pause,
                        size: 16,
                        color: _autoScroll ? Colors.greenAccent : Colors.grey,
                      ),
                      onPressed: () {
                        setState(() {
                          _autoScroll = !_autoScroll;
                        });
                      },
                      splashRadius: 16,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    ),
                  ),
                  // Copy all
                  Tooltip(
                    message: 'Copy all logs',
                    child: IconButton(
                      icon: Icon(
                        Icons.copy,
                        size: 16,
                        color: Colors.grey.shade400,
                      ),
                      onPressed: () {
                        final text = _logs.map((e) => 
                          '[${e.timestamp.hour}:${e.timestamp.minute.toString().padLeft(2, '0')}:${e.timestamp.second.toString().padLeft(2, '0')}] ${e.prefix} ${e.message}'
                        ).join('\n');
                        Clipboard.setData(ClipboardData(text: text));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Logs copied to clipboard'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      },
                      splashRadius: 16,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    ),
                  ),
                  // Clear
                  Tooltip(
                    message: 'Clear console',
                    child: IconButton(
                      icon: Icon(
                        Icons.delete_outline,
                        size: 16,
                        color: Colors.grey.shade400,
                      ),
                      onPressed: () {
                        MasteringConsole.clear();
                      },
                      splashRadius: 16,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    ),
                  ),
                  // Expand/Collapse
                  Tooltip(
                    message: _isExpanded ? 'Collapse' : 'Expand',
                    child: IconButton(
                      icon: Icon(
                        _isExpanded ? Icons.expand_more : Icons.expand_less,
                        size: 18,
                        color: Colors.grey.shade400,
                      ),
                      onPressed: () {
                        setState(() {
                          _isExpanded = !_isExpanded;
                        });
                      },
                      splashRadius: 16,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    ),
                  ),
                ],
              ),
            ),
          // Log content
          if (_isExpanded)
            Expanded(
              child: _logs.isEmpty
                  ? Center(
                      child: Text(
                        'No logs yet...',
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(8),
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        final entry = _logs[index];
                        final time = '${entry.timestamp.hour.toString().padLeft(2, '0')}:${entry.timestamp.minute.toString().padLeft(2, '0')}:${entry.timestamp.second.toString().padLeft(2, '0')}';
                        
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: SelectableText.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '[$time] ',
                                  style: TextStyle(
                                    color: Colors.grey.shade600,
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                                TextSpan(
                                  text: '${entry.prefix} ',
                                  style: TextStyle(
                                    color: entry.color,
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                TextSpan(
                                  text: entry.message,
                                  style: TextStyle(
                                    color: entry.color.withOpacity(0.9),
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
        ],
      ),
    );
  }
}
