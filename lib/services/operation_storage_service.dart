import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Stores operation details locally for recovery after browser restart/relogin
class OperationStorageService {
  static final OperationStorageService _instance = OperationStorageService._internal();
  factory OperationStorageService() => _instance;
  OperationStorageService._internal();

  final Map<String, OperationRecord> _operations = {};
  String? _storagePath;

  /// Initialize storage
  Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _storagePath = '${dir.path}/veo3_operations.json';
      await _loadFromDisk();
      print('[OperationStorage] Initialized with ${_operations.length} saved operations');
    } catch (e) {
      print('[OperationStorage] Init error: $e');
    }
  }

  /// Save an operation when generation starts
  Future<void> saveOperation({
    required String sceneId,
    required String prompt,
    required String operationName,
    String? browserName,
  }) async {
    final record = OperationRecord(
      sceneId: sceneId,
      prompt: prompt,
      operationName: operationName,
      browserName: browserName,
      createdAt: DateTime.now(),
      status: 'pending',
    );
    
    _operations[sceneId] = record;
    await _saveToDisk();
    
    print('[OperationStorage] Saved: sceneId=$sceneId, op=${operationName.substring(0, 50)}...');
  }

  /// Update operation status
  Future<void> updateStatus(String sceneId, String status, {String? videoUrl, String? error}) async {
    final record = _operations[sceneId];
    if (record != null) {
      record.status = status;
      record.videoUrl = videoUrl;
      record.error = error;
      record.updatedAt = DateTime.now();
      await _saveToDisk();
      print('[OperationStorage] Updated: sceneId=$sceneId, status=$status');
    }
  }

  /// Get operation by scene ID
  OperationRecord? getBySceneId(String sceneId) {
    return _operations[sceneId];
  }

  /// Get operation by operation name
  OperationRecord? getByOperationName(String operationName) {
    return _operations.values.firstWhere(
      (op) => op.operationName == operationName,
      orElse: () => OperationRecord.empty(),
    );
  }

  /// Get all pending operations (for recovery polling)
  List<OperationRecord> getPendingOperations() {
    return _operations.values
        .where((op) => op.status == 'pending' || op.status == 'active')
        .toList();
  }

  /// Get all operations
  List<OperationRecord> getAllOperations() {
    return _operations.values.toList();
  }

  /// Clear completed operations older than 24 hours
  Future<void> cleanup() async {
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    _operations.removeWhere((key, op) => 
      op.status == 'complete' && op.createdAt.isBefore(cutoff)
    );
    await _saveToDisk();
  }

  /// Load from disk
  Future<void> _loadFromDisk() async {
    if (_storagePath == null) return;
    
    try {
      final file = File(_storagePath!);
      if (await file.exists()) {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        
        for (final entry in json.entries) {
          try {
            _operations[entry.key] = OperationRecord.fromJson(entry.value);
          } catch (e) {
            print('[OperationStorage] Parse error for ${entry.key}: $e');
          }
        }
      }
    } catch (e) {
      print('[OperationStorage] Load error: $e');
    }
  }

  /// Save to disk
  Future<void> _saveToDisk() async {
    if (_storagePath == null) return;
    
    try {
      final json = <String, dynamic>{};
      for (final entry in _operations.entries) {
        json[entry.key] = entry.value.toJson();
      }
      
      final file = File(_storagePath!);
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
    } catch (e) {
      print('[OperationStorage] Save error: $e');
    }
  }

  /// Export all operations as JSON string (for debugging)
  String exportToJson() {
    final json = <String, dynamic>{};
    for (final entry in _operations.entries) {
      json[entry.key] = entry.value.toJson();
    }
    return const JsonEncoder.withIndent('  ').convert(json);
  }
}

/// Single operation record
class OperationRecord {
  final String sceneId;
  final String prompt;
  final String operationName;
  final String? browserName;
  final DateTime createdAt;
  DateTime? updatedAt;
  String status; // pending, active, complete, failed
  String? videoUrl;
  String? error;

  OperationRecord({
    required this.sceneId,
    required this.prompt,
    required this.operationName,
    this.browserName,
    required this.createdAt,
    this.status = 'pending',
    this.videoUrl,
    this.error,
    this.updatedAt,
  });

  factory OperationRecord.empty() => OperationRecord(
    sceneId: '',
    prompt: '',
    operationName: '',
    createdAt: DateTime.now(),
  );

  bool get isEmpty => sceneId.isEmpty;

  factory OperationRecord.fromJson(Map<String, dynamic> json) {
    return OperationRecord(
      sceneId: json['sceneId'] ?? '',
      prompt: json['prompt'] ?? '',
      operationName: json['operationName'] ?? '',
      browserName: json['browserName'],
      createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
      updatedAt: json['updatedAt'] != null ? DateTime.tryParse(json['updatedAt']) : null,
      status: json['status'] ?? 'pending',
      videoUrl: json['videoUrl'],
      error: json['error'],
    );
  }

  Map<String, dynamic> toJson() => {
    'sceneId': sceneId,
    'prompt': prompt,
    'operationName': operationName,
    'browserName': browserName,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt?.toIso8601String(),
    'status': status,
    'videoUrl': videoUrl,
    'error': error,
  };

  @override
  String toString() => 'OperationRecord($sceneId, $status, op=${operationName.substring(0, 30)}...)';
}
