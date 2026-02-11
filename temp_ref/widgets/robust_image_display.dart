
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';

class RobustImageDisplay extends StatefulWidget {
  final File? imageFile;
  final Uint8List? imageBytes;
  final String id;
  final VoidCallback? onTap;
  final String? badgeText; // Optional badge text (e.g., "1", "2", "3")
  final BoxFit? fit;

  const RobustImageDisplay({
    Key? key,
    required this.id,
    this.imageFile,
    this.imageBytes,
    this.onTap,
    this.badgeText,
    this.fit,
  }) : super(key: key);

  @override
  State<RobustImageDisplay> createState() => _RobustImageDisplayState();
}

class _RobustImageDisplayState extends State<RobustImageDisplay> {
  int _retryCount = 0;
  bool _hasError = false;
  Key _uniqueKey = UniqueKey();

  @override
  void didUpdateWidget(RobustImageDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.imageFile?.path != oldWidget.imageFile?.path || 
        widget.imageBytes != oldWidget.imageBytes) {
      _retryCount = 0;
      _hasError = false;
      _uniqueKey = UniqueKey();
      if (mounted) setState(() {});
    }
  }

  void _handleError(Object error, StackTrace? stackTrace) {
    print('⚠️ Error loading image for ${widget.id}: $error');
    
    if (_retryCount < 3) {
      _retryCount++;
      print('   🔄 Retrying image load ($_retryCount/3)...');
      
      // Delay retry slightly to allow filesystem to catch up
      Future.delayed(Duration(milliseconds: 500 * _retryCount), () {
        if (mounted) {
          setState(() {
            _uniqueKey = UniqueKey(); // Force reload
            _hasError = false;
          });
        }
      });
    } else {
      if (mounted) {
        setState(() {
          _hasError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.imageFile == null && widget.imageBytes == null) {
      return Container(
        color: Colors.grey.shade100,
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    
    Widget imageWidget;
    
    if (widget.imageFile != null) {
       imageWidget = Image.file(
        widget.imageFile!,
        // key: _uniqueKey, // removing key here to let parent handle it or avoid conflicts if key passed to widget
        fit: widget.fit ?? BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          // If file fails, try validation or fallback
          _handleError(error, stackTrace);
          
          // While retrying or if failed, show Bytes or Error
          if (widget.imageBytes != null) {
            return Image.memory(
              widget.imageBytes!,
              fit: widget.fit ?? BoxFit.cover,
              gaplessPlayback: true,
            );
          }
          
          return Container(
             color: Colors.grey.shade200,
             child: Column(
               mainAxisAlignment: MainAxisAlignment.center,
               children: [
                 Icon(Icons.broken_image, color: Colors.grey.shade400),
                 const SizedBox(height: 4),
                 if (_retryCount > 0 && _retryCount < 3)
                   const SizedBox(
                     width: 12, height: 12, 
                     child: CircularProgressIndicator(strokeWidth: 1)
                   )
               ],
             ),
          );
        },
      );
    } else {
      imageWidget = Image.memory(
        widget.imageBytes!,
        fit: widget.fit ?? BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const Icon(Icons.error),
      );
    }

    // Wrap with Stack to add badge overlay
    Widget displayWidget = Stack(
      children: [
        imageWidget,
        // Golden star badge in top-left corner
        if (widget.badgeText != null)
          Positioned(
            top: 6,
            left: 6,
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.amber.shade400, Colors.yellow.shade600],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.orange.shade800, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.6),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  widget.badgeText!,
                  style: TextStyle(
                    color: Colors.grey.shade900,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    height: 1,
                  ),
                ),
              ),
            ),
          ),
      ],
    );

    if (widget.onTap != null) {
      return GestureDetector(
        onTap: widget.onTap,
        child: displayWidget,
      );
    }
    
    return displayWidget;
  }
}
