# Batch Generation Improvements Plan

## Requirements

### 1. Auto-Connect Browsers on Start
When clicking "Start" on home screen for batch generation:
- If browsers not connected, try to connect to available profiles blindly (9222, 9223, etc.)
- Number of profiles to try should match settings
- Generate even if some browsers fail to connect

### 2. Auto-Navigate to Flow URL and Retry Token
- If browser connected but token fetch fails:
  - Navigate to https://labs.google/fx/tools/flow
  - Try to fetch token again
  - If still fails: Stop generation and show notification "Flow URL is not opened or session expired"

### 3. Clean Up Logs
- Remove recaptcha-related log lines from dedicated logs viewer
- Just show "retrying video" and "generating video"
- Remove verbiage about recaptcha token generation
- Overall reduce junk logs

## Implementation Tasks

### Task 1: Auto-Connect in startBatch()
**File**: `lib/services/video_generation_service.dart`
**Method**: `startBatch()`
**Changes**:
1. Before starting generation, check if any browsers are connected
2. If not connected, call `_autoConnectBrowsers()`
3. Try to connect to ports 9222, 9223, ... based on settings profile count
4. Use `ProfileManagerService.connectToProfile()` or similar logic

### Task 2: Auto-Navigate & Retry Token
**File**: `lib/services/video_generation_service.dart`
**Method**: New method `_ensureTokenAvailable(account)`
**Changes**:
1. When getting account from pool, check if token is available
2. If not, try navigating to Flow URL
3. Wait a few seconds and retry token fetch
4. If still fails, show notification and return null

### Task 3: Clean Logs
**File**: `lib/services/video_generation_service.dart`
**Method**: `_log()` and related logging
**Changes**:
1. Filter out recaptcha-related messages
2. Simplify retry messages to just "Retrying video [X/10]..."
3. Simplify generation messages to just "[GENERATE] Scene X..."

## Files to Modify

1. `lib/services/video_generation_service.dart` - Main service
2. `lib/main.dart` - Home screen start button (line ~2644)
3. Potentially `lib/services/profile_manager_service.dart` - Blind connect logic

## Code Locations

### Start Button
- `lib/main.dart` line 2644: `_startGeneration()`
- Calls `VideoGenerationService().startBatch()`

### Video Generation Service
- `lib/services/video_generation_service.dart`
- `startBatch()` - line 246
- `_getAvailableAccount()` - needs token check
- `_log()` - needs filtering

### Profile Connection
- `lib/services/profile_manager_service.dart`
- `connectToProfile()` - line 159
- Can be used for blind connection attempts

## Testing Checklist

- [ ] Start generation with no browsers connected
- [ ] Verify auto-connect attempts on 9222, 9223, etc.
- [ ] Start generation with browser connected but no token
- [ ] Verify navigation to Flow URL
- [ ] Verify retry token fetch
- [ ] Verify notification if token still fails
- [ ] Check logs viewer for reduced recaptcha noise
- [ ] Check logs viewer for simplified messages
