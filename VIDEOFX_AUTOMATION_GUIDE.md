# VideoFX Flow Automation Guide

## Overview
This document describes the automated video generation workflow for Google's VideoFX Flow using Chrome DevTools Protocol (CDP).

## Architecture

### 1. UI Element Identification
Through browser inspection, we identified the following key elements:

| Element | Location | Selector/ID | Description |
|---------|----------|-------------|-------------|
| **New Project Button** | Dashboard | Text: "New project" | Creates a new video project |
| **Prompt Input** | Project Page | `#PINHOLE_TEXT_AREA_ELEMENT_ID` | Textarea for video description |
| **Generate Button** | Project Page | Button with `arrow_forward` icon | Triggers video generation |
| **Settings Button** | Project Page | Button with `tune` icon | Opens configuration panel |
| **Aspect Ratio Selector** | Settings Panel | `button[role="combobox"]` with "Aspect Ratio" label | Landscape (16:9) or Portrait (9:16) |
| **Model Selector** | Settings Panel | `button[role="combobox"]` with "Model" label | Veo 3.1/2, Fast/Quality variants |
| **Outputs Selector** | Settings Panel | `button[role="combobox"]` with "Outputs per prompt" label | Number of videos (1-4) |

### Configuration Options

#### Aspect Ratio
- **Landscape (16:9)** - Default, horizontal format
- **Portrait (9:16)** - Vertical format for mobile/social media

#### Veo Models
- **Veo 3.1 - Fast** (Default) - Faster generation, Beta Audio support
- **Veo 3.1 - Quality** - Higher quality, Beta Audio support
- **Veo 2 - Fast** - Legacy fast model
- **Veo 2 - Quality** - Legacy quality model

#### Number of Videos
- **1-4 videos** per prompt (Default: 2)
- Note: More videos = higher credit cost

### 2. Network API Endpoints

#### Video Generation Request
- **Endpoint**: `POST https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoText`
- **Purpose**: Initiates video generation
- **Response**: Returns an `operation` object with a unique `name` (operation ID)
- **Status**: Initially set to `MEDIA_GENERATION_STATUS_PENDING`

#### Status Polling
- **Endpoint**: `POST https://aisandbox-pa.googleapis.com/v1/video:batchCheckAsyncVideoGenerationStatus`
- **Purpose**: Checks generation progress
- **Polling Interval**: Every 4-5 seconds
- **Status Values**:
  - `MEDIA_GENERATION_STATUS_PENDING`: Queued
  - `MEDIA_GENERATION_STATUS_ACTIVE`: Currently generating
  - `MEDIA_GENERATION_STATUS_SUCCESSFUL`: Complete
  - `MEDIA_GENERATION_STATUS_FAILED`: Failed

#### Video Download
- **Location in Response**: `operation.metadata.video.fifeUrl`
- **URL Format**: Signed Google Storage URL
- **Example**: `https://storage.googleapis.com/ai-sandbox-videofx/video/...`
- **Method**: Standard HTTP GET request

