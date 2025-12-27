# VideoFX Flow Automation - Quick Reference

## Available Configuration Options

### Aspect Ratios
```dart
AspectRatio.landscape  // 16:9 (Default)
AspectRatio.portrait   // 9:16
```

### Veo Models
```dart
VeoModel.veo31Fast     // Veo 3.1 - Fast (Default, Beta Audio)
VeoModel.veo31Quality  // Veo 3.1 - Quality (Beta Audio)
VeoModel.veo2Fast      // Veo 2 - Fast (Legacy)
VeoModel.veo2Quality   // Veo 2 - Quality (Legacy)
```

### Number of Videos
```dart
numberOfVideos: 1  // Single video
numberOfVideos: 2  // Default
numberOfVideos: 3
numberOfVideos: 4  // Maximum
```

## Quick Start

### 1. Start Chrome with Remote Debugging
```bash
chrome.exe --remote-debugging-port=9222
```

### 2. Login to VideoFX
Navigate to: https://labs.google/fx/tools/flow

### 3. Run Automation Script
```bash
dart test/flow_ui_automation.dart
```

## Code Snippets

### Basic Generation (Default Settings)
```dart
final automation = FlowUiAutomation();
await automation.connect();
await automation.enableNetworkMonitoring();
await automation.generateVideo(prompt: "Your prompt here");
final videoUrl = await automation.waitForVideoCompletion();
await automation.downloadVideo(videoUrl, 'output.mp4');
```

### Custom Configuration
```dart
await automation.configureSettings(
  aspectRatio: AspectRatio.portrait,
  model: VeoModel.veo31Quality,
  numberOfVideos: 1,
);
```

### Create New Project
```dart
await automation.createNewProject();
await Future.delayed(Duration(seconds: 3)); // Wait for navigation
```

### Full Workflow Example
```dart
final automation = FlowUiAutomation();

try {
  await automation.connect();
  await automation.enableNetworkMonitoring();
  
  // Create new project
  await automation.createNewProject();
  await Future.delayed(Duration(seconds: 3));
  
  // Configure settings
  await automation.configureSettings(
    aspectRatio: AspectRatio.portrait,
    model: VeoModel.veo31Quality,
    numberOfVideos: 1,
  );
  
  // Generate video
  await automation.generateVideo(
    prompt: "A cinematic shot of a futuristic city at night"
  );
  
  // Wait for completion and download
  final videoUrl = await automation.waitForVideoCompletion();
  if (videoUrl != null) {
    await automation.downloadVideo(
      videoUrl, 
      'downloads/my_video.mp4'
    );
  }
} finally {
  automation.close();
}
```

## UI Element Selectors

| Element | Selector | Method |
|---------|----------|--------|
| Settings Button | `button` with `tune` icon | `_openSettingsPanel()` |
| Aspect Ratio | `button[role="combobox"]` + "Aspect Ratio" label | `_setAspectRatio()` |
| Model | `button[role="combobox"]` + "Model" label | `_setModel()` |
| Outputs | `button[role="combobox"]` + "Outputs" label | `_setNumberOfVideos()` |
| Prompt Input | `#PINHOLE_TEXT_AREA_ELEMENT_ID` | `generateVideo()` |
| Generate Button | `button` with `arrow_forward` icon | `generateVideo()` |

## API Endpoints

### Generate Video
```
POST https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoText
```

### Check Status
```
POST https://aisandbox-pa.googleapis.com/v1/video:batchCheckAsyncVideoGenerationStatus
```

### Download Video
```
GET <fifeUrl from response>
```

## Status Values

- `MEDIA_GENERATION_STATUS_PENDING` - Queued
- `MEDIA_GENERATION_STATUS_ACTIVE` - Generating
- `MEDIA_GENERATION_STATUS_SUCCESSFUL` - Complete
- `MEDIA_GENERATION_STATUS_FAILED` - Failed

## Common Issues

### Generate Button Stays Disabled
**Solution**: Use `Input.insertText` via CDP, not direct DOM manipulation
```dart
await sendCommand('Input.insertText', {'text': prompt});
```

### Settings Not Applying
**Solution**: Add delays between configuration steps
```dart
await Future.delayed(Duration(milliseconds: 300));
```

### Video URL Not Found
**Solution**: Increase polling timeout or check DOM structure
```dart
await automation.waitForVideoCompletion(maxWaitSeconds: 600);
```

## Credit Costs (Approximate)

| Configuration | Credits |
|---------------|---------|
| 1 video, Fast | ~20 credits |
| 1 video, Quality | ~50 credits |
| 2 videos, Fast | ~40 credits |
| 4 videos, Quality | ~200 credits |

*Note: Actual costs may vary based on video length and complexity*

## Best Practices

1. **Always enable network monitoring** before generating videos
2. **Add delays** after navigation and configuration changes
3. **Use try-finally** to ensure cleanup (close WebSocket)
4. **Check for null** video URLs before downloading
5. **Handle timeouts** gracefully with appropriate error messages
6. **Download immediately** after getting video URL (signed URLs expire)

## Integration Example

```dart
// In your BrowserVideoGenerator service:
class BrowserVideoGenerator {
  final FlowUiAutomation _automation = FlowUiAutomation();
  
  Future<void> initialize() async {
    await _automation.connect();
    await _automation.enableNetworkMonitoring();
  }
  
  Future<String?> generateVideo({
    required String prompt,
    AspectRatio ratio = AspectRatio.landscape,
    VeoModel model = VeoModel.veo31Fast,
    int count = 1,
  }) async {
    await _automation.configureSettings(
      aspectRatio: ratio,
      model: model,
      numberOfVideos: count,
    );
    
    await _automation.generateVideo(prompt: prompt);
    return await _automation.waitForVideoCompletion();
  }
  
  void dispose() {
    _automation.close();
  }
}
```

---

**Last Updated**: 2025-12-20  
**Version**: 1.1
