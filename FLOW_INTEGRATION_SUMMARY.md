# Flow UI Automation Integration - Summary

## What Was Added

The complete Flow UI automation workflow has been integrated into `lib/services/browser_video_generator.dart`.

## New Methods Available

### 1. **Complete Workflow (Recommended)**
```dart
Future<String?> generateVideoCompleteFlow({
  required String prompt,
  required String outputPath,
  String aspectRatio = 'Landscape (16:9)',
  String model = 'Veo 3.1 - Fast',
  int numberOfVideos = 1,
})
```

**This method handles everything:**
- ✅ Checks if on project page, creates new project if needed
- ✅ Configures aspect ratio, model, and number of videos
- ✅ Enters the prompt using CDP (realistic typing)
- ✅ Clicks the Generate button
- ✅ Waits for video completion (polls DOM)
- ✅ Downloads the completed video
- ✅ Returns the output path on success

### 2. **Individual Methods**

For more control, you can use these methods separately:

- `getCurrentUrl()` - Get current page URL
- `createNewProject()` - Click "New project" button
- `configureFlowSettings()` - Set aspect ratio, model, video count
- `generateVideoViaFlow()` - Enter prompt and click generate
- `waitForFlowVideoCompletion()` - Poll for completion, return video URL

## Usage Example

```dart
// Initialize the generator
final generator = BrowserVideoGenerator();
await generator.connect();

// Generate a video using the complete workflow
final outputPath = await generator.generateVideoCompleteFlow(
  prompt: "A cinematic shot of a futuristic city at night, neon lights, rain",
  outputPath: "downloads/my_video.mp4",
  aspectRatio: "Portrait (9:16)",
  model: "Veo 3.1 - Quality",
  numberOfVideos: 1,
);

if (outputPath != null) {
  print("Video saved to: $outputPath");
} else {
  print("Video generation failed");
}

generator.close();
```

## Configuration Options

### Aspect Ratios
- `"Landscape (16:9)"` - Default, horizontal
- `"Portrait (9:16)"` - Vertical for mobile/social

### Models
- `"Veo 3.1 - Fast"` - Default, fastest generation, Beta Audio
- `"Veo 3.1 - Quality"` - Best quality, Beta Audio
- `"Veo 2 - Fast"` - Legacy fast model
- `"Veo 2 - Quality"` - Legacy quality model

### Number of Videos
- `1` to `4` videos per prompt
- Default: `1`

## How It Works

1. **UI Detection**: Uses JavaScript to find elements by text content and ARIA roles
2. **CDP Input**: Uses Chrome DevTools Protocol `Input.insertText` for realistic typing
3. **Settings Configuration**: Clicks dropdowns and selects options programmatically
4. **Completion Polling**: Checks DOM every 5 seconds for `<video>` elements with Google Storage URLs
5. **Download**: Uses standard HTTP GET to download the video file

## Integration Points

### For Bulk Generation
You can now use this in your bulk task executor:

```dart
// In bulk_task_executor.dart or similar
final generator = BrowserVideoGenerator();
await generator.connect();

for (final task in tasks) {
  final videoPath = await generator.generateVideoCompleteFlow(
    prompt: task.prompt,
    outputPath: task.outputPath,
    aspectRatio: task.aspectRatio,
    model: task.model,
  );
  
  if (videoPath != null) {
    // Update task status to completed
  }
}
```

### For Single Generation
You can add a button in your UI that calls this method directly.

## Advantages Over API Method

1. **No Token Management**: Uses browser's existing session
2. **No reCAPTCHA Handling**: Browser already solved it during login
3. **Visual Feedback**: Can see the generation happening in the browser
4. **Reliable**: Uses the same flow as manual user interaction
5. **Configuration Support**: Can set aspect ratio, model, and video count

## Notes

- Requires Chrome running with `--remote-debugging-port=9222`
- User must be logged into https://labs.google/fx/tools/flow
- Timeout is 300 seconds (5 minutes) by default
- Uses CDP for realistic input to avoid bot detection

---

**Created**: 2025-12-21  
**Integrated into**: `lib/services/browser_video_generator.dart`
