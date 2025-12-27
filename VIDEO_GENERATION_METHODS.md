# Video Generation Methods - Summary

## Changes Made

### 1. **Updated Config (`lib/utils/config.dart`)**

Added new model options and generation methods:

#### API-Based Models (Old Method - Kept)
```dart
'Veo 3.1 Fast (API)': 'veo_3_1_t2v_fast_ultra',
'Veo 3.1 Quality (API)': 'veo_3_1_t2v_quality_ultra',
'Veo 2 Fast (API)': 'veo_2_t2v_fast',
'Veo 2 Quality (API)': 'veo_2_t2v_quality',
```

#### Flow UI Models (New Method)
```dart
'Veo 3.1 - Fast': 'Veo 3.1 - Fast',
'Veo 3.1 - Quality': 'Veo 3.1 - Quality',
'Veo 2 - Fast': 'Veo 2 - Fast',
'Veo 2 - Quality': 'Veo 2 - Quality',
```

#### Generation Methods
```dart
'API (Direct)': 'api',
'Flow UI (Automation)': 'flow_ui',
```

### 2. **Fixed Invalid Model**

Replaced all instances of invalid model `veo_3_1_t2v_fast_ultra_relaxed` with valid `veo_3_1_t2v_fast_ultra` in:
- `lib/main.dart`
- `lib/models/bulk_task.dart`
- `lib/widgets/heavy_bulk_tasks_screen.dart`

### 3. **Integrated Flow UI Automation**

Added to `lib/services/browser_video_generator.dart`:
- `generateVideoCompleteFlow()` - Complete workflow method
- `configureFlowSettings()` - Configure aspect ratio, model, video count
- `generateVideoViaFlow()` - UI automation for prompt entry
- `waitForFlowVideoCompletion()` - Poll for completion

## Two Methods Available

### Method 1: API (Direct) - **OLD METHOD (KEPT)**
```dart
final generator = BrowserVideoGenerator();
await generator.connect();

final accessToken = await generator.getAccessToken();

final result = await generator.generateVideo(
  prompt: "Your prompt",
  accessToken: accessToken!,
  aspectRatio: 'VIDEO_ASPECT_RATIO_LANDSCAPE',
  model: 'veo_3_1_t2v_fast_ultra',
);

// Then poll for completion
final status = await generator.pollVideoStatus(
  operationName,
  sceneId,
  accessToken,
);
```

**Pros:**
- Direct API calls
- Faster (no UI interaction)
- Can run in background

**Cons:**
- Requires access token management
- Requires reCAPTCHA handling
- Limited to API-supported models

### Method 2: Flow UI (Automation) - **NEW METHOD (ADDED)**
```dart
final generator = BrowserVideoGenerator();
await generator.connect();

final videoPath = await generator.generateVideoCompleteFlow(
  prompt: "Your prompt",
  outputPath: "output/video.mp4",
  aspectRatio: "Landscape (16:9)",  // or "Portrait (9:16)"
  model: "Veo 3.1 - Quality",       // UI-friendly names
  numberOfVideos: 1,                 // 1-4
);
```

**Pros:**
- No token management needed
- No reCAPTCHA handling
- Can configure aspect ratio, model, video count
- Uses browser's existing session
- Visual feedback in browser

**Cons:**
- Requires visible browser window
- Slightly slower (UI interaction)
- Depends on UI element stability

## Recommended Usage

### For Bulk Generation
Use **Flow UI method** for reliability:
```dart
for (final task in tasks) {
  final videoPath = await generator.generateVideoCompleteFlow(
    prompt: task.prompt,
    outputPath: task.outputPath,
    aspectRatio: task.aspectRatio,
    model: task.model,
  );
}
```

### For Single Quick Generation
Use **API method** for speed (if you have valid token):
```dart
final result = await generator.generateVideo(
  prompt: prompt,
  accessToken: token,
  model: 'veo_3_1_t2v_fast_ultra',
);
```

## Next Steps

To add UI selection between methods, you can:

1. Add a dropdown in your UI:
```dart
DropdownButton<String>(
  value: selectedMethod,
  items: AppConfig.generationMethodOptions.entries.map((e) {
    return DropdownMenuItem(value: e.value, child: Text(e.key));
  }).toList(),
  onChanged: (value) => setState(() => selectedMethod = value!),
)
```

2. Use the selected method:
```dart
if (selectedMethod == 'flow_ui') {
  // Use Flow UI automation
  await generator.generateVideoCompleteFlow(...);
} else {
  // Use API method
  await generator.generateVideo(...);
}
```

---

**Status**: ✅ Both methods are now available and working
**Default**: API method (for backward compatibility)
**Recommended**: Flow UI method (for new features)
