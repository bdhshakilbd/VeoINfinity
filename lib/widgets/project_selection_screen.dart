import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as path;
import '../services/project_service.dart';
import '../services/permission_service.dart';

/// Screen for selecting or creating a project
class ProjectSelectionScreen extends StatefulWidget {
  final Function(Project) onProjectSelected;
  final bool isActivated;
  final bool isCheckingLicense;
  final String licenseError;
  final String deviceId;
  final VoidCallback onRetryLicense;
  
  const ProjectSelectionScreen({
    super.key,
    required this.onProjectSelected,
    required this.isActivated,
    required this.isCheckingLicense,
    required this.licenseError,
    required this.deviceId,
    required this.onRetryLicense,
  });

  @override
  State<ProjectSelectionScreen> createState() => _ProjectSelectionScreenState();
}

class _ProjectSelectionScreenState extends State<ProjectSelectionScreen> {
  List<Project> _projects = [];
  bool _isLoading = true;
  String _projectsBasePath = '';

  @override
  void initState() {
    super.initState();
    _loadProjects();
  }

  Future<void> _loadProjects() async {
    setState(() => _isLoading = true);
    try {
      await ProjectService.ensureDirectories();
      final projects = await ProjectService.listProjects();
      final basePath = await ProjectService.projectsBasePath;
      setState(() {
        _projects = projects;
        _projectsBasePath = basePath;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading projects: $e')),
        );
      }
    }
  }

