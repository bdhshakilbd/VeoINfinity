import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as path;

/// A log entry with type and message
class LogEntry {
  final String type;
  final String message;
  final DateTime timestamp;

  LogEntry({required this.type, required this.message, DateTime? timestamp})
      : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() => '[$type] $message';
}

/// Singleton LogService for capturing and streaming application logs
/// Logs are stored in memory and can be streamed to UI widgets
/// Also writes logs to a shared file for cross-process access
class LogService {
  static final LogService _instance = LogService._internal();
  factory LogService() => _instance;
  LogService._internal() {
    _initLogFile();
  }

  final List<LogEntry> _logs = [];
  final StreamController<List<LogEntry>> _controller =
      StreamController<List<LogEntry>>.broadcast();

  static const int _maxLogs = 1000;
  
  // Shared log file path for cross-process communication
  File? _logFile;
  int _lastReadPosition = 0;
  Timer? _fileWatchTimer;

  void _initLogFile() {
    try {
      final tempDir = Directory.systemTemp;
      _logFile = File(path.join(tempDir.path, 'veo3_shared_logs.txt'));
      // Clear old logs on startup (only in main app mode)
      if (_logFile!.existsSync()) {
        // Don't clear - we want to read existing logs
      }
    } catch (e) {
      print('[LogService] Error initializing log file: $e');
    }
  }

  /// Get all logs
  List<LogEntry> get logs => List.unmodifiable(_logs);

  /// Stream of log updates
  Stream<List<LogEntry>> get stream => _controller.stream;

  /// Add a log entry
  void add(String message, {String type = 'INFO'}) {
    final entry = LogEntry(type: type, message: message);
    _logs.add(entry);
    
    // Trim if over max
    if (_logs.length > _maxLogs) {
      _logs.removeRange(0, _logs.length - _maxLogs);
    }
    
    // Write to shared file for cross-process access
    _writeToFile(entry);
    
    // Notify listeners
    _controller.add(List.unmodifiable(_logs));
  }

  /// Convenience method for mobile logs
  void mobile(String message) => add(message, type: 'MOBILE');
  
  /// Convenience method for error logs
  void error(String message) => add(message, type: 'ERROR');
  
  /// Convenience method for info logs
  void info(String message) => add(message, type: 'INFO');
  
  /// Convenience method for network logs
  void net(String message) => add(message, type: 'NET');
  
  /// Convenience method for generation logs
  void gen(String message) => add(message, type: 'GEN');
  
  /// Convenience method for success logs
  void success(String message) => add(message, type: 'SUCCESS');


  /// Write log entry to shared file
  void _writeToFile(LogEntry entry) {
    if (_logFile == null) return;
    try {
      final timestamp = entry.timestamp.toIso8601String();
      final line = '[$timestamp][${entry.type}] ${entry.message}\n';
      _logFile!.writeAsStringSync(line, mode: FileMode.append);
    } catch (e) {
      // Silently fail file writes
    }
  }

  /// Start watching the shared log file (for logs viewer window)
  void startWatchingFile() {
    _fileWatchTimer?.cancel();
    _lastReadPosition = 0;
    
    // Clear existing logs
    _logs.clear();
    
    // Read existing content first
    _readNewLogs();
    
    // Then poll for new logs every 500ms
    _fileWatchTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _readNewLogs();
    });
  }

  /// Stop watching the log file
  void stopWatchingFile() {
    _fileWatchTimer?.cancel();
    _fileWatchTimer = null;
  }

  /// Read new logs from the shared file
  void _readNewLogs() {
    if (_logFile == null || !_logFile!.existsSync()) return;
    
    try {
      final content = _logFile!.readAsStringSync();
      if (content.length <= _lastReadPosition) return;
      
      final newContent = content.substring(_lastReadPosition);
      _lastReadPosition = content.length;
      
      // Parse new lines
      final lines = newContent.split('\n').where((l) => l.isNotEmpty);
      for (final line in lines) {
        // Parse format: [timestamp][TYPE] message
        final match = RegExp(r'\[([^\]]+)\]\[([^\]]+)\] (.*)').firstMatch(line);
        if (match != null) {
          final timestamp = DateTime.tryParse(match.group(1) ?? '') ?? DateTime.now();
          final type = match.group(2) ?? 'INFO';
          final message = match.group(3) ?? line;
          final entry = LogEntry(type: type, message: message, timestamp: timestamp);
          _logs.add(entry);
        } else {
          // Fallback: treat whole line as message
          _logs.add(LogEntry(type: 'INFO', message: line));
        }
      }
      
      // Trim if over max
      if (_logs.length > _maxLogs) {
        _logs.removeRange(0, _logs.length - _maxLogs);
      }
      
      // Notify listeners
      _controller.add(List.unmodifiable(_logs));
    } catch (e) {
      // Silently fail
    }
  }

  /// Clear all logs
  void clear() {
    _logs.clear();
    _controller.add([]);
    
    // Clear the file too
    try {
      _logFile?.writeAsStringSync('');
      _lastReadPosition = 0;
    } catch (e) {
      // Silently fail
    }
  }

  /// Dispose the service
  void dispose() {
    _fileWatchTimer?.cancel();
    _controller.close();
  }
}
