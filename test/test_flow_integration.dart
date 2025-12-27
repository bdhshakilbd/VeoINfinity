import 'package:veo3_another/services/browser_video_generator.dart';

/// Test the Flow UI automation integration
void main() async {
  print('=== Flow UI Automation Test ===\n');
  
  final generator = BrowserVideoGenerator();
  
  try {
    // Connect to Chrome
    print('Connecting to Chrome...');
    await generator.connect();
    print('✓ Connected\n');
    
    // Test the complete workflow
    print('Starting video generation workflow...');
    final outputPath = await generator.generateVideoCompleteFlow(
      prompt: "A beautiful sunset over the ocean, cinematic, 4k",
      outputPath: "downloads/test_video_${DateTime.now().millisecondsSinceEpoch}.mp4",
      aspectRatio: "Landscape (16:9)",
      model: "Veo 3.1 - Fast",
      numberOfVideos: 1,
    );
    
    if (outputPath != null) {
      print('\n✓ SUCCESS! Video saved to: $outputPath');
    } else {
      print('\n✗ FAILED: Video generation did not complete');
    }
    
  } catch (e, stack) {
    print('\n✗ ERROR: $e');
    print(stack);
  } finally {
    generator.close();
    print('\nConnection closed.');
  }
}