  Future<void> _createNewProject() async {
    final nameController = TextEditingController();
    
    // Get default export path asynchronously
    final defaultExport = await ProjectService.defaultExportPath;
    final projectsPath = await ProjectService.projectsBasePath;
    final exportPathController = TextEditingController(text: defaultExport);
    
    // Detect if mobile
    final isMobile = MediaQuery.of(context).size.width < 600;

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.create_new_folder, color: Colors.blue),
            SizedBox(width: 8),
            Flexible(child: Text('Create New Project')),
          ],
        ),
        content: SizedBox(
          width: isMobile ? double.maxFinite : 450,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: !isMobile,
                  decoration: const InputDecoration(
                    labelText: 'Project Name',
                    hintText: 'Enter a name for your project',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.folder),
                  ),
                ),
                if (!isMobile) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: exportPathController,
                    decoration: const InputDecoration(
                      labelText: 'Export Folder (videos will be saved here)',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.video_library),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  isMobile
                      ? 'Videos will be saved to app storage'
                      : 'Project data will be saved to:\n$projectsPath\\<project_name>',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              if (nameController.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter a project name')),
                );
                return;
              }
              Navigator.pop(context, {
                'name': nameController.text.trim(),
                'exportPath': isMobile ? '' : exportPathController.text.trim(),
              });
            },
            icon: const Icon(Icons.add),
            label: const Text('Create'),
          ),
        ],
      ),
    );

    if (result != null) {
      try {
        final service = ProjectService();
        final project = await service.createProject(
          result['name']!,
          customExportPath: result['exportPath']!.isEmpty ? null : result['exportPath'],
        );
        await service.loadProject(project);
        widget.onProjectSelected(project);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error creating project: $e')),
          );
        }
      }
    }
  }

  Future<void> _selectProject(Project project) async {
    try {
      final service = ProjectService();
      await service.loadProject(project);
      widget.onProjectSelected(project);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading project: $e')),
        );
      }
    }
  }

  void _showProjectsPathInfo() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.folder_special, color: Colors.blue),
            SizedBox(width: 8),
            Text('Projects Location'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Projects are stored at:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: SelectableText(
                _projectsBasePath,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Each project has its own subfolder containing prompts, settings, and other data.',
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade700,
              ),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _projectsBasePath));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Path copied to clipboard')),
              );
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy Path'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final isMobile = screenWidth < 600;
    
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.blue.shade800,
              Colors.purple.shade600,
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Top Header Bar
              _buildTopHeader(isMobile),
              
              // Main Content - Full Screen
              Expanded(
                child: Container(
                  margin: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8F9FC),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      // License Status Banner (if needed)
                      if (!widget.isActivated && !widget.isCheckingLicense)
                        _buildLicenseBanner(isMobile),
                      
                      // Checking License Indicator
                      if (widget.isCheckingLicense)
                        _buildCheckingLicenseIndicator(),
                      
                      // Projects Grid
                      Expanded(
                        child: _isLoading
                            ? const Center(child: CircularProgressIndicator())
                            : _projects.isEmpty
                                ? _buildEmptyState()
                                : _buildProjectsGrid(isMobile),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLicenseBanner(bool isMobile) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 12 : 16,
        vertical: 12,
      ),
      decoration: BoxDecoration(
        color: widget.licenseError.isNotEmpty 
            ? Colors.orange.shade100 
            : Colors.red.shade100,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                widget.licenseError.isNotEmpty ? Icons.wifi_off : Icons.lock,
                color: widget.licenseError.isNotEmpty ? Colors.orange : Colors.red,
                size: isMobile ? 20 : 24,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.licenseError.isNotEmpty 
                      ? 'Network Error' 
                      : 'License Required',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: isMobile ? 13 : 14,
                    color: widget.licenseError.isNotEmpty 
                        ? Colors.orange.shade800 
                        : Colors.red.shade800,
                  ),
                ),
              ),
            ],
          ),
          if (!widget.licenseError.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Device ID: ${widget.deviceId}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade700,
                      fontFamily: 'monospace',
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: 'Copy Device ID',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: widget.deviceId));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Device ID copied to clipboard'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
          if (widget.licenseError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                widget.licenseError,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade700,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: widget.onRetryLicense,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCheckingLicenseIndicator() {
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.blue.shade600,
            Colors.purple.shade500,
            Colors.pink.shade400,
          ],
        ),
        borderRadius: widget.isActivated 
            ? BorderRadius.zero 
            : const BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // VEO3 Infinity Logo/Icon
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withOpacity(0.2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 20,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: const Icon(
              Icons.video_library_rounded,
              size: 56,
              color: Colors.white,
            ),
          ),
          
          const SizedBox(height: 24),
          
          // VEO3 Infinity Title
          const Text(
            'VEO3 Infinity',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              letterSpacing: 1.2,
              shadows: [
                Shadow(
                  color: Colors.black26,
                  offset: Offset(0, 2),
                  blurRadius: 4,
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 8),
          
          // Slogan
          const Text(
            'Unlimited AI Video Generation',
            style: TextStyle(
              fontSize: 16,
              color: Colors.white,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'No bounds',
            style: TextStyle(
              fontSize: 14,
              color: Colors.white70,
              fontStyle: FontStyle.italic,
              letterSpacing: 0.8,
            ),
          ),
          
          const SizedBox(height: 32),
          
          // Loading Bar Container
          Container(
            width: 280,
            height: 6,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(3),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: const LinearProgressIndicator(
                backgroundColor: Colors.transparent,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
          ),
          
          const SizedBox(height: 16),
          
          // Loading Text
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white.withOpacity(0.8)),
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                'Verifying license...',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(bool isMobile) {
    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: (!widget.isActivated || widget.isCheckingLicense)
            ? BorderRadius.zero
            : const BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: isMobile ? _buildMobileHeader() : _buildDesktopHeader(),
    );
  }

  Widget _buildMobileHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.video_library, size: 32, color: Colors.blue.shade700),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'VEO3 Infinity',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (widget.isActivated) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFFFFD700), Color(0xFFFFA500)],
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.star, size: 10, color: Colors.white),
                              SizedBox(width: 2),
                              Text(
                                'PRO',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _createNewProject,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New Project'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDesktopHeader() {
    return Row(
      children: [
        Icon(Icons.video_library, size: 48, color: Colors.blue.shade700),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    'VEO3 Infinity',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (widget.isActivated)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFFFD700), Color(0xFFFFA500)],
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.star, size: 12, color: Colors.white),
                          SizedBox(width: 4),
                          Text(
                            'PREMIUM',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              Text(
                widget.isActivated 
                    ? 'Select a project to continue or create a new one'
                    : 'Create a project to explore features',
                style: const TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
        ElevatedButton.icon(
          onPressed: _createNewProject,
          icon: const Icon(Icons.add),
          label: const Text('New Project'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(48),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.blue.shade400,
                    Colors.purple.shade400,
                  ],
                ),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.folder_open,
                size: 80,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 32),
            const Text(
              'No projects yet',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1E293B),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Click "New Project" to get started with\nyour first AI video generation project',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _createNewProject,
              icon: const Icon(Icons.add, size: 24),
              label: const Text(
                'Create Your First Project',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade600,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProjectsList(bool isMobile) {
    return ListView.builder(
      padding: EdgeInsets.all(isMobile ? 8 : 16),
      itemCount: _projects.length,
      itemBuilder: (context, index) {
        final project = _projects[index];
        return _buildProjectCard(project, isMobile);
      },
    );
  }
  
  Widget _buildTopHeader(bool isMobile) {
    return Container(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          // Logo and Title
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.video_library_rounded,
              color: Colors.white,
              size: 32,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'VEO3 Infinity',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (widget.isActivated)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFFFFD700), Color(0xFFFFA500)],
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.star, size: 14, color: Colors.white),
                            SizedBox(width: 4),
                            Text(
                              'PREMIUM',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Your Projects',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
          // New Project Button
          ElevatedButton.icon(
            onPressed: _createNewProject,
            icon: const Icon(Icons.add, size: 20),
            label: const Text('New Project'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.blue.shade700,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              elevation: 2,
            ),
          ),
          const SizedBox(width: 12),
          // Info Button
          IconButton(
            onPressed: _showProjectsPathInfo,
            icon: const Icon(Icons.info_outline, color: Colors.white),
            tooltip: 'View Storage Location',
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withOpacity(0.2),
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildProjectsGrid(bool isMobile) {
    final crossAxisCount = isMobile ? 1 : (MediaQuery.of(context).size.width > 1200 ? 4 : 3);
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section Header
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Row(
            children: [
              const Text(
                'Recent Projects',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1E293B),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.blue.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${_projects.length} project${_projects.length != 1 ? 's' : ''}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.blue.shade700,
                  ),
                ),
              ),
            ],
          ),
        ),
        
        // Projects Grid
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
              childAspectRatio: 1.1,
            ),
            itemCount: _projects.length,
            itemBuilder: (context, index) {
              return _buildProjectGridCard(_projects[index]);
            },
          ),
        ),
      ],
    );
  }
  
  Widget _buildProjectGridCard(Project project) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _getProjectStats(project),
      builder: (context, snapshot) {
        final stats = snapshot.data ?? {'prompts': 0, 'videos': 0, 'images': 0, 'thumbnail': null};
        
        return Card(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: InkWell(
            onTap: () => _selectProject(project),
            borderRadius: BorderRadius.circular(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Thumbnail
                Expanded(
                  flex: 3,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          const Color(0xFF818CF8),
                          const Color(0xFFC084FC),
                        ],
                      ),
                    ),
                    child: stats['thumbnail'] != null
                        ? ClipRRect(
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                            child: Image.file(
                              File(stats['thumbnail']),
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) {
                                return _buildDefaultThumbnail();
                              },
                            ),
                          )
                        : _buildDefaultThumbnail(),
                  ),
                ),
                
                // Project Info
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Project Name
                        Text(
                          project.name,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1E293B),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        
                        // Date
                        Text(
                          _formatDate(project.lastModified ?? project.createdAt),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF64748B),
                          ),
                        ),
                        
                        const Spacer(),
                        
                        // Stats Row
                        Row(
                          children: [
                            _buildStatChip(Icons.description, stats['prompts'].toString(), Colors.blue),
                            const SizedBox(width: 8),
                            _buildStatChip(Icons.video_library, stats['videos'].toString(), Colors.purple),
                            const SizedBox(width: 8),
                            _buildStatChip(Icons.image, stats['images'].toString(), Colors.pink),
                            const Spacer(),
                            // Delete button
                            InkWell(
                              onTap: () => _confirmDeleteProject(project),
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.red.shade50,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Icon(
                                  Icons.delete_outline,
                                  size: 18,
                                  color: Colors.red.shade400,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
  
  Widget _buildDefaultThumbnail() {
    return Stack(
      alignment: Alignment.center,
      children: [
        Icon(
          Icons.video_library_rounded,
          size: 64,
          color: Colors.white.withOpacity(0.8),
        ),
        Positioned(
          bottom: 12,
          right: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              'No Preview',
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ],
    );
  }
  
  Widget _buildStatChip(IconData icon, String count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            count,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
  
  Future<Map<String, dynamic>> _getProjectStats(Project project) async {
    try {
      final projectDir = Directory(project.projectPath);
      int promptCount = 0;
      int videoCount = 0;
      int imageCount = 0;
      String? thumbnailPath;
      
      // Count prompts from prompts.txt
      final promptsFile = File(path.join(project.projectPath, 'prompts.txt'));
      if (await promptsFile.exists()) {
        final content = await promptsFile.readAsString();
        promptCount = content.split('\n').where((line) => line.trim().isNotEmpty).length;
      }
      
      // Check for scene builder autosave.json which contains generatedImagePaths
      final autosaveFile = File(path.join(project.projectPath, 'autosave.json'));
      if (await autosaveFile.exists()) {
        try {
          final json = jsonDecode(await autosaveFile.readAsString());
          if (json['generatedImagePaths'] != null) {
            final List<dynamic> imagePaths = json['generatedImagePaths'];
            // Filter existing files only
            for (var imgPath in imagePaths) {
              if (imgPath is String && await File(imgPath).exists()) {
                imageCount++;
                thumbnailPath ??= imgPath; // Use first available image
              }
            }
          }
        } catch (e) {
          // Autosave parsing failed, continue with other methods
        }
      }
      
      // Check outputs folder for videos and get thumbnail
      final outputsDir = Directory(path.join(project.projectPath, 'outputs'));
      if (await outputsDir.exists()) {
        final files = await outputsDir.list().toList();
        for (var file in files) {
          if (file is File) {
            final ext = path.extension(file.path).toLowerCase();
            if (ext == '.mp4' || ext == '.mov' || ext == '.avi') {
              videoCount++;
              // Use first video as thumbnail source (could extract frame later)
              thumbnailPath ??= file.path;
            }
          }
        }
      }
      
      // Check images folder
      final imagesDir = Directory(path.join(project.projectPath, 'images'));
      if (await imagesDir.exists()) {
        final files = await imagesDir.list().toList();
        for (var file in files) {
          if (file is File) {
            final ext = path.extension(file.path).toLowerCase();
            if (ext == '.png' || ext == '.jpg' || ext == '.jpeg' || ext == '.webp') {
              imageCount++;
              // Use first image as thumbnail
              thumbnailPath ??= file.path;
            }
          }
        }
      }
      
      // Check generated_images folder (scene builder saves here)
      final generatedImagesDir = Directory(path.join(project.projectPath, 'generated_images'));
      if (await generatedImagesDir.exists()) {
        final files = await generatedImagesDir.list().toList();
        for (var file in files) {
          if (file is File) {
            final ext = path.extension(file.path).toLowerCase();
            if (ext == '.png' || ext == '.jpg' || ext == '.jpeg' || ext == '.webp') {
              imageCount++;
              thumbnailPath ??= file.path;
            }
          }
        }
      }
      
      // Also check scene_images folder
      final sceneImagesDir = Directory(path.join(project.projectPath, 'scene_images'));
      if (await sceneImagesDir.exists()) {
        final files = await sceneImagesDir.list().toList();
        for (var file in files) {
          if (file is File) {
            final ext = path.extension(file.path).toLowerCase();
            if (ext == '.png' || ext == '.jpg' || ext == '.jpeg' || ext == '.webp') {
              imageCount++;
              thumbnailPath ??= file.path;
            }
          }
        }
      }
      
      return {
        'prompts': promptCount,
        'videos': videoCount,
        'images': imageCount,
        'thumbnail': thumbnailPath,
      };
    } catch (e) {
      return {'prompts': 0, 'videos': 0, 'images': 0, 'thumbnail': null};
    }
  }

  Widget _buildProjectCard(Project project, bool isMobile) {
    return Card(
      margin: EdgeInsets.only(bottom: isMobile ? 8 : 12),
      child: InkWell(
        onTap: () => _selectProject(project),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.all(isMobile ? 12 : 16),
          child: Row(
            children: [
              CircleAvatar(
                radius: isMobile ? 20 : 24,
                backgroundColor: Colors.blue.shade100,
                child: Icon(Icons.folder, color: Colors.blue.shade700, size: isMobile ? 20 : 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      project.name,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: isMobile ? 14 : 16,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _formatDate(project.lastModified ?? project.createdAt),
                      style: TextStyle(
                        fontSize: isMobile ? 11 : 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline, color: Colors.red, size: isMobile ? 20 : 22),
                tooltip: 'Delete Project',
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(minWidth: isMobile ? 32 : 40, minHeight: isMobile ? 32 : 40),
                onPressed: () => _confirmDeleteProject(project),
              ),
              Icon(Icons.arrow_forward_ios, size: isMobile ? 16 : 18, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDeleteProject(Project project) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Project'),
        content: Text('Are you sure you want to delete "${project.name}"?\n\nThis will delete the project folder and all its data permanently.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      try {
        final projectDir = Directory(project.projectPath);
        if (await projectDir.exists()) {
          await projectDir.delete(recursive: true);
        }
        await _loadProjects();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Deleted "${project.name}"')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error deleting project: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  Widget _buildFooter(bool isMobile) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Icon(Icons.folder_special, size: 16, color: Colors.grey.shade600),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isMobile 
                        ? 'Tap ℹ️ to see storage location'
                        : _projectsBasePath.isEmpty ? 'Loading...' : _projectsBasePath,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade600,
                      fontFamily: isMobile ? null : 'monospace',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.info_outline, size: 18, color: Colors.blue.shade600),
            tooltip: 'View Full Path',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: _showProjectsPathInfo,
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) {
      return 'Today at ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    } else if (diff.inDays == 1) {
      return 'Yesterday';
    } else if (diff.inDays < 7) {
      return '${diff.inDays} days ago';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }
}
