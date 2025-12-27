# iOS Path Migration Guide

## Problem
The app currently uses hardcoded Android paths like `/storage/emulated/0/veo3/` which **won't work on iOS**.

## iOS File System Structure

### Key Differences

| Platform | Base Path | Access |
|----------|-----------|--------|
| **Android** | `/storage/emulated/0/veo3/` | Public, user-accessible |
| **iOS** | `/var/mobile/.../Documents/veo3/` | Private, app-sandboxed |
| **macOS** | `~/Documents/veo3/` | Public, user-accessible |
| **Windows** | `C:/Users/{user}/Documents/veo3/` | Public, user-accessible |

### iOS Sandbox Directories

```
iOS App Container/
├── Documents/          ← Use this for user data (backed up to iCloud)
│   └── veo3/
│       ├── projects/
│       ├── videos/
│       └── reels_output/
├── Library/
│   ├── Caches/        ← Use for temporary files (not backed up)
│   └── Application Support/
└── tmp/               ← Use for temp processing (auto-deleted)
```

## Solution: Use `PlatformPaths` Utility

I've created `lib/utils/platform_paths.dart` that handles all platforms automatically.

### Files That Need Updating

Found **11 hardcoded paths** in:
1. `lib/main.dart` (3 locations)
2. `lib/services/project_service.dart` (4 locations)
3. `lib/services/story/gemini_alignment_service.dart` (1 location)
4. `lib/services/story/gemini_tts_service.dart` (1 location)
5. `lib/screens/story_audio_screen.dart` (2 locations)

### Migration Examples

#### Before (Hardcoded):
```dart
final dir = Directory('/storage/emulated/0/veo3');
```

#### After (Cross-platform):
```dart
import '../utils/platform_paths.dart';

final basePath = await PlatformPaths.getBasePath();
final dir = Directory(basePath);
```

### Specific Replacements

#### 1. Base veo3 directory
```dart
// OLD
Directory('/storage/emulated/0/veo3')

// NEW
Directory(await PlatformPaths.getBasePath())
```

#### 2. Projects directory
```dart
// OLD
'/storage/emulated/0/veo3/projects'

// NEW
await PlatformPaths.getProjectsPath()
```

#### 3. Videos export directory
```dart
// OLD
'/storage/emulated/0/veo3/videos'

// NEW
await PlatformPaths.getVideosPath()
```

#### 4. Generations directory
```dart
// OLD
'/storage/emulated/0/veo3_generations'

// NEW
await PlatformPaths.getGenerationsPath()
```

## Files to Update

### 1. `lib/main.dart`

**Line 374-375:**
```dart
// OLD
const externalPath = '/storage/emulated/0';
final veo3Dir = Directory('$externalPath/veo3_generations');

// NEW
final generationsPath = await PlatformPaths.getGenerationsPath();
final veo3Dir = Directory(generationsPath);
```

**Line 486:**
```dart
// OLD
final dir = Directory('/storage/emulated/0/veo3');

// NEW
final basePath = await PlatformPaths.getBasePath();
final dir = Directory(basePath);
```

### 2. `lib/services/project_service.dart`

**Line 131:**
```dart
// OLD
_cachedProjectsBasePath = '/storage/emulated/0/veo3/projects';

// NEW
_cachedProjectsBasePath = await PlatformPaths.getProjectsPath();
```

**Line 147:**
```dart
// OLD
_cachedDefaultExportPath = '/storage/emulated/0/veo3/videos';

// NEW
_cachedDefaultExportPath = await PlatformPaths.getVideosPath();
```

### 3. `lib/services/story/gemini_alignment_service.dart`

**Line 21:**
```dart
// OLD
final dir = Directory('/storage/emulated/0/veo3');

// NEW
final basePath = await PlatformPaths.getBasePath();
final dir = Directory(basePath);
```

### 4. `lib/services/story/gemini_tts_service.dart`

**Line 18:**
```dart
// OLD
final dir = Directory('/storage/emulated/0/veo3');

// NEW
final basePath = await PlatformPaths.getBasePath();
final dir = Directory(basePath);
```

### 5. `lib/screens/story_audio_screen.dart`

**Line 243:**
```dart
// OLD
final defaultDir = Directory('/storage/emulated/0/veo3');

// NEW
final basePath = await PlatformPaths.getBasePath();
final defaultDir = Directory(basePath);
```

**Line 1111:**
```dart
// OLD
final dir = Directory('/storage/emulated/0/veo3');

// NEW
final basePath = await PlatformPaths.getBasePath();
final dir = Directory(basePath);
```

## iOS-Specific Considerations

### 1. File Sharing
To allow users to access files via Files app on iOS, add to `Info.plist`:
```xml
<key>UIFileSharingEnabled</key>
<true/>
<key>LSSupportsOpeningDocumentsInPlace</key>
<true/>
```

### 2. iCloud Backup
Documents folder is automatically backed up to iCloud. To exclude large files:
```dart
import 'dart:io';

// Exclude from backup
final file = File(path);
await Process.run('xattr', ['-w', 'com.apple.MobileBackup', '1', path]);
```

### 3. Storage Limits
iOS apps have limited storage. Monitor usage:
```dart
import 'package:disk_space/disk_space.dart';

final freeSpace = await DiskSpace.getFreeDiskSpace;
print('Free space: ${freeSpace}MB');
```

## Testing

### Debug Path Info
Add this to your app for debugging:
```dart
import 'utils/platform_paths.dart';

// Print all paths
final pathInfo = await PlatformPaths.getPathInfo();
pathInfo.forEach((key, value) {
  print('$key: $value');
});
```

### Expected Output

**Android:**
```
platform: android
basePath: /storage/emulated/0/veo3
projectsPath: /storage/emulated/0/veo3/projects
videosPath: /storage/emulated/0/veo3/videos
```

**iOS:**
```
platform: ios
basePath: /var/mobile/Containers/Data/Application/{UUID}/Documents/veo3
projectsPath: /var/mobile/.../Documents/veo3/projects
videosPath: /var/mobile/.../Documents/veo3/videos
```

**macOS:**
```
platform: macos
basePath: /Users/{username}/Documents/veo3
projectsPath: /Users/{username}/Documents/veo3/projects
videosPath: /Users/{username}/Documents/veo3/videos
```

## Next Steps

1. **Import the utility** in all files that use hardcoded paths
2. **Replace hardcoded strings** with `await PlatformPaths.getXXX()`
3. **Test on Android** to ensure nothing broke
4. **Build iOS** and test file access

Would you like me to automatically update all these files with the cross-platform paths?
