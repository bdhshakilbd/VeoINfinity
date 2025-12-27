# iOS Build - Quick Start Script

## ⚠️ IMPORTANT: iOS folder not found!

Your project doesn't have an `ios/` folder yet. This is normal for a new Flutter project.

## 🔧 Fix: Create iOS Project Files

Run this command in your project directory:

```bash
cd h:\gravityapps\veo3_another
flutter create --platforms=ios,macos .
```

This will:
- ✅ Create `ios/` folder
- ✅ Create `macos/` folder  
- ✅ Generate all necessary iOS/macOS files
- ✅ NOT overwrite your existing code

## ⏱️ Time: ~2 minutes

---

## Then Follow These Steps:

### 1. Create iOS/macOS folders
```bash
flutter create --platforms=ios,macos .
```

### 2. Update Bundle ID
Edit `codemagic.yaml`:
```yaml
BUNDLE_ID: "com.yourname.veo3"  # Change this!
```

### 3. Add iOS Permissions
Edit `ios/Runner/Info.plist` (will exist after step 1):

Add before `</dict>`:
```xml
<key>NSCameraUsageDescription</key>
<string>This app needs camera access</string>
<key>NSMicrophoneUsageDescription</key>
<string>This app needs microphone access</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>This app needs photo library access</string>
<key>UIFileSharingEnabled</key>
<true/>
<key>LSSupportsOpeningDocumentsInPlace</key>
<true/>
```

### 4. Push to GitHub
```bash
git add .
git commit -m "Add iOS/macOS support"
git push
```

### 5. Build on Codemagic
1. Go to https://codemagic.io
2. Sign up with GitHub
3. Select your repo
4. Choose `ios-workflow`
5. Click "Start build"
6. Wait ~15 minutes
7. Download `Runner.app`

---

## 📋 Full Checklist

- [ ] Run `flutter create --platforms=ios,macos .`
- [ ] Update `BUNDLE_ID` in `codemagic.yaml`
- [ ] Update email in `codemagic.yaml`
- [ ] Add permissions to `ios/Runner/Info.plist`
- [ ] Commit: `git add . && git commit -m "iOS support"`
- [ ] Push: `git push`
- [ ] Sign up: https://codemagic.io
- [ ] Start build
- [ ] Download app

---

## 🚀 One-Command Setup

```bash
# Run all at once:
cd h:\gravityapps\veo3_another
flutter create --platforms=ios,macos .
echo "iOS and macOS folders created!"
echo "Now edit codemagic.yaml and ios/Runner/Info.plist"
```

---

## ⏭️ After iOS Folder Created

See `BUILD_IOS_NOW.md` for detailed build instructions.

---

## 💡 Why No iOS Folder?

Flutter projects don't include iOS/macOS folders by default on Windows.
You must explicitly create them with `flutter create --platforms=ios,macos .`

This is normal and safe! ✅
