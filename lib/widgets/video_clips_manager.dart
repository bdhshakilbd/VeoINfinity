import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:open_filex/open_filex.dart';
import '../utils/video_export_helper.dart';

class VideoClipsManager extends StatefulWidget {
  final List<PlatformFile> initialFiles;
  final Function(List<PlatformFile> files) onExport;
  final String? exportFolder;
  final bool embedded;

  const VideoClipsManager({
    Key? key,
    required this.initialFiles,
    required this.onExport,
    this.exportFolder,
    this.embedded = false,
  }) : super(key: key);

  @override
  State<VideoClipsManager> createState() => _VideoClipsManagerState();
}

class _VideoClipsManagerState extends State<VideoClipsManager> {
  late List<PlatformFile> _files;

  @override
  void initState() {
    super.initState();
    _files = List.from(widget.initialFiles);
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp4', 'avi', 'mkv', 'mov', 'webm'],
      allowMultiple: true,
      dialogTitle: 'Add More Videos',
    );

    if (result != null && result.files.isNotEmpty) {
      setState(() {
        _files.addAll(result.files);
      });
    }
  }

  Future<void> _pickFolder() async {
    final String? selectedDirectory = await FilePicker.platform.getDirectoryPath(
       dialogTitle: 'Select Folder with Videos'
    );
    
    if (selectedDirectory != null) {
      final dir = Directory(selectedDirectory);
      try {
        final List<FileSystemEntity> entities = await dir.list().toList();
        final List<PlatformFile> newFiles = [];
        
        for (final entity in entities) {
           if (entity is File) {
              final ext = path.extension(entity.path).toLowerCase().replaceAll('.', '');
              if (['mp4', 'avi', 'mkv', 'mov', 'webm'].contains(ext)) {
                 final len = await entity.length();
                 newFiles.add(PlatformFile(
                    name: path.basename(entity.path),
                    path: entity.path,
                    size: len,
                 ));
              }
           }
        }
        
        if (newFiles.isNotEmpty) {
           // Sort naturally
           newFiles.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
           
           setState(() {
             _files.addAll(newFiles);
           });
           
           ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added ${newFiles.length} videos')));
        } else {
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No videos found in folder')));
        }
      } catch (e) {
         print('Error reading folder: $e');
         ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error reading folder: $e')));
      }
    }
  }

  void _addMoreClips() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.video_library),
              title: const Text('Pick Video Files'),
              onTap: () { Navigator.pop(ctx); _pickFiles(); },
            ),
            ListTile(
              leading: const Icon(Icons.folder),
              title: const Text('Pick Entire Folder'),
              subtitle: const Text('Add all videos from a folder'),
              onTap: () { Navigator.pop(ctx); _pickFolder(); },
            ),
          ],
        ),
      ),
    );
  }

  void _removeClip(int index) {
    setState(() {
      _files.removeAt(index);
    });
  }

  void _moveClip(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) {
        newIndex -= 1;
      }
      final item = _files.removeAt(oldIndex);
      _files.insert(newIndex, item);
    });
  }

  void _moveUp(int index) {
    if (index > 0) {
      setState(() {
        final item = _files.removeAt(index);
        _files.insert(index - 1, item);
      });
    }
  }

  void _moveDown(int index) {
    if (index < _files.length - 1) {
      setState(() {
        final item = _files.removeAt(index);
        _files.insert(index + 1, item);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 600;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: const Color(0xFFF8F9FC),
        appBar: AppBar(
          automaticallyImplyLeading: !widget.embedded,
          title: Text('Video Project (${_files.length})'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Join Clips', icon: Icon(Icons.movie_creation)),
              Tab(text: 'Exported Videos', icon: Icon(Icons.video_library)),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'Add Clips',
              onPressed: _addMoreClips,
            ),
          ],
        ),
        body: Column(
          children: [
            // Status banner is persistent across tabs for visibility
            _buildExportStatusBanner(),
            Expanded(
              child: TabBarView(
                children: [
                   // Tab 1: Clip Editor
                   isMobile ? _buildMobileLayout() : _buildDesktopLayout(),
                   
                   // Tab 2: Exported Videos Browser
                   _buildExportedVideosTab(),
                ],
              ),
            ),
          ],
        ),
        // FAB for mobile export (Only on Join Clips tab logic? 
        // We can show it always but it acts on _files. 
        // Better to hide if on Exported tab? Hard to detect tab index in DefaultTabController easily without listener.
        // We'll leave it or wrap it. For now, show it.)
        floatingActionButton: isMobile && _files.length >= 2
            ? FloatingActionButton.extended(
                onPressed: () => widget.onExport(_files),
                icon: const Icon(Icons.video_settings),
                label: const Text('Export'),
                backgroundColor: Colors.green,
              )
            : null,
      ),
    );
  }

  Widget _buildExportedVideosTab() {
    if (widget.exportFolder == null) {
      return const Center(child: Text('No export folder configured.'));
    }
    
    final dir = Directory(widget.exportFolder!);
    if (!dir.existsSync()) {
       return Center(child: Text('Export folder does not exist:\n${widget.exportFolder}'));
    }
    
    // List files
    // Use FutureBuilder to list
    return FutureBuilder<List<FileSystemEntity>>(
       future: dir.list().toList(),
       builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          
          final entities = snapshot.data!;
          final videos = entities.where((e) {
             if (e is! File) return false;
             final ext = path.extension(e.path).toLowerCase();
             return ['.mp4', '.mov', '.avi', '.mkv'].contains(ext);
          }).toList();
          
          // Sort by modified date desc
          videos.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
          
          if (videos.isEmpty) {
             return const Center(child: Text('No exported videos found.'));
          }
          
          return ListView.builder(
             padding: const EdgeInsets.all(16),
             itemCount: videos.length,
             itemBuilder: (context, index) {
                final file = videos[index] as File;
                final stat = file.statSync();
                final name = path.basename(file.path);
                
                return Card(
                   margin: const EdgeInsets.only(bottom: 8),
                   child: ListTile(
                      leading: const Icon(Icons.video_file, color: Colors.blue, size: 40),
                      title: Text(name),
                      subtitle: Text('${stat.modified.toString().split('.')[0]} • ${_formatFileSize(stat.size)}'),
                      trailing: const Icon(Icons.play_circle_fill, color: Colors.green),
                      onTap: () {
                         OpenFilex.open(file.path);
                      },
                   ),
                );
             },
          );
       },
    );
  }

  Widget _buildMobileLayout() {
    return Column(
      children: [
        // Summary bar at top
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Colors.blue.shade50,
          child: Row(
            children: [
              Icon(Icons.video_library, color: Colors.blue.shade700, size: 20),
              const SizedBox(width: 8),
              Text(
                '${_files.length} clips',
                style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue.shade700),
              ),
              const SizedBox(width: 16),
              Text(
                _formatFileSize(_files.fold<int>(0, (sum, f) => sum + f.size)),
                style: TextStyle(color: Colors.blue.shade600, fontSize: 13),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _addMoreClips,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                ),
              ),
            ],
          ),
        ),
        // Video list
        Expanded(
          child: _files.isEmpty
              ? _buildEmptyState()
              : ReorderableListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _files.length,
                  onReorder: _moveClip,
                  buildDefaultDragHandles: false,
                  itemBuilder: (context, index) {
                    final file = _files[index];
                    return _buildMobileClipCard(file, index);
                  },
                ),
        ),
        // Bottom message for mobile
        if (_files.length < 2 && _files.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.orange.shade50,
            child: Row(
              children: [
                Icon(Icons.info, color: Colors.orange.shade700, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Add at least 2 videos to export',
                  style: TextStyle(color: Colors.orange.shade800, fontSize: 13),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildMobileClipCard(PlatformFile file, int index) {
    return Card(
      key: ValueKey(file.path ?? file.name),
      margin: const EdgeInsets.only(bottom: 8),
      child: ReorderableDragStartListener(
        index: index,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              // Drag handle + number
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: Colors.blue,
                  borderRadius: BorderRadius.circular(4),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // File info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatFileSize(file.size),
                      style: TextStyle(color: Colors.grey[600], fontSize: 11),
                    ),
                  ],
                ),
              ),
              // Actions
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (index > 0)
                    IconButton(
                      icon: const Icon(Icons.arrow_upward, size: 18),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      onPressed: () => _moveUp(index),
                    ),
                  if (index < _files.length - 1)
                    IconButton(
                      icon: const Icon(Icons.arrow_downward, size: 18),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      onPressed: () => _moveDown(index),
                    ),
                  IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red, size: 18),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    onPressed: () => _removeClip(index),
                  ),
                  const Icon(Icons.drag_handle, color: Colors.grey, size: 20),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopLayout() {
    return Row(
      children: [
        // Video list
        Expanded(
          child: _files.isEmpty
              ? _buildEmptyState()
              : ReorderableListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _files.length,
                  onReorder: _moveClip,
                  buildDefaultDragHandles: false,
                  itemBuilder: (context, index) {
                    final file = _files[index];
                    return Card(
                      key: ValueKey(file.path ?? file.name),
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ReorderableDragStartListener(
                        index: index,
                        child: ListTile(
                          leading: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.drag_handle, color: Colors.grey),
                              const SizedBox(width: 8),
                              Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: Colors.blue,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  '${index + 1}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              const Icon(Icons.video_file, size: 40, color: Colors.blue),
                            ],
                          ),
                          title: Text(
                            file.name,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                          subtitle: Text(
                            _formatFileSize(file.size),
                            style: TextStyle(color: Colors.grey[600]),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (index > 0)
                                IconButton(
                                  icon: const Icon(Icons.arrow_upward, size: 20),
                                  tooltip: 'Move Up',
                                  onPressed: () => _moveUp(index),
                                ),
                              if (index < _files.length - 1)
                                IconButton(
                                  icon: const Icon(Icons.arrow_downward, size: 20),
                                  tooltip: 'Move Down',
                                  onPressed: () => _moveDown(index),
                                ),
                              IconButton(
                                icon: const Icon(Icons.delete, color: Colors.red),
                                tooltip: 'Remove',
                                onPressed: () => _removeClip(index),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        // Export panel (desktop only)
        Container(
          width: 280,
          decoration: BoxDecoration(
            color: Colors.grey[100],
            border: Border(
              left: BorderSide(color: Colors.grey[300]!),
            ),
          ),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blue,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: const Row(
                  children: [
                    Icon(Icons.settings, color: Colors.white),
                    SizedBox(width: 8),
                    Text(
                      'Export Settings',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Summary',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text('Total Clips: ${_files.length}'),
                              Text('Total Size: ${_formatFileSize(_files.fold<int>(0, (sum, f) => sum + f.size))}'),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: _files.length >= 2
                            ? () => widget.onExport(_files)
                            : null,
                        icon: const Icon(Icons.video_settings),
                        label: const Text('Configure & Export'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (_files.length < 2)
                        const Text(
                          'Add at least 2 videos to export',
                          style: TextStyle(
                            color: Colors.red,
                            fontSize: 12,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      const SizedBox(height: 16),
                      const Text(
                        'Quick Actions',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _addMoreClips,
                        icon: const Icon(Icons.add),
                        label: const Text('Add More Clips'),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _files.isEmpty
                            ? null
                            : () {
                                setState(() {
                                  _files.clear();
                                });
                              },
                        icon: const Icon(Icons.clear_all),
                        label: const Text('Clear All'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.video_settings, size: 80, color: Colors.blueGrey),
          const SizedBox(height: 24),
          const Text(
            'Join Video Clips',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Select videos or a folder to get started',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
               ElevatedButton.icon(
                onPressed: _pickFiles,
                icon: const Icon(Icons.video_library),
                label: const Text('Select Videos'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                ),
              ),
              const SizedBox(width: 16),
              ElevatedButton.icon(
                onPressed: _pickFolder,
                icon: const Icon(Icons.folder_open),
                label: const Text('Select Folder'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.blue,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Widget _buildExportStatusBanner() {
    return ValueListenableBuilder<bool>(
      valueListenable: ExportStatus.isExporting,
      builder: (context, isExporting, child) {
         if (!isExporting) return const SizedBox.shrink();
         return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
               color: Colors.blue.shade50,
               border: Border(bottom: BorderSide(color: Colors.blue.shade200))
            ),
            child: Row(
               children: [
                  const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Export in progress...', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.blue)),
                        const SizedBox(height: 2),
                        ValueListenableBuilder<String>(
                           valueListenable: ExportStatus.message,
                           builder: (ctx, msg, _) => Text(msg, 
                             style: TextStyle(fontSize: 12, color: Colors.blue.shade800),
                             overflow: TextOverflow.ellipsis
                           ),
                        ),
                      ],
                    )
                  ),
                  if (ExportStatus.progress.value != null)
                     ValueListenableBuilder<double?>(
                       valueListenable: ExportStatus.progress,
                       builder: (ctx, val, _) => Text(
                         val != null ? '${(val * 100).toInt()}%' : '',
                         style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue),
                       ),
                     ),
                  
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.blueGrey, size: 20),
                    tooltip: 'Cancel Export',
                    onPressed: () {
                        showDialog(
                          context: context, 
                          builder: (c) => AlertDialog(
                           title: const Text('Cancel Export?'),
                           content: const Text('This will stop the current background process.'),
                           actions: [
                              TextButton(onPressed:()=>Navigator.pop(c), child: const Text('Keep Exporting')),
                              TextButton(
                                onPressed:(){
                                 Navigator.pop(c);
                                 ExportStatus.cancel();
                                }, 
                                style: TextButton.styleFrom(foregroundColor: Colors.red),
                                child: const Text('Stop Export')
                              ),
                           ]
                        ));
                    },
                  ),
               ],
            ),
         );
      }
    );
  }
}
