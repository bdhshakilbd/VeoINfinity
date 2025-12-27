# Device ID Support Across Platforms

## Summary

✅ **All platforms now supported!**

| Platform | ID Type | Format | Example |
|----------|---------|--------|---------|
| **Windows** | MAC Address | `AA-BB-CC-DD-EE-FF` | `A1-B2-C3-D4-E5-F6` |
| **Android** | Fingerprint Hash | 16-char hex | `a1b2c3d4e5f6g7h8` |
| **iOS** | Vendor ID | UUID | `12345678-ABCD-1234-ABCD-123456789ABC` |
| **macOS** | System GUID | UUID | `12345678-ABCD-1234-ABCD-123456789ABC` |

## What Shows in "Device ID" Box

### Windows:
```
Device ID: A1-B2-C3-D4-E5-F6
Status: ✅ Authorized (if whitelisted)
```

### Android:
```
Device ID: a1b2c3d4e5f6g7h8
Status: ✅ Authorized (if whitelisted)
```

### iOS:
```
Device ID: 12345678-ABCD-1234-ABCD-123456789ABC
Status: ✅ Authorized (if whitelisted)
```

### macOS:
```
Device ID: 87654321-DCBA-4321-DCBA-CBA987654321
Status: ✅ Authorized (if whitelisted)
```

## How It Works

### 1. **Windows** (MAC Address)
```dart
// Runs: getmac command
// Gets: Physical network adapter MAC
// Format: AA-BB-CC-DD-EE-FF
// Whitelist: First 5 segments (AA-BB-CC-DD-EE)
```

### 2. **Android** (Fingerprint Hash)
```dart
// Gets: androidInfo.fingerprint
// Example: "google/sdk_gphone64_arm64/emu64a:13/TE1A.220922.034/10940250:userdebug/dev-keys"
// Converts to: 16-char hex hash
// Whitelist: Exact match (lowercase)
```

### 3. **iOS** (Vendor Identifier)
```dart
// Gets: iosInfo.identifierForVendor
// Format: UUID (unique per app vendor)
// Changes: If app reinstalled + all vendor apps deleted
// Whitelist: Exact match
```

### 4. **macOS** (System GUID)
```dart
// Gets: macInfo.systemGUID
// Format: UUID (unique per Mac)
// Persistent: Survives app reinstall
// Whitelist: Exact match
```

## Whitelist Format

Your `veo3_infinity.txt` file should contain:

```
# Windows MAC addresses (first 5 segments)
A1-B2-C3-D4-E5

# Android device IDs (16-char hex)
a1b2c3d4e5f6g7h8

# iOS device IDs (UUID)
12345678-ABCD-1234-ABCD-123456789ABC

# macOS device IDs (UUID)
87654321-DCBA-4321-DCBA-CBA987654321

# Comments start with #
```

## Getting Device IDs

### Windows:
```bash
# Run in app, check console output
# Or run: getmac
```

### Android:
```bash
# Run app, check console for:
# [AUTH] Android simple ID (for whitelist): "a1b2c3d4e5f6g7h8"
```

### iOS:
```bash
# Run app, check console for:
# [AUTH] iOS identifier: "12345678-ABCD-1234-ABCD-123456789ABC"
```

### macOS:
```bash
# Run app, check console for:
# [AUTH] macOS system GUID: "87654321-DCBA-4321-DCBA-CBA987654321"
```

## Important Notes

### iOS `identifierForVendor`:
- ✅ Unique per device + vendor
- ✅ Persists across app updates
- ⚠️ Changes if ALL apps from vendor are deleted
- ⚠️ Changes if device is reset

### macOS `systemGUID`:
- ✅ Unique per Mac
- ✅ Persists across app reinstalls
- ✅ Persists across OS updates
- ⚠️ Changes if macOS is reinstalled

### Android Fingerprint:
- ✅ Unique per device
- ✅ Persists across app reinstalls
- ⚠️ Changes if ROM is changed
- ⚠️ Changes if device is factory reset

### Windows MAC:
- ✅ Unique per network adapter
- ✅ Very stable
- ⚠️ Changes if network adapter is replaced
- ⚠️ Can be spoofed (rare)

## Testing

### 1. **Get Device ID**
Run app on each platform and check console:
```
[AUTH] Android simple ID (for whitelist): "a1b2c3d4e5f6g7h8"
[AUTH] iOS identifier: "12345678-ABCD-1234-ABCD-123456789ABC"
[AUTH] macOS system GUID: "87654321-DCBA-4321-DCBA-CBA987654321"
```

### 2. **Add to Whitelist**
Copy the ID to your `veo3_infinity.txt` file on Dropbox.

### 3. **Test Authorization**
Restart app, should show:
```
Status: ✅ Authorized
Device ID: [your-device-id]
```

## Error Messages

| Message | Meaning | Solution |
|---------|---------|----------|
| `NO_INTERNET_CONNECTION` | No internet | Check WiFi/cellular |
| `AUTHORIZATION_SERVER_ERROR` | Can't fetch whitelist | Check Dropbox link |
| `⚠️ This device is not registered` | ID not in whitelist | Add device ID to whitelist |
| `No ID Found` | Can't get device ID | Check permissions |

## Privacy & Security

### What's Collected:
- ✅ Device identifier only
- ❌ No personal information
- ❌ No location data
- ❌ No user data

### How It's Used:
- ✅ License verification only
- ✅ Stored in Dropbox whitelist
- ❌ Not shared with third parties
- ❌ Not used for tracking

## Summary

| Platform | Status | ID Format | Stable? |
|----------|--------|-----------|---------|
| Windows | ✅ Working | MAC Address | ✅ Very |
| Android | ✅ Working | Hex Hash | ✅ Yes |
| iOS | ✅ Working | UUID | ⚠️ Mostly |
| macOS | ✅ **NEW** | UUID | ✅ Yes |

**All platforms now show device ID in the project card!** 🎉
