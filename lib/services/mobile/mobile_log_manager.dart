import 'dart:async';

/// Global log manager for mobile browser activities
/// Used to display logs in the Browser tab UI
class MobileLogManager {
  static final MobileLogManager _instance = MobileLogManager._internal();
  factory MobileLogManager() => _instance;
  MobileLogManager._internal();
  
  final List<String> _logs = [];
  final _controller = StreamController<String>.broadcast();
  
  /// Maximum number of logs to keep
  static const int maxLogs = 200;
  
  /// Get all logs
  List<String> get logs => List.unmodifiable(_logs);
  
  /// Stream of new log entries
  Stream<String> get stream => _controller.stream;
  
  /// Add a log entry
  void log(String message) {
    final timestamp = DateTime.now().toString().substring(11, 19); // HH:MM:SS
    final entry = '[$timestamp] $message';
    
    _logs.add(entry);
    
    // Keep only the last maxLogs entries
    if (_logs.length > maxLogs) {
      _logs.removeAt(0);
    }
    
    _controller.add(entry);
    
    // Also print to console for debugging
    print(message);
  }
  
  /// Clear all logs
  void clear() {
    _logs.clear();
    _controller.add('[CLEARED]');
  }
  
  /// Dispose the stream controller
  void dispose() {
    _controller.close();
  }
}

/// Global log function for easy access
void mobileLog(String message) {
  MobileLogManager().log(message);
}
