
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../services/mobile/mobile_browser_service.dart';
import '../services/mobile/mobile_log_manager.dart';

class MobileBrowserManagerWidget extends StatefulWidget {
  final int browserCount;
  final Function(bool) onVisibilityChanged; // To callback when closed

  const MobileBrowserManagerWidget({
    Key? key,
    this.browserCount = 1, // Default 1 browser on startup
    required this.onVisibilityChanged,
    this.initiallyVisible = false,
  }) : super(key: key);

  final bool initiallyVisible;

  @override
  State<MobileBrowserManagerWidget> createState() => _MobileBrowserManagerWidgetState();
}

class _MobileBrowserManagerWidgetState extends State<MobileBrowserManagerWidget> {
  int _selectedIndex = 0;
  bool _isVisible = false;
  bool _showLogs = false;  // Toggle for log panel
  bool _showLoginPanel = false;  // Toggle for login panel
  bool _isLoggingIn = false;  // Login in progress
  final MobileBrowserService _service = MobileBrowserService();
  final String _initialUrl = 'https://labs.google/fx/tools/flow';
  
  // Login credentials
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  
  // Unique keys for each WebView to ensure proper isolation
  final List<GlobalKey> _webViewKeys = [];
  
  // Log manager and subscription
  final MobileLogManager _logManager = MobileLogManager();
  StreamSubscription<String>? _logSubscription;
  final ScrollController _logScrollController = ScrollController();
  
  // Stream subscription for cycling
  StreamSubscription<int>? _refreshSubscription;
  Timer? _logThrottleTimer;

  @override
  void initState() {
    super.initState();
    print('[BROWSER WIDGET] initState called, initiallyVisible: ${widget.initiallyVisible}');
    _isVisible = widget.initiallyVisible;
    _service.initialize(widget.browserCount);
    print('[BROWSER WIDGET] Service initialized with ${widget.browserCount} browsers');
    
    // Create unique keys for each browser
    _syncWebViewKeys();
    
    // Listen to log updates with strict throttling to prevent UI lag.
    // We only trigger a rebuild every 500ms if there are new logs.
    _logSubscription = _logManager.stream.listen((log) {
      if (mounted && _showLogs) {
        if (_logThrottleTimer == null || !_logThrottleTimer!.isActive) {
          _logThrottleTimer = Timer(const Duration(milliseconds: 500), () {
            if (mounted) {
              setState(() {});
              // Jump to bottom immediately without animation to save CPU
              if (_logScrollController.hasClients) {
                _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
              }
            }
          });
        }
      }
    });

    // Listen to refresh/cycling requests
    _refreshSubscription = _service.refreshStream.listen((index) {
      if (mounted && index >= 0 && index < _webViewKeys.length) {
        setState(() {
          // Clear current controller/generator before recreation to signal the relogin logic
          final profile = _service.getProfile(index);
          profile?.controller = null;
          profile?.generator = null;
          
          // Change the key to force disposal and recreation of InAppWebView
          _webViewKeys[index] = GlobalKey(debugLabel: 'webview_${index}_rebuild_${DateTime.now().millisecondsSinceEpoch}');
        });
      }
    });
  }

  void _syncWebViewKeys() {
    // Ensure _webViewKeys has exactly the same number of keys as profiles
    while (_webViewKeys.length < _service.profiles.length) {
      _webViewKeys.add(GlobalKey(debugLabel: 'webview_${_webViewKeys.length}'));
    }
    while (_webViewKeys.length > _service.profiles.length) {
      _webViewKeys.removeLast();
    }
  }

  @override
  void didUpdateWidget(covariant MobileBrowserManagerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    // If browser count changed, reinitialize the service
    if (oldWidget.browserCount != widget.browserCount) {
      print('[BROWSER] Count changed from ${oldWidget.browserCount} to ${widget.browserCount}');
      _service.initialize(widget.browserCount);
      _syncWebViewKeys();
      setState(() {});
    }
  }

