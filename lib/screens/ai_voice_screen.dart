import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/gemini_key_service.dart';
import '../services/story/gemini_tts_service.dart';

// Gemini TTS Voice Options
class GeminiVoice {
  final String id;
  final String name;
  final String gender;
  final String accent;
  bool isFavorite;

  GeminiVoice({
    required this.id,
    required this.name,
    required this.gender,
    required this.accent,
    this.isFavorite = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'gender': gender,
    'accent': accent,
    'isFavorite': isFavorite,
  };

  factory GeminiVoice.fromJson(Map<String, dynamic> json) => GeminiVoice(
    id: json['id'] ?? '',
    name: json['name'] ?? '',
    gender: json['gender'] ?? '',
    accent: json['accent'] ?? '',
    isFavorite: json['isFavorite'] ?? false,
  );
}

// Voice Task for queuing
class VoiceTask {
  final String id;
  final String text;
  final String voiceId;
  final String voiceName;
  final Map<String, dynamic> settings;
  String status; // 'pending', 'processing', 'completed', 'failed'
  String? outputPath;
  String? error;
  int retryCount;
  DateTime createdAt;

  VoiceTask({
    required this.id,
    required this.text,
    required this.voiceId,
    required this.voiceName,
    required this.settings,
    this.status = 'pending',
    this.outputPath,
    this.error,
    this.retryCount = 0,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
}

// Voice Preset
class VoicePreset {
  final String name;
  final String pace;
  final String tone;
  final String style;
  final String instruction;

  const VoicePreset({
    required this.name,
    required this.pace,
    required this.tone,
    required this.style,
    required this.instruction,
  });
}

class AIVoiceScreen extends StatefulWidget {
  final List<String>? geminiApiKeys;
  
  const AIVoiceScreen({super.key, this.geminiApiKeys});

  @override
  State<AIVoiceScreen> createState() => _AIVoiceScreenState();
}

class _AIVoiceScreenState extends State<AIVoiceScreen> {
  // Controllers
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _paceController = TextEditingController(text: '1.0');
  final TextEditingController _toneController = TextEditingController(text: 'neutral');
  final TextEditingController _styleController = TextEditingController(text: 'conversational');
  final TextEditingController _instructionController = TextEditingController();
  
  // State
  List<GeminiVoice> _voices = [];
  List<VoiceTask> _tasks = [];
  List<String> _generatedFiles = [];
  String? _selectedVoiceId;
  String _selectedModel = 'gemini-2.5-flash-preview-tts';
  bool _isProcessing = false;
  int _currentApiIndex = 0;

  String? _playingFile;
  String _outputFolder = '';
  List<String> _apiKeysList = [];
  final GeminiTtsService _ttsService = GeminiTtsService();
  
  // Presets
  final List<VoicePreset> _presets = const [
    VoicePreset(name: 'Natural', pace: '1.0', tone: 'neutral', style: 'conversational', instruction: 'Speak naturally and clearly'),
    VoicePreset(name: 'Energetic', pace: '1.2', tone: 'enthusiastic', style: 'upbeat', instruction: 'Speak with energy and excitement'),
    VoicePreset(name: 'Calm', pace: '0.9', tone: 'calm', style: 'soothing', instruction: 'Speak in a calm, relaxed manner'),
    VoicePreset(name: 'Professional', pace: '1.0', tone: 'formal', style: 'professional', instruction: 'Speak professionally like a news anchor'),
    VoicePreset(name: 'Storyteller', pace: '0.95', tone: 'engaging', style: 'narrative', instruction: 'Speak like telling an engaging story'),
    VoicePreset(name: 'Podcast', pace: '1.05', tone: 'friendly', style: 'casual', instruction: 'Speak like a friendly podcast host'),
  ];

  // Available models
  final List<String> _models = [
    'gemini-2.5-flash-preview-tts',
    'gemini-2.0-flash-exp',
  ];

  // Available voices (All 30 Gemini TTS voices - IDs must be lowercase)
  final List<GeminiVoice> _defaultVoices = [
    GeminiVoice(id: 'puck', name: 'Puck', gender: 'Male', accent: 'English'),
    GeminiVoice(id: 'charon', name: 'Charon', gender: 'Male', accent: 'English'),
    GeminiVoice(id: 'kore', name: 'Kore', gender: 'Female', accent: 'English'),
    GeminiVoice(id: 'fenrir', name: 'Fenrir', gender: 'Male', accent: 'English'),
    GeminiVoice(id: 'aoede', name: 'Aoede', gender: 'Female', accent: 'English'),
    GeminiVoice(id: 'leda', name: 'Leda', gender: 'Female', accent: 'English'),
    GeminiVoice(id: 'orus', name: 'Orus', gender: 'Male', accent: 'English'),
    GeminiVoice(id: 'zephyr', name: 'Zephyr', gender: 'Male', accent: 'English'),
    GeminiVoice(id: 'achernar', name: 'Achernar', gender: 'Male', accent: 'English'),
    GeminiVoice(id: 'achird', name: 'Achird', gender: 'Male', accent: 'English'),
    GeminiVoice(id: 'algenib', name: 'Algenib', gender: 'Male', accent: 'English'),
    GeminiVoice(id: 'algieba', name: 'Algieba', gender: 'Male', accent: 'English'),
    GeminiVoice(id: 'alnilam', name: 'Alnilam', gender: 'Male', accent: 'English'),
    GeminiVoice(id: 'autonoe', name: 'Autonoe', gender: 'Female', accent: 'English'),
    GeminiVoice(id: 'callirrhoe', name: 'Callirrhoe', gender: 'Female', accent: 'English'),
    GeminiVoice(id: 'despina', name: 'Despina', gender: 'Female', accent: 'English'),
    GeminiVoice(id: 'enceladus', name: 'Enceladus', gender: 'Male', accent: 'English'),
    GeminiVoice(id: 'erinome', name: 'Erinome', gender: 'Female', accent: 'English'),
    GeminiVoice(id: 'gacrux', name: 'Gacrux', gender: 'Male', accent: 'English'),
    GeminiVoice(id: 'iapetus', name: 'Iapetus', gender: 'Male', accent: 'English'),
    GeminiVoice(id: 'laomedeia', name: 'Laomedeia', gender: 'Female', accent: 'English'),
    GeminiVoice(id: 'pulcherrima', name: 'Pulcherrima', gender: 'Female', accent: 'English'),
    GeminiVoice(id: 'rasalgethi', name: 'Rasalgethi', gender: 'Male', accent: 'English'),
    GeminiVoice(id: 'sadachbia', name: 'Sadachbia', gender: 'Male', accent: 'English'),
    GeminiVoice(id: 'sadaltager', name: 'Sadaltager', gender: 'Male', accent: 'English'),
    GeminiVoice(id: 'schedar', name: 'Schedar', gender: 'Male', accent: 'English'),
    GeminiVoice(id: 'sulafat', name: 'Sulafat', gender: 'Female', accent: 'English'),
    GeminiVoice(id: 'umbriel', name: 'Umbriel', gender: 'Male', accent: 'English'),
    GeminiVoice(id: 'vindemiatrix', name: 'Vindemiatrix', gender: 'Female', accent: 'English'),
    GeminiVoice(id: 'zubenelgenubi', name: 'Zubenelgenubi', gender: 'Male', accent: 'English'),
  ];

  @override
  void initState() {
    super.initState();
    _initVoices();
    _loadSettings();
    _initOutputFolder();
    _loadApiKeys();
    _initTtsService();

  }
  
  Future<void> _initTtsService() async {
    try {
      await _ttsService.loadApiKeys();
      print('[AI_VOICE] TTS Service initialized with API keys');
    } catch (e) {
      print('[AI_VOICE] Error loading TTS service: $e');
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _paceController.dispose();
    _toneController.dispose();
    _styleController.dispose();
    _instructionController.dispose();

    super.dispose();
  }

  void _initVoices() {
    _voices = List.from(_defaultVoices);
    _selectedVoiceId = _voices.first.id;
  }

  Future<void> _initOutputFolder() async {
    final downloadsDir = Directory('${Platform.environment['USERPROFILE']}\\Downloads\\ai_voice');
    if (!await downloadsDir.exists()) {
      await downloadsDir.create(recursive: true);
    }
    _outputFolder = downloadsDir.path;
    await _loadGeneratedFiles();
  }

  Future<void> _loadGeneratedFiles() async {
    final dir = Directory(_outputFolder);
    if (await dir.exists()) {
      final files = await dir.list().where((f) => f.path.endsWith('.wav') || f.path.endsWith('.mp3')).toList();
      setState(() {
        _generatedFiles = files.map((f) => f.path).toList()..sort((a, b) => b.compareTo(a));
      });
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Get valid voice IDs (from Google's allowed list)
    final validVoiceIds = _voices.map((v) => v.id).toSet();
    
    // Load favorites - only keep valid ones
    final favoritesJson = prefs.getString('ai_voice_favorites');
    if (favoritesJson != null) {
      final favorites = List<String>.from(jsonDecode(favoritesJson));
      // Filter out invalid favorites
      final validFavorites = favorites.where((id) => validVoiceIds.contains(id)).toList();
      for (var voice in _voices) {
        voice.isFavorite = validFavorites.contains(voice.id);
      }
      // Save cleaned favorites back
      if (validFavorites.length != favorites.length) {
        await prefs.setString('ai_voice_favorites', jsonEncode(validFavorites));
      }
      _sortVoices();
    }
    
    // Load settings
    _selectedModel = prefs.getString('ai_voice_model') ?? _selectedModel;
    
    // Load selected voice - validate and clean invalid
    final savedVoice = prefs.getString('ai_voice_selected');
    if (savedVoice != null && validVoiceIds.contains(savedVoice)) {
      _selectedVoiceId = savedVoice;
    } else {
      // Delete invalid saved voice
      if (savedVoice != null) {
        await prefs.remove('ai_voice_selected');
        print('[AI_VOICE] Removed invalid saved voice: $savedVoice');
      }
      // Use first voice
      _selectedVoiceId = _voices.first.id;
    }
    
    _paceController.text = prefs.getString('ai_voice_pace') ?? '1.0';
    _toneController.text = prefs.getString('ai_voice_tone') ?? 'neutral';
    _styleController.text = prefs.getString('ai_voice_style') ?? 'conversational';
    _instructionController.text = prefs.getString('ai_voice_instruction') ?? '';
    
    setState(() {});
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Save favorites
    final favorites = _voices.where((v) => v.isFavorite).map((v) => v.id).toList();
    await prefs.setString('ai_voice_favorites', jsonEncode(favorites));
    
    // Save settings
    await prefs.setString('ai_voice_model', _selectedModel);
    await prefs.setString('ai_voice_selected', _selectedVoiceId ?? '');
    await prefs.setString('ai_voice_pace', _paceController.text);
    await prefs.setString('ai_voice_tone', _toneController.text);
    await prefs.setString('ai_voice_style', _styleController.text);
    await prefs.setString('ai_voice_instruction', _instructionController.text);
  }

  void _sortVoices() {
    _voices.sort((a, b) {
      if (a.isFavorite && !b.isFavorite) return -1;
      if (!a.isFavorite && b.isFavorite) return 1;
      return a.name.compareTo(b.name);
    });
  }

  void _toggleFavorite(String voiceId) {
    setState(() {
      final voice = _voices.firstWhere((v) => v.id == voiceId);
      voice.isFavorite = !voice.isFavorite;
      _sortVoices();
    });
    _saveSettings();
  }

  void _applyPreset(VoicePreset preset) {
    setState(() {
      _paceController.text = preset.pace;
      _toneController.text = preset.tone;
      _styleController.text = preset.style;
      _instructionController.text = preset.instruction;
    });
    _saveSettings();
  }

  String _generateFileName() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = timestamp % 10000;
    return 'voice_${timestamp}_$random.wav';
  }

  Future<void> _loadApiKeys() async {
    // First try widget-provided keys
    if (widget.geminiApiKeys != null && widget.geminiApiKeys!.isNotEmpty) {
      _apiKeysList = widget.geminiApiKeys!;
      return;
    }
    // Otherwise load from GeminiKeyService
    try {
      final keys = await GeminiKeyService.loadKeys();
      if (keys.isNotEmpty) {
        _apiKeysList = keys.where((k) => k.trim().isNotEmpty).toList();
      }
    } catch (e) {
      print('[AI Voice] Error loading API keys: $e');
    }
  }

  List<String> get _apiKeys => _apiKeysList;

  String? _getNextApiKey() {
    if (_apiKeys.isEmpty) return null;
    final key = _apiKeys[_currentApiIndex % _apiKeys.length];
    _currentApiIndex++;
    return key;
  }

  Future<void> _addToQueue() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter text to generate'), backgroundColor: Colors.orange),
      );
      return;
    }

    if (_apiKeys.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No Gemini API keys configured. Go to Settings to add API keys.'), backgroundColor: Colors.red),
      );
      return;
    }

    final selectedVoice = _voices.firstWhere((v) => v.id == _selectedVoiceId, orElse: () => _voices.first);
    
    final task = VoiceTask(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: text,
      voiceId: _selectedVoiceId ?? 'Puck',
      voiceName: selectedVoice.name,
      settings: {
        'model': _selectedModel,
        'pace': _paceController.text,
        'tone': _toneController.text,
        'style': _styleController.text,
        'instruction': _instructionController.text,
      },
    );

    setState(() {
      _tasks.insert(0, task);
      _textController.clear();
    });

    _saveSettings();
    _processQueue();
  }

