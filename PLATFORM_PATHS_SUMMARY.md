# Platform Paths Summary

## All Supported Platforms

| Platform | Base Path | User Accessible? | Notes |
|----------|-----------|------------------|-------|
| **Android** | `/storage/emulated/0/veo3/` | ✅ Yes | Via file manager |
| **iOS** | `{App}/Documents/veo3/` | ⚠️ Limited | Via Files app (if enabled) |
| **macOS** | `~/Documents/veo3/` | ✅ Yes | Finder accessible |
| **Windows** | `{Documents}/veo3/` | ✅ Yes | Explorer accessible |
| **Linux** | `{Documents}/veo3/` | ✅ Yes | File manager accessible |

## Key Differences

### iOS vs macOS
- **iOS**: App-sandboxed, isolated storage
  - Path: `/var/mobile/Containers/Data/Application/{UUID}/Documents/veo3/`
  - Backed up to iCloud automatically
  - Requires `UIFileSharingEnabled` for user access

- **macOS**: User-accessible Documents folder
  - Path: `/Users/{username}/Documents/veo3/`
  - Same as Windows behavior
  - Directly accessible in Finder

### Why Different?
- **iOS**: Security model requires app sandboxing
- **macOS**: Desktop OS, users expect file access
- **Android**: Public storage for user convenience
- **Windows**: Standard Documents folder

## Usage

```dart
import 'utils/platform_paths.dart';

// Works on ALL platforms automatically
final basePath = await PlatformPaths.getBasePath();
final projectsPath = await PlatformPaths.getProjectsPath();
final videosPath = await PlatformPaths.getVideosPath();

print('Base: $basePath');
// Android: /storage/emulated/0/veo3
// iOS: /var/mobile/.../Documents/veo3
// macOS: /Users/john/Documents/veo3
// Windows: C:/Users/john/Documents/veo3
```

## File Access by Platform

### Android
```bash
# Via ADB
adb shell ls /storage/emulated/0/veo3/

# Via File Manager
Open "Files" app → Internal Storage → veo3
```

### iOS
```bash
# Via Xcode
Window → Devices and Simulators → Select device → Download Container

# Via Files App (requires Info.plist config)
Files app → On My iPhone → {App Name} → veo3
```

### macOS
```bash
# Via Finder
open ~/Documents/veo3

# Via Terminal
ls ~/Documents/veo3
```

### Windows
```bash
# Via Explorer
explorer %USERPROFILE%\Documents\veo3

# Via Command Prompt
dir %USERPROFILE%\Documents\veo3
```

## Building for Each Platform

### Android ✅ (Working)
```bash
flutter build apk --release
```

### iOS 📱 (Needs Codemagic)
```bash
# See IOS_BUILD_GUIDE.md
# Use Codemagic or GitHub Actions
```

### macOS 🖥️ (Easy)
```bash
flutter build macos --release
```

### Windows 💻 (Working)
```bash
flutter build windows --release
```

## Next Steps

1. ✅ **Created**: `lib/utils/platform_paths.dart`
2. ⏳ **TODO**: Replace 11 hardcoded paths
3. ⏳ **TODO**: Test on Android (ensure nothing broke)
4. ⏳ **TODO**: Build iOS via Codemagic
5. ⏳ **TODO**: Test macOS build

**Ready to update all hardcoded paths?** Just say "yes"!