### 3. Automation Workflow

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Connect to Chrome via CDP (port 9222)                   │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 2. Enable Network Monitoring                                │
│    - Capture API requests/responses                         │
│    - Extract operation names                                │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 3. Navigate to Project (or Create New)                     │
│    - Check current URL                                      │
│    - Click "New project" if on dashboard                   │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 4. Configure Settings (Optional)                            │
│    - Click Settings button (tune icon)                     │
│    - Set Aspect Ratio (Landscape/Portrait)                 │
│    - Set Model (Veo 3.1/2, Fast/Quality)                   │
│    - Set Number of Videos (1-4)                            │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 5. Enter Video Prompt                                       │
│    - Focus textarea (#PINHOLE_TEXT_AREA_ELEMENT_ID)        │
│    - Use CDP Input.insertText for realistic typing         │
│    - Dispatch input/change events                          │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 6. Click Generate Button                                    │
│    - Find button with arrow_forward icon                   │
│    - Verify not disabled                                    │
│    - Click to start generation                              │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 7. Monitor Completion                                       │
│    - Extract operation name from network logs               │
│    - Poll DOM for <video> element with storage URL         │
│    - Check status text for "Generating"/"Failed"           │
│    - Max wait: 300 seconds (5 minutes)                     │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 8. Download Video                                           │
│    - Extract fifeUrl from <video> element                  │
│    - HTTP GET request to download                          │
│    - Save to downloads/generated_video_<timestamp>.mp4     │
└─────────────────────────────────────────────────────────────┘
```

## Usage

### Prerequisites
1. Chrome browser running with remote debugging enabled:
   ```bash
   chrome.exe --remote-debugging-port=9222
   ```
2. Logged into https://labs.google/fx
3. Dart SDK installed

### Running the Test Script
```bash
dart test/flow_ui_automation.dart
```

### Script Behavior
- **If on Dashboard**: Creates new project → Generates video → Downloads
- **If on Project Page**: Generates video immediately → Downloads
- **Output**: Videos saved to `downloads/` directory with timestamp

### Configuration Examples

#### Example 1: Portrait Video with Quality Model
```dart
await automation.configureSettings(
  aspectRatio: AspectRatio.portrait,
  model: VeoModel.veo31Quality,
  numberOfVideos: 1,
);
await automation.generateVideo(prompt: "A sunset over mountains");
```

#### Example 2: Multiple Landscape Videos with Fast Model
```dart
await automation.configureSettings(
  aspectRatio: AspectRatio.landscape,
  model: VeoModel.veo31Fast,
  numberOfVideos: 4,
);
await automation.generateVideo(prompt: "City traffic time-lapse");
```

#### Example 3: Default Settings (No Configuration)
```dart
// Uses defaults: Landscape, Veo 3.1 Fast, 2 videos
await automation.generateVideo(prompt: "Ocean waves");
```

## Key Implementation Details

### 1. Input Method
We use CDP's `Input.insertText` instead of direct DOM manipulation because:
- Modern frameworks (React/Angular) require real input events
- Direct value assignment doesn't trigger validation
- The Generate button remains disabled without proper events

### 2. Network Monitoring
The script listens to `Network.responseReceived` events to:
- Capture the initial generation response
- Extract the operation name automatically
- Track status changes during polling

### 3. Completion Detection
Multiple strategies are used:
1. **Primary**: Check for `<video>` elements with Google Storage URLs
2. **Secondary**: Monitor status text for "Generating"/"Failed"
3. **Fallback**: Search network logs for operation status

### 4. Error Handling
- Timeout after 5 minutes of waiting
- Detects "Failed" status and aborts
- Graceful fallback if operation name not captured

## Integration with Existing Codebase

The automation logic can be integrated into `lib/services/browser_video_generator.dart`:

```dart
// Add to BrowserVideoGenerator class:
Future<String?> automateVideoGeneration(String prompt) async {
  // 1. Navigate to project or create new
  // 2. Enter prompt using Input.insertText
  // 3. Click generate button
  // 4. Poll for completion
  // 5. Return video URL
}
```

## Limitations & Considerations

1. **Selector Stability**: CSS class names may change with UI updates
2. **Rate Limiting**: Google may impose generation limits
3. **Session Management**: Requires active browser session
4. **Network Dependency**: Relies on intercepting network traffic

## Future Enhancements

1. **Direct API Polling**: Use the status check endpoint directly instead of DOM inspection
2. **Access Token Extraction**: Capture and use the bearer token for API calls
3. **Batch Processing**: Queue multiple prompts for sequential generation
4. **Progress Callbacks**: Real-time progress updates to GUI
5. **Retry Logic**: Automatic retry on transient failures

## Testing Results

✅ Successfully identifies UI elements  
✅ Clicks "New project" button  
✅ Enters prompts via CDP  
✅ Clicks "Generate" button  
✅ Monitors network traffic  
✅ Detects video completion  
✅ Downloads generated videos  

## Troubleshooting

### Generate Button Disabled
- **Cause**: Prompt not properly entered
- **Solution**: Ensure `Input.insertText` is used, not direct DOM manipulation

### Operation Name Not Captured
- **Cause**: Network monitoring started too late
- **Solution**: Enable monitoring before clicking Generate

### Video URL Not Found
- **Cause**: Page structure changed or video still generating
- **Solution**: Increase wait time or check DOM structure

### Download Fails
- **Cause**: Signed URL expired or network issue
- **Solution**: Download immediately after URL is found

---

**Created**: 2025-12-20  
**Author**: Antigravity AI  
**Version**: 1.0