  Future<void> _processQueue() async {
    if (_isProcessing) return;
    
    final pendingTask = _tasks.where((t) => t.status == 'pending').firstOrNull;
    if (pendingTask == null) return;

    setState(() {
      _isProcessing = true;
      pendingTask.status = 'processing';
    });

    try {
      final success = await _generateVoice(pendingTask);
      
      if (success) {
        setState(() {
          pendingTask.status = 'completed';
        });
        await _loadGeneratedFiles();
      } else if (pendingTask.retryCount < 5) {
        setState(() {
          pendingTask.retryCount++;
          pendingTask.status = 'pending';
        });
      } else {
        setState(() {
          pendingTask.status = 'failed';
          pendingTask.error = 'Failed after 5 retries';
        });
      }
    } catch (e) {
      if (pendingTask.retryCount < 5) {
        setState(() {
          pendingTask.retryCount++;
          pendingTask.status = 'pending';
          pendingTask.error = e.toString();
        });
      } else {
        setState(() {
          pendingTask.status = 'failed';
          pendingTask.error = e.toString();
        });
      }
    }

    setState(() {
      _isProcessing = false;
    });

    // Process next task
    _processQueue();
  }

  Future<bool> _generateVoice(VoiceTask task) async {
    // Ensure TTS service has API keys loaded
    try {
      await _ttsService.loadApiKeys();
    } catch (e) {
      print('[AI_VOICE] Error loading API keys: $e');
      task.error = 'Failed to load API keys: $e';
      return false;
    }
    
    final instruction = task.settings['instruction'] ?? '';
    final pace = task.settings['pace'] ?? '1.0';
    final tone = task.settings['tone'] ?? 'neutral';
    final style = task.settings['style'] ?? 'conversational';
    
    // Build voice style prompt (matching the working format in GeminiTtsService)
    final voiceStyle = '''Speak with the following characteristics:
- Pace: $pace (1.0 is normal speed)
- Tone: $tone
- Style: $style
${instruction.isNotEmpty ? '- Additional instructions: $instruction' : ''}''';

    print('[AI_VOICE] ========== GENERATING VOICE ==========');
    print('[AI_VOICE] Voice: ${task.voiceId}');
    print('[AI_VOICE] Text length: ${task.text.length} chars');
    print('[AI_VOICE] Voice Style: $voiceStyle');

    try {
      // Generate unique filename
      final fileName = 'voice_${DateTime.now().millisecondsSinceEpoch}.wav';
      final filePath = '$_outputFolder\\$fileName';
      
      print('[AI_VOICE] Output path: $filePath');
      
      // Use the working GeminiTtsService
      final success = await _ttsService.generateTts(
        text: task.text,
        voiceModel: task.voiceId,
        voiceStyle: voiceStyle,
        speechRate: double.tryParse(pace) ?? 1.0,
        outputPath: filePath,
      );
      
      if (success) {
        task.outputPath = filePath;
        print('[AI_VOICE] SUCCESS: Voice generated at $filePath');
        return true;
      } else {
        task.error = 'TTS generation failed';
        print('[AI_VOICE] FAILED: TTS generation returned false');
        return false;
      }
    } catch (e, stackTrace) {
      print('[AI_VOICE] EXCEPTION: $e');
      print('[AI_VOICE] Stack trace: $stackTrace');
      task.error = e.toString();
      return false;
    }
  }

