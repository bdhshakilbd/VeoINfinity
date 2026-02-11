import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/log_service.dart';

/// A floating, draggable log viewer window for displaying application logs
class LogViewerWidget extends StatefulWidget {
  const LogViewerWidget({Key? key}) : super(key: key);

  @override
  State<LogViewerWidget> createState() => _LogViewerWidgetState();
}

class _LogViewerWidgetState extends State<LogViewerWidget> {
  final LogService _logService = LogService();
  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;
  String _filterText = '';
  bool _isExpanded = true;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_autoScroll && _scrollController.hasClients) {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }
  }

  Color _getLogColor(String type) {
    switch (type.toUpperCase()) {
      case 'ERROR':
        return Colors.red.shade300;
      case 'NET':
      case 'NETWORK':
        return Colors.blue.shade300;
      case 'MOBILE':
        return Colors.purple.shade300;
      case 'NORMAL':
      case 'NORMAL MODE':
        return Colors.green.shade300;
      case 'GEN':
      case 'PRODUCER':
      case 'POLLER':
        return Colors.orange.shade300;
      case 'VGEN':
      case 'GENERATE':
        return Colors.cyan.shade300;
      case 'PROFILE':
        return Colors.amber.shade300;
      case 'SUCCESS':
        return Colors.greenAccent.shade200;
      default:
        return Colors.grey.shade400;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 600,
        height: _isExpanded ? 400 : 40,
        decoration: BoxDecoration(
          color: Colors.grey.shade900,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.shade700, width: 1),
        ),
        child: Column(
          children: [
            // Header
            Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.grey.shade800,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
              ),
              child: Row(
                children: [
                  Icon(Icons.terminal, size: 16, color: Colors.green.shade400),
                  const SizedBox(width: 8),
                  Text(
                    'Application Logs',
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const Spacer(),
                  // Auto-scroll toggle
                  Tooltip(
                    message: 'Auto-scroll to bottom',
                    child: InkWell(
                      onTap: () => setState(() => _autoScroll = !_autoScroll),
                      child: Icon(
                        _autoScroll ? Icons.arrow_downward : Icons.pause,
                        size: 16,
                        color: _autoScroll ? Colors.green.shade400 : Colors.grey.shade400,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Clear logs
                  Tooltip(
                    message: 'Clear logs',
                    child: InkWell(
                      onTap: () => _logService.clear(),
                      child: Icon(Icons.delete_outline, size: 16, color: Colors.red.shade400),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Copy all logs
                  Tooltip(
                    message: 'Copy all logs',
                    child: InkWell(
                      onTap: () {
                        final allLogs = _logService.logs.map((e) => e.toString()).join('\n');
                        Clipboard.setData(ClipboardData(text: allLogs));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Logs copied to clipboard'), duration: Duration(seconds: 1)),
                        );
                      },
                      child: Icon(Icons.copy, size: 16, color: Colors.blue.shade400),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Collapse/Expand
                  InkWell(
                    onTap: () => setState(() => _isExpanded = !_isExpanded),
                    child: Icon(
                      _isExpanded ? Icons.expand_more : Icons.expand_less,
                      size: 18,
                      color: Colors.grey.shade400,
                    ),
                  ),
                ],
              ),
            ),
            
            if (_isExpanded) ...[
              // Log content
              Expanded(
                child: StreamBuilder<List<LogEntry>>(
                  stream: _logService.stream,
                  initialData: _logService.logs,
                  builder: (context, snapshot) {
                    final logs = snapshot.data ?? [];
                    
                    // Auto-scroll when new logs arrive
                    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
                    
                    // Filter logs if needed
                    final filteredLogs = _filterText.isEmpty
                        ? logs
                        : logs.where((log) => log.message.toLowerCase().contains(_filterText.toLowerCase())).toList();
                    
                    if (filteredLogs.isEmpty) {
                      return Center(
                        child: Text(
                          'No logs yet...',
                          style: GoogleFonts.jetBrainsMono(color: Colors.grey.shade600),
                        ),
                      );
                    }
                    
                    return ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(8),
                      itemCount: filteredLogs.length,
                      itemBuilder: (context, index) {
                        final log = filteredLogs[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: SelectableText.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '[${log.type}] ',
                                  style: GoogleFonts.jetBrainsMono(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: _getLogColor(log.type),
                                  ),
                                ),
                                TextSpan(
                                  text: log.message,
                                  style: GoogleFonts.jetBrainsMono(
                                    fontSize: 11,
                                    color: Colors.grey.shade300,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
