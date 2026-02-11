# VEO3 Infinity

<div align="center">

![VEO3 Infinity](assets/app_icon.png)

**Professional AI Video Generation Tool**

[![Flutter](https://img.shields.io/badge/Flutter-3.8+-02569B?logo=flutter)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/Platform-Windows%20|%20macOS%20|%20Android%20|%20iOS-blue)]()
[![Version](https://img.shields.io/badge/Version-3.5.0-green)]()

</div>

## 🎬 Features

### Core Features
- 🖼️ **Character Studio** - Create consistent character images with AI
- 🎥 **Image-to-Video** - Convert images to videos with Google's Veo 3.1
- 📝 **Text-to-Video** - Generate videos directly from text prompts
- 🎨 **Style Transfer** - Apply custom styles to generated images
- 🎭 **Multi-Character Support** - Manage multiple characters in scenes

### Advanced Features
- 🌐 **Multi-Browser Support** - Parallel generation with multiple Chrome instances
- 🔄 **Auto-Retry Logic** - Intelligent error handling and recovery
- 📦 **Batch Processing** - Generate multiple videos simultaneously
- 💾 **Project Management** - Save and load complex video projects
- 🎯 **Reference Images** - Use subject references for consistent characters

### Platform Support
- ✅ **Windows** - Full desktop experience
- ✅ **macOS** - Native Apple Silicon & Intel support
- ✅ **Android** - Mobile generation on-the-go
- ✅ **iOS** - Coming soon

## 📋 Requirements

### Desktop
- **Windows**: Windows 10+ (x64)
- **macOS**: macOS 10.15+ (Intel/Apple Silicon)
- **RAM**: 4GB minimum, 8GB recommended
- **Storage**: 500MB for app, additional space for generated videos

### Mobile
- **Android**: Android 7.0+ (API 24+)
- **iOS**: iOS 12.0+

## 🚀 Installation

### Windows
1. Download `VEO3_Infinity_Setup_3.5.0.exe` from [Releases](https://github.com/bdhshakilbd/VeoINfinity/releases)
2. Run the installer
3. Launch VEO3 Infinity

### macOS
Build from source using Codemagic or:
```bash
flutter build macos --release
```

### Android
```bash
flutter build apk --release
```

## 🛠️ Building from Source

### Prerequisites
```bash
# Install Flutter 3.8+
flutter --version

# Get dependencies
flutter pub get
```

### Platform-Specific Setup

#### Windows
```bash
# Build Windows executable
flutter build windows --release

# Create installer (requires Inno Setup)
iscc setup.iss
```

#### macOS
```bash
# Build for macOS
flutter build macos --release

# Create DMG (optional)
create-dmg build/macos/Build/Products/Release/veo3_another.app
```

#### Android
```bash
# Build APK
flutter build apk --release

# Or build App Bundle for Play Store
flutter build appbundle --release
```

## 📖 Usage

### Character Studio
1. Open **Character Studio** tab
2. Click **Detect Characters** to analyze your story
3. Generate character images with customizable styles
4. Use generated characters in video scenes

### Video Generation
1. Select **Images** or **Video** tab
2. Choose AI model (Veo 3.1, Imagen 3.5, etc.)
3. Upload first frame or write text prompt
4. Click **Generate Video**
5. Monitor progress and download completed videos

### Multi-Browser Mode
1. Click **Open Browsers** (specify count)
2. Log into Google Labs in each browser
3. Click **Connect** to link browsers
4. Start generation - work is distributed automatically

## 🔧 Configuration

### API Keys (Optional)
For enhanced features, add API keys in:
- `gemini_api_keys.txt` - For Gemini Pro features
- Settings → Configure credentials for Google Labs

### Project Settings
- Output folder
- Default aspect ratio
- Browser count
- Retry limits

## 🎨 Technologies

- **Framework**: Flutter 3.8+
- **Video Player**: media_kit
- **Browser Automation**: Chrome DevTools Protocol
- **AI Models**: Google Veo 3.1, Imagen 3.5, Gemini Pro
- **State Management**: Native Flutter setState
- **Desktop UI**: Custom responsive layout

## 📝 License

This project is proprietary software. Redistribution or commercial use requires written permission.

## 🤝 Contributing

This is a private project. For collaboration inquiries, please contact the maintainer.

## 📞 Support

For issues or questions:
- Open an issue on GitHub
- Contact: [Your Email/Discord]

## 🎯 Roadmap

- [x] Windows desktop support
- [x] Android mobile support
- [ ] macOS native build
- [ ] iOS support
- [ ] Cloud rendering backend
- [ ] AI voice generation
- [ ] Real-time collaboration

## ⚠️ Disclaimer

This tool interfaces with Google's AI services. You must have a valid Google account and comply with Google's Terms of Service. The developers are not responsible for any misuse or violations.

---

<div align="center">

**Made with ❤️ by the VEO3 Infinity Team**

⭐ Star this repo if you find it useful!

</div>