  Future<void> _playAudio(String path) async {
    try {
      // Use Windows default player
      await Process.run('cmd', ['/c', 'start', '', path]);
      setState(() => _playingFile = path);
      // Reset after a delay (since we can't track system player state)
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() => _playingFile = null);
        }
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error playing audio: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _openOutputFolder() {
    Process.run('explorer', [_outputFolder]);
  }
  
  void _retryTask(VoiceTask task) {
    setState(() {
      task.status = 'pending';
      task.retryCount = 0;
      task.error = null;
    });
    _processQueue();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF8F9FC),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [Colors.purple.shade500, Colors.blue.shade500]),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.record_voice_over, color: Colors.white, size: 24),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('AI Voice Generator', style: GoogleFonts.inter(fontSize: 20, fontWeight: FontWeight.bold)),
                    Text('Generate natural voices using Gemini TTS', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                  ],
                ),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: _openOutputFolder,
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('Open Folder'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.grey.shade100, foregroundColor: Colors.grey.shade700),
                ),
              ],
            ),
          ),
          // Main Content - 3 columns
          Expanded(
            child: Row(
              children: [
                // LEFT PANEL - Settings
                Container(
                  width: 300,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border(right: BorderSide(color: Colors.grey.shade200)),
                  ),
                  child: _buildSettingsPanel(),
                ),
                // MIDDLE PANEL - Text Input
                Expanded(
                  child: _buildTextInputPanel(),
                ),
                // RIGHT PANEL - Queue & Files (kept intact)
                Container(
                  width: 340,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border(left: BorderSide(color: Colors.grey.shade200)),
                  ),
                  child: _buildRightPanel(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsPanel() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Voice Selection
          Text('Voice', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: _selectedVoiceId,
            isExpanded: true,
            decoration: InputDecoration(
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              filled: true,
              fillColor: Colors.grey.shade50,
            ),
            items: _voices.map((v) => DropdownMenuItem(
              value: v.id,
              child: Row(
                children: [
                  if (v.isFavorite) Icon(Icons.star, size: 14, color: Colors.amber.shade600),
                  if (v.isFavorite) const SizedBox(width: 4),
                  Expanded(child: Text('${v.name} (${v.gender})', style: const TextStyle(fontSize: 13))),
                ],
              ),
            )).toList(),
            onChanged: (v) {
              setState(() => _selectedVoiceId = v);
              _saveSettings();
            },
          ),
          if (_selectedVoiceId != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: InkWell(
                onTap: () => _toggleFavorite(_selectedVoiceId!),
                child: Row(
                  children: [
                    Icon(
                      _voices.firstWhere((v) => v.id == _selectedVoiceId).isFavorite ? Icons.star : Icons.star_border,
                      size: 16,
                      color: Colors.amber.shade600,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _voices.firstWhere((v) => v.id == _selectedVoiceId).isFavorite ? 'Favorited' : 'Add to Favorites',
                      style: TextStyle(fontSize: 11, color: Colors.amber.shade700),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          
          // Model Selection
          Text('Model', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: _selectedModel,
            isExpanded: true,
            decoration: InputDecoration(
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              filled: true,
              fillColor: Colors.grey.shade50,
            ),
            items: _models.map((m) => DropdownMenuItem(value: m, child: Text(m, style: const TextStyle(fontSize: 11)))).toList(),
            onChanged: (v) {
              setState(() => _selectedModel = v!);
              _saveSettings();
            },
          ),
          const SizedBox(height: 20),
          
          // Presets
          Row(
            children: [
              Text('Presets', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _presets.map((p) => InkWell(
              onTap: () => _applyPreset(p),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.purple.shade50,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.purple.shade200),
                ),
                child: Text(p.name, style: TextStyle(fontSize: 11, color: Colors.purple.shade700, fontWeight: FontWeight.w500)),
              ),
            )).toList(),
          ),
          const SizedBox(height: 20),
          
          // Voice Settings
          Text('Voice Settings', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
          const SizedBox(height: 12),
          _buildCompactSettingField('Pace', _paceController, '1.0'),
          const SizedBox(height: 10),
          _buildCompactSettingField('Tone', _toneController, 'neutral'),
          const SizedBox(height: 10),
          _buildCompactSettingField('Style', _styleController, 'conversational'),
          const SizedBox(height: 10),
          _buildCompactSettingField('Instruction', _instructionController, 'Custom...'),
        ],
      ),
    );
  }
  
  Widget _buildCompactSettingField(String label, TextEditingController controller, String hint) {
    return Row(
      children: [
        SizedBox(
          width: 70,
          child: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        ),
        Expanded(
          child: TextField(
            controller: controller,
            onChanged: (_) => _saveSettings(),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(fontSize: 12, color: Colors.grey.shade400),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              isDense: true,
              filled: true,
              fillColor: Colors.grey.shade50,
            ),
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildTextInputPanel() {
    return Container(
      color: const Color(0xFFF8F9FC),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Text Input Header
            Row(
              children: [
                Text('Text to Generate', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_textController.text.length} characters',
                    style: TextStyle(color: Colors.blue.shade700, fontSize: 11, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Text Input
            Expanded(
              child: TextField(
                controller: _textController,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Enter or paste your text here...',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  filled: true,
                  fillColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Generate Button
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _addToQueue,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Generate Voice'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.purple.shade600,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton(
                  onPressed: () async {
                    final data = await Clipboard.getData('text/plain');
                    if (data?.text != null) {
                      _textController.text = data!.text!;
                      setState(() {});
                    }
                  },
                  icon: const Icon(Icons.paste),
                  tooltip: 'Paste from clipboard',
                  style: IconButton.styleFrom(backgroundColor: Colors.grey.shade200),
                ),
                const SizedBox(width: 6),
                IconButton(
                  onPressed: () {
                    _textController.clear();
                    setState(() {});
                  },
                  icon: const Icon(Icons.clear),
                  tooltip: 'Clear text',
                  style: IconButton.styleFrom(backgroundColor: Colors.grey.shade200),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingField(String label, TextEditingController controller, String hint) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          onChanged: (_) => _saveSettings(),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(fontSize: 12, color: Colors.grey.shade400),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            isDense: true,
          ),
          style: const TextStyle(fontSize: 13),
        ),
      ],
    );
  }

  Widget _buildRightPanel() {
    return Column(
      children: [
        // Queue Header
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
          ),
          child: Row(
            children: [
              const Icon(Icons.queue_music, size: 20),
              const SizedBox(width: 8),
              Text('Processing Queue', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: _isProcessing ? Colors.orange.shade100 : Colors.green.shade100,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _isProcessing ? 'Processing' : 'Idle',
                  style: TextStyle(fontSize: 11, color: _isProcessing ? Colors.orange.shade800 : Colors.green.shade800),
                ),
              ),
            ],
          ),
        ),
        // Queue List
        Expanded(
          flex: 2,
          child: _tasks.isEmpty
              ? Center(child: Text('No tasks in queue', style: TextStyle(color: Colors.grey.shade400)))
              : ListView.builder(
                  itemCount: _tasks.length,
                  itemBuilder: (context, index) => _buildTaskItem(_tasks[index]),
                ),
        ),
        // Generated Files Header
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            border: Border(top: BorderSide(color: Colors.grey.shade200), bottom: BorderSide(color: Colors.grey.shade200)),
          ),
          child: Row(
            children: [
              const Icon(Icons.audio_file, size: 20),
              const SizedBox(width: 8),
              Text('Generated Files', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('${_generatedFiles.length}', style: TextStyle(color: Colors.grey.shade600)),
            ],
          ),
        ),
        // Files List
        Expanded(
          flex: 3,
          child: _generatedFiles.isEmpty
              ? Center(child: Text('No files generated yet', style: TextStyle(color: Colors.grey.shade400)))
              : ListView.builder(
                  itemCount: _generatedFiles.length,
                  itemBuilder: (context, index) => _buildFileItem(_generatedFiles[index]),
                ),
        ),
      ],
    );
  }

  Widget _buildTaskItem(VoiceTask task) {
    Color statusColor;
    IconData statusIcon;
    
    switch (task.status) {
      case 'processing':
        statusColor = Colors.orange;
        statusIcon = Icons.sync;
        break;
      case 'completed':
        statusColor = Colors.green;
        statusIcon = Icons.check_circle;
        break;
      case 'failed':
        statusColor = Colors.red;
        statusIcon = Icons.error;
        break;
      default:
        statusColor = Colors.grey;
        statusIcon = Icons.schedule;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey.shade100)),
      ),
      child: Row(
        children: [
          Icon(statusIcon, size: 18, color: statusColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.text.length > 40 ? '${task.text.substring(0, 40)}...' : task.text,
                  style: const TextStyle(fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${task.voiceName} • ${task.status}${task.retryCount > 0 ? ' (retry ${task.retryCount})' : ''}',
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                ),
              ],
            ),
          ),
          if (task.status == 'failed')
            IconButton(
              icon: Icon(Icons.refresh, size: 18, color: Colors.orange.shade600),
              tooltip: 'Retry',
              onPressed: () => _retryTask(task),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          if (task.status == 'completed' && task.outputPath != null)
            IconButton(
              icon: Icon(
                _playingFile == task.outputPath ? Icons.stop : Icons.play_arrow,
                size: 18,
                color: Colors.purple,
              ),
              onPressed: () => _playAudio(task.outputPath!),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
        ],
      ),
    );
  }

  Widget _buildFileItem(String path) {
    final fileName = path.split('\\').last;
    final isPlaying = _playingFile == path;
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isPlaying ? Colors.purple.shade50 : Colors.transparent,
        border: Border(bottom: BorderSide(color: Colors.grey.shade100)),
      ),
      child: Row(
        children: [
          Icon(Icons.audio_file, size: 18, color: Colors.purple.shade400),
          const SizedBox(width: 10),
          Expanded(
            child: Text(fileName, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
          ),
          IconButton(
            icon: Icon(isPlaying ? Icons.stop : Icons.play_arrow, size: 18, color: Colors.purple),
            onPressed: () => _playAudio(path),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            tooltip: 'Play',
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: Icon(Icons.delete_outline, size: 18, color: Colors.red.shade400),
            onPressed: () => _deleteFile(path),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            tooltip: 'Delete',
          ),
        ],
      ),
    );
  }
  
  Future<void> _deleteFile(String path) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Audio?'),
        content: Text('Delete "${path.split('\\').last}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: TextStyle(color: Colors.red.shade600)),
          ),
        ],
      ),
    );
    
    if (confirm == true) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
        setState(() {
          _generatedFiles.remove(path);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File deleted'), duration: Duration(seconds: 1)),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }
}
