import 'dart:async';

class LogEntry {
  final DateTime timestamp;
  final String message;
  final String type; // 'info', 'error', 'network'
  
  LogEntry(this.message, {this.type = 'info'}) : timestamp = DateTime.now();
  
  @override
  String toString() => '${timestamp.toIso8601String().split('T')[1].substring(0,8)} [$type] $message';
}

class LogService {
  static final LogService _instance = LogService._internal();
  factory LogService() => _instance;
  LogService._internal();
  
  final List<LogEntry> logs = [];
  // Use broadcast stream for UI updates
  final _controller = StreamController<List<LogEntry>>.broadcast();
  Stream<List<LogEntry>> get stream => _controller.stream;
  
  void info(String message) => add(message, type: 'INFO');
  void error(String message) => add(message, type: 'ERROR');
  void network(String message) => add(message, type: 'NET');
  void mobile(String message) => add(message, type: 'MOBILE');
  
  void add(String message, {String type = 'INFO'}) {
    logs.add(LogEntry(message, type: type));
    if (logs.length > 1000) logs.removeAt(0); // Keep last 1000 logs
    _controller.add(List.from(logs));
    
    // Also print to system console for VSCode debugging
    print('[$type] $message');
  }
  
  void clear() {
    logs.clear();
    _controller.add([]);
  }
}