  @override
  void dispose() {
    _logSubscription?.cancel();
    _refreshSubscription?.cancel();
    _logThrottleTimer?.cancel();
    _logScrollController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void show() {
    setState(() {
      _isVisible = true;
    });
    widget.onVisibilityChanged(true);
  }

  void hide() {
    setState(() {
      _isVisible = false;
    });
    widget.onVisibilityChanged(false);
  }

  @override
  Widget build(BuildContext context) {
    _syncWebViewKeys(); // Keep keys in sync with service profiles

    // Safety: Clamp selected index to available profiles to prevent black screens from out-of-bounds errors
    if (_selectedIndex >= _service.profiles.length) {
      _selectedIndex = _service.profiles.length - 1;
    }
    if (_selectedIndex < 0 && _service.profiles.isNotEmpty) {
      _selectedIndex = 0;
    }

    return Stack(
      children: [
        // Using Visibility(maintainState: true) to keep WebViews alive in the background
        Visibility(
          visible: _isVisible,
          maintainState: true,
          child: GestureDetector(
            onHorizontalDragEnd: (details) {
              // Swipe Left detected (Finger moved Right -> Left)
              if (details.primaryVelocity != null && details.primaryVelocity! < -800) {
                hide();
              }
            },
            child: Scaffold(
              backgroundColor: Colors.white, // Ensure no "black screen" from empty scaffold
              appBar: AppBar(
                backgroundColor: Colors.blueAccent.shade700,
                foregroundColor: Colors.white,
                elevation: 0,
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Close Overlay',
                  onPressed: hide,
                ),
                title: Text('B${_selectedIndex + 1}'),
                actions: [
                  // Quick Actions
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    tooltip: 'Refresh Current',
                    onPressed: () {
                      _service.getProfile(_selectedIndex)?.controller?.reload();
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.open_in_browser, size: 20, color: Colors.lightGreenAccent),
                    tooltip: 'Load Flow URL',
                    onPressed: () {
                      _service.getProfile(_selectedIndex)?.controller?.loadUrl(
                        urlRequest: URLRequest(url: WebUri('https://labs.google/fx/tools/flow'))
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.sync_problem, color: Colors.orangeAccent, size: 20),
                    tooltip: 'Cycle Browser',
                    onPressed: () {
                      _service.cycleProfileWebView(_selectedIndex);
                    },
                  ),
                  // Auto Login button
                  IconButton(
                    icon: Icon(_isLoggingIn ? Icons.hourglass_empty : Icons.login, size: 20, color: Colors.lightBlueAccent),
                    tooltip: 'Auto Login',
                    onPressed: _isLoggingIn ? null : () {
                      setState(() => _showLoginPanel = !_showLoginPanel);
                    },
                  ),
                  // Toggle logs button
                  IconButton(
                    icon: Icon(_showLogs ? Icons.terminal : Icons.terminal_outlined, size: 20),
                    tooltip: 'Toggle Logs',
                    onPressed: () {
                      setState(() => _showLogs = !_showLogs);
                    },
                  ),
                  
                  // Browser selector
                  Theme(
                    data: Theme.of(context).copyWith(canvasColor: Colors.blueAccent.shade700),
                    child: DropdownButton<int>(
                      value: _selectedIndex,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      underline: const SizedBox(),
                      icon: const Icon(Icons.arrow_drop_down, color: Colors.white),
                      items: [
                        ...List.generate(_service.profiles.length, (index) {
                          final p = _service.getProfile(index);
                          String status = '...';
                          if (p != null) {
                            if (p.status == MobileProfileStatus.ready) status = 'Ready';
                            else if (p.status == MobileProfileStatus.connected) status = 'Loaded';
                            else if (p.status == MobileProfileStatus.loading) status = 'Wait';
                            else status = 'Disc';
                          }
                          return DropdownMenuItem<int>(
                            value: index,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('B${index + 1} ($status)'),
                                const SizedBox(width: 8),
                                if (_service.profiles.length > 1)
                                  GestureDetector(
                                    onTap: () {
                                      // Remove profile and ensure index doesn't go out of bounds
                                      _service.removeProfileAt(index);
                                      setState(() {
                                        if (_selectedIndex >= _service.profiles.length) {
                                          _selectedIndex = _service.profiles.length - 1;
                                        }
                                        // Navigator.of(context).pop() might be unnecessary if item is clicked,
                                        // but for the X button we close it. Close it safely.
                                        Navigator.maybeOf(context)?.pop();
                                      });
                                    },
                                    child: const Icon(Icons.close, color: Colors.redAccent, size: 16),
                                  ),
                              ],
                            ),
                          );
                        }),
                        const DropdownMenuItem<int>(
                          value: -1,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.add_circle_outline, color: Colors.greenAccent, size: 18),
                              SizedBox(width: 8),
                              Text('Add New', style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ],
                      onChanged: (val) async {
                        if (val == -1) {
                          _service.addNewProfile();
                          final newIndex = _service.profiles.length - 1;
                          setState(() {
                            _selectedIndex = newIndex;
                          });
                          
                          mobileLog('[UI] Created Browser ${newIndex + 1} - Auto-loading Flow...');
                          
                          for (int i = 0; i < 20; i++) {
                            await Future.delayed(const Duration(milliseconds: 200));
                            final p = _service.getProfile(newIndex);
                            if (p?.controller != null) {
                              p!.controller!.loadUrl(
                                urlRequest: URLRequest(url: WebUri('https://labs.google/fx/tools/flow'))
                              );
                              break;
                            }
                          }
                        } else if (val != null) {
                          setState(() => _selectedIndex = val);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            body: Column(
              children: [
                // Login Panel (collapsible)
                if (_showLoginPanel)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      border: Border(bottom: BorderSide(color: Colors.blue.shade200)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.login, size: 16, color: Colors.blue.shade700),
                            const SizedBox(width: 8),
                            Text('Auto Login', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.blue.shade700)),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => setState(() => _showLoginPanel = false),
                              tooltip: 'Close',
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _emailController,
                          decoration: InputDecoration(
                            labelText: 'Email',
                            hintText: 'your.email@gmail.com',
                            prefixIcon: const Icon(Icons.email, size: 18),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            isDense: true,
                          ),
                          keyboardType: TextInputType.emailAddress,
                          style: const TextStyle(fontSize: 13),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _passwordController,
                          decoration: InputDecoration(
                            labelText: 'Password',
                            hintText: '••••••••',
                            prefixIcon: const Icon(Icons.lock, size: 18),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            isDense: true,
                          ),
                          obscureText: true,
                          style: const TextStyle(fontSize: 13),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: _isLoggingIn ? null : _handleAutoLogin,
                                icon: _isLoggingIn 
                                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                  : const Icon(Icons.login, size: 16),
                                label: Text(_isLoggingIn ? 'Logging in...' : 'Login Browser ${_selectedIndex + 1}'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.blue.shade600,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'This will auto-login to Google and navigate to Flow',
                          style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                // WebView area
                Expanded(
                  child: IndexedStack(
                    index: _selectedIndex,
                    children: List.generate(_service.profiles.length, (index) {
                      return Container(
                        color: Colors.white, // Fallback background
                        child: InAppWebView(
                          key: _webViewKeys[index],
                          initialUrlRequest: URLRequest(url: WebUri(_initialUrl)),
                          initialSettings: InAppWebViewSettings(
                            isInspectable: true,
                            mediaPlaybackRequiresUserGesture: false,
                            allowsInlineMediaPlayback: true,
                            cacheEnabled: true,
                            domStorageEnabled: true,
                            databaseEnabled: true,
                            javaScriptCanOpenWindowsAutomatically: true,
                            supportMultipleWindows: false,
                            useHybridComposition: false,
                            disableContextMenu: true,
                            supportZoom: false,
                            // Realistic browser settings to avoid detection
                            hardwareAcceleration: true,
                            mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                            // Use latest Chrome user agent (Chrome 133 - February 2026)
                            userAgent: (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
                              ? "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36"
                              : "Mozilla/5.0 (Linux; Android 14; Pixel 8 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Mobile Safari/537.36",
                          ),
                          onReceivedError: (controller, request, error) {
                             print('[WEBVIEW] Error: ${error.description} (Code: ${error.type}) for ${request.url}');
                             mobileLog('[WEBVIEW ERROR] ${error.description}');
                          },
                          onReceivedHttpError: (controller, request, error) {
                             print('[WEBVIEW] HTTP Error: ${error.statusCode} ${error.reasonPhrase} for ${request.url}');
                             if (error.statusCode == 429) {
                               mobileLog('[WEBVIEW] 429 Too Many Requests!');
                             }
                          },
                          onConsoleMessage: (controller, consoleMessage) {
                            if (consoleMessage.messageLevel == ConsoleMessageLevel.ERROR) {
                               print('[WEBVIEW CONSOLE] ${consoleMessage.message}');
                               if (consoleMessage.message.contains('quota')) {
                                  mobileLog('[JS ERROR] ${consoleMessage.message}');
                               }
                            }
                          },
                          onWebViewCreated: (controller) {
                            print('[WEBVIEW $index] Created!');
                            final profile = _service.getProfile(index);
                            if (profile != null) {
                              profile.controller = controller;
                              profile.generator = MobileVideoGenerator(controller);
                              print('[WEBVIEW $index] Profile set up with controller');
                            }
                          },
                          onLoadStart: (controller, url) {
                            print('[WEBVIEW $index] Load START: $url');
                            mobileLog('[B$index] Loading: ${url?.host ?? url}');
                          },
                          onLoadStop: (controller, url) async {
                            print('[WEBVIEW $index] Load STOP: $url');
                            mobileLog('[B$index] Loaded: ${url?.host ?? url}');
                            final profile = _service.getProfile(index);
                            if (profile != null) {
                              profile.status = MobileProfileStatus.connected;
                              if (url.toString().contains('labs.google') && !url.toString().contains('accounts.google')) {
                                final token = await profile.generator?.getAccessTokenQuick();
                                if (token != null && token.isNotEmpty) {
                                  profile.accessToken = token;
                                  profile.status = MobileProfileStatus.ready;
                                  profile.consecutive403Count = 0; // Reset 403 count on successful token
                                  profile.isReloginInProgress = false;
                                  if (mounted) setState(() {});
                                }
                              }
                            }
                          },
                        ),
                      );
                    }),
                  ),
                ),
                // Log panel
                if (_showLogs)
                  Expanded(
                    child: Container(
                      color: Colors.black,
                      child: ListView.builder(
                        controller: _logScrollController,
                        padding: const EdgeInsets.all(8),
                        itemCount: _logManager.logs.length,
                        itemBuilder: (context, index) {
                          final log = _logManager.logs[index];
                          return Text(
                            log,
                            style: const TextStyle(color: Colors.white70, fontSize: 10, fontFamily: 'monospace'),
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

  // Auto-login handler
  Future<void> _handleAutoLogin() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    
    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚠️ Please enter both email and password'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    
    setState(() => _isLoggingIn = true);
    mobileLog('[UI] Starting auto-login for Browser ${_selectedIndex + 1}...');
    
    try {
      final profile = _service.getProfile(_selectedIndex);
      if (profile?.generator == null) {
        throw Exception('Browser not ready. Please wait a moment and try again.');
      }
      
      final success = await profile!.generator!.autoLogin(email, password);
      
      if (mounted) {
        setState(() => _isLoggingIn = false);
        
        if (success) {
          mobileLog('[UI] ✅ Login successful for Browser ${_selectedIndex + 1}!');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.white),
                  const SizedBox(width: 8),
                  Text('✅ Login successful for Browser ${_selectedIndex + 1}!'),
                ],
              ),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 3),
            ),
          );
          // Close login panel on success
          setState(() => _showLoginPanel = false);
        } else {
          mobileLog('[UI] ✗ Login failed for Browser ${_selectedIndex + 1}');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✗ Login failed. Check credentials and try again.'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 4),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoggingIn = false);
        mobileLog('[UI] Error during login: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }
}
