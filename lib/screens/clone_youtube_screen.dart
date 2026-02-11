import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Clone YouTube Screen - YouTube video cloning tool
class CloneYouTubeScreen extends StatefulWidget {
  const CloneYouTubeScreen({super.key});

  @override
  State<CloneYouTubeScreen> createState() => _CloneYouTubeScreenState();
}

class _CloneYouTubeScreenState extends State<CloneYouTubeScreen> 
    with AutomaticKeepAliveClientMixin {
  
  @override
  bool get wantKeepAlive => true; // Keep this widget alive when switching tabs
  
  InAppWebViewController? _webViewController;
  final GlobalKey _webViewKey = GlobalKey();
  bool _isWebViewLoading = true;
  bool _webViewInitialized = false;

  @override
  Widget build(BuildContext context) {
    // CRITICAL: Must call super.build to enable AutomaticKeepAliveClientMixin
    super.build(context);
    
    return Stack(
      children: [
        // Only build webview once and keep it alive
        if (!_webViewInitialized || _webViewController != null)
          InAppWebView(
            key: _webViewKey,
            initialUrlRequest: URLRequest(
              url: WebUri('https://ai.studio/apps/drive/1GWn1yu8l66TjZk5_GeqPvc5WNlnkNhRt?fullscreenApplet=true'),
            ),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              javaScriptCanOpenWindowsAutomatically: true,
              mediaPlaybackRequiresUserGesture: false,
              allowsInlineMediaPlayback: true,
              useHybridComposition: Platform.isAndroid,
              // Additional settings to keep webview alive
              disableContextMenu: false,
              supportZoom: true,
              cacheEnabled: true,
            ),
            onWebViewCreated: (controller) {
              _webViewController = controller;
              _webViewInitialized = true;
              print('[Clone YouTube WebView] Created and will stay alive');
            },
            onLoadStart: (controller, url) {
              print('[Clone YouTube WebView] Loading: $url');
              if (mounted) setState(() => _isWebViewLoading = true);
            },
            onLoadStop: (controller, url) async {
              print('[Clone YouTube WebView] Loaded: $url');
              if (mounted) setState(() => _isWebViewLoading = false);
            },
            onReceivedError: (controller, request, error) {
              print('[Clone YouTube WebView] Error: ${error.description}');
              if (mounted) setState(() => _isWebViewLoading = false);
            },
            shouldOverrideUrlLoading: (controller, navigationAction) async {
              // Allow all navigation within the webview
              return NavigationActionPolicy.ALLOW;
            },
          ),
        
        // Loading Overlay
        if (_isWebViewLoading)
          Container(
            color: Colors.white,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Loading Clone YouTube App...',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'This page stays open when you switch tabs',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
  
  @override
  void dispose() {
    // Don't dispose the webview controller - let it stay alive
    // Only dispose when the entire app closes
    print('[Clone YouTube WebView] Widget dispose called - keeping webview alive');
    super.dispose();
  }
}
