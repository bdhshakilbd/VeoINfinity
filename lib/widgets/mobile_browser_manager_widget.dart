
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../services/mobile/mobile_browser_service.dart';

class MobileBrowserManagerWidget extends StatefulWidget {
  final int browserCount;
  final Function(bool) onVisibilityChanged; // To callback when closed

  const MobileBrowserManagerWidget({
    Key? key,
    this.browserCount = 4, // Default 4 profiles
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
  final MobileBrowserService _service = MobileBrowserService();
  final String _initialUrl = 'https://labs.google/fx/tools/flow';
  
  // Unique keys for each WebView to ensure proper isolation
  final List<GlobalKey> _webViewKeys = [];

  @override
  void initState() {
    super.initState();
    _isVisible = widget.initiallyVisible;
    _service.initialize(widget.browserCount);
    
    // Create unique keys for each browser
    for (int i = 0; i < widget.browserCount; i++) {
      _webViewKeys.add(GlobalKey(debugLabel: 'webview_$i'));
    }
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
    // We use an IndexedStack to keep all WebViews alive
    // We wrap it in Offstage if not visible to user, 
    // BUT we must ensure Offstage doesn't kill the webview.
    // In Flutter, Offstage keeps the subtree alive.
    
    // However, to view them on menu, we need a wrapper UI.
    
    return Stack(
      children: [
        // The WebViews (Always live, but hidden if not _isVisible)
        Offstage(
          offstage: !_isVisible,
          child: Scaffold(
            appBar: AppBar(
              title: Text('Browser ${_selectedIndex + 1}'),
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: hide,
              ),
              actions: [
                DropdownButton<int>(
                  value: _selectedIndex,
                  dropdownColor: Colors.blue,
                  style: const TextStyle(color: Colors.white),
                  items: List.generate(widget.browserCount, (index) {
                    final p = _service.getProfile(index);
                    String status = 'unknown';
                    if (p != null) {
                       if (p.status == MobileProfileStatus.ready) status = 'Ready';
                       else if (p.status == MobileProfileStatus.connected) status = 'Loaded';
                       else if (p.status == MobileProfileStatus.loading) status = 'Loading...';
                       else status = 'Disc';
                    }
                    return DropdownMenuItem(
                      value: index,
                      child: Text('Browser ${index + 1} ($status)'),
                    );
                  }),
                  onChanged: (val) {
                    if (val != null) setState(() => _selectedIndex = val);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () {
                    _service.getProfile(_selectedIndex)?.controller?.reload();
                  },
                ),
                // Manual token fetch button
                IconButton(
                  icon: const Icon(Icons.key),
                  tooltip: 'Fetch Token',
                  onPressed: () async {
                    final profile = _service.getProfile(_selectedIndex);
                    if (profile?.generator != null) {
                      final token = await profile!.generator!.getAccessToken();
                      if (token != null) {
                        profile.accessToken = token;
                        profile.status = MobileProfileStatus.ready;
                        setState(() {});
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Token fetched! ${token.substring(0, 20)}...')),
                        );
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('No token found - please login first')),
                        );
                      }
                    }
                  },
                ),
              ],
            ),
            body: IndexedStack(
              index: _selectedIndex,
              children: List.generate(widget.browserCount, (index) {
                return InAppWebView(
                  key: _webViewKeys[index], // Unique key for each WebView
                  initialUrlRequest: URLRequest(url: WebUri(_initialUrl)),
                  initialSettings: InAppWebViewSettings(
                    isInspectable: true,
                    mediaPlaybackRequiresUserGesture: false,
                    allowsInlineMediaPlayback: true,
                    // Use separate cache and storage settings per browser
                    cacheEnabled: true,
                    javaScriptCanOpenWindowsAutomatically: true,
                    supportMultipleWindows: false,
                    // Use hybrid composition for better Android WebView isolation  
                    useHybridComposition: true,
                    userAgent: "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
                  ),
                  onWebViewCreated: (controller) {
                    print('[MOBILE] WebView $index created with unique key');
                    final profile = _service.getProfile(index);
                    if (profile != null) {
                      profile.controller = controller;
                      profile.generator = MobileVideoGenerator(controller);
                      
                      // Hook console messages for debugging
                      controller.addJavaScriptHandler(handlerName: 'consoleLog', callback: (args) {
                         print('[WV$index] ${args.join(" ")}');
                      });
                    }
                  },
                  onLoadStop: (controller, url) async {
                    print('[MOBILE] WebView $index loaded: $url');
                    final profile = _service.getProfile(index);
                    if (profile != null) {
                      profile.status = MobileProfileStatus.connected;
                      
                      // Try to auto-detect login
                      if (url.toString().contains('labs.google') && !url.toString().contains('accounts.google')) {
                         final token = await profile.generator?.getAccessToken();
                         if (token != null && token.isNotEmpty) {
                           profile.accessToken = token;
                           profile.status = MobileProfileStatus.ready;
                           print('[MOBILE] Profile $index READY with token: ${token.substring(0, 30)}...');
                           setState(() {}); // Update UI
                         }
                      }
                    }
                  },
                );
              }),
            ),
          ),
        ),
      ],
    );
  }
}

