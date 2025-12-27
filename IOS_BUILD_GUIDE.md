# iOS Build Setup with Codemagic (No Mac Required)

## Prerequisites
1. **Apple Developer Account** ($99/year) - Required for App Store distribution
2. **GitHub/GitLab/Bitbucket account** - To host your code
3. **Codemagic account** - Free tier available

## Step-by-Step Setup

### 1. Update Bundle ID
Edit `ios/Runner.xcodeproj/project.pbxproj` and `ios/Runner/Info.plist`:
- Change `PRODUCT_BUNDLE_IDENTIFIER` to your unique ID (e.g., `com.yourcompany.veo3another`)
- Update in `codemagic.yaml` as well

### 2. Push Code to Git Repository
```bash
git init
git add .
git commit -m "Initial commit"
git remote add origin https://github.com/yourusername/veo3_another.git
git push -u origin main
```

### 3. Sign Up for Codemagic
1. Go to https://codemagic.io/signup
2. Sign up with your Git provider (GitHub/GitLab/Bitbucket)
3. Free tier includes: 500 build minutes/month

### 4. Connect Your Repository
1. Click "Add application"
2. Select your repository
3. Codemagic will auto-detect Flutter project

### 5. Configure Build
1. Select "Start your first build"
2. Choose "iOS" platform
3. Select the workflow from `codemagic.yaml`
4. Click "Start new build"

### 6. Build Without Code Signing (Testing)
The current config builds **unsigned** iOS app:
- Good for: Testing, development
- **Cannot install on real devices** without jailbreak
- **Cannot publish to App Store**

To test unsigned build:
- Download the `.app` file from artifacts
- Use iOS Simulator on a Mac (or cloud Mac)

### 7. Build WITH Code Signing (App Store)

#### A. Generate Certificates (Requires Mac or Cloud Mac)
You'll need:
- **iOS Distribution Certificate** (.p12 file)
- **Provisioning Profile** (.mobileprovision file)

**Option 1: Use Codemagic's Mac**
1. In Codemagic, go to "Code signing identities"
2. Use "Automatic code signing" (Codemagic will generate for you)

**Option 2: Use MacInCloud ($30/month)**
1. Rent a Mac from https://www.macincloud.com/
2. Open Xcode
3. Go to Preferences → Accounts → Add Apple ID
4. Xcode will generate certificates automatically

#### B. Upload to Codemagic
1. In Codemagic project settings → "Code signing identities"
2. Upload:
   - Distribution certificate (.p12)
   - Provisioning profile (.mobileprovision)
   - Certificate password

#### C. Update codemagic.yaml
Uncomment the signed build section:
```yaml
- name: Build signed iOS app
  script: |
    flutter build ipa --release \
      --export-options-plist=/Users/builder/export_options.plist
```

### 8. Publish to App Store
Uncomment the `app_store_connect` section in `codemagic.yaml`:
```yaml
publishing:
  app_store_connect:
    api_key: $APP_STORE_CONNECT_PRIVATE_KEY
    key_id: $APP_STORE_CONNECT_KEY_IDENTIFIER
    issuer_id: $APP_STORE_CONNECT_ISSUER_ID
```

Get App Store Connect API keys:
1. Go to https://appstoreconnect.apple.com/
2. Users and Access → Keys → App Store Connect API
3. Generate new key
4. Download the `.p8` file
5. Add to Codemagic environment variables

## Quick Start (Unsigned Build)

1. **Update `codemagic.yaml`:**
   - Change `BUNDLE_ID` to your bundle ID
   - Change email to your email

2. **Push to Git:**
   ```bash
   git add codemagic.yaml
   git commit -m "Add Codemagic config"
   git push
   ```

3. **Build on Codemagic:**
   - Go to Codemagic dashboard
   - Click "Start new build"
   - Wait 10-15 minutes
   - Download `.app` file from artifacts

## Alternative: GitHub Actions (Free)

If you prefer GitHub Actions, I can create that config instead.
It's completely free (2000 minutes/month) but requires more manual setup.

## Troubleshooting

### Build fails with "Pod install failed"
- Check `ios/Podfile` exists
- Ensure all dependencies support iOS

### "No valid code signing identity"
- You're trying to build signed without certificates
- Use unsigned build first, or add certificates

### "Bundle ID already exists"
- Change `BUNDLE_ID` in `codemagic.yaml`
- Update in Xcode project settings

## Cost Breakdown

| Service | Cost | Purpose |
|---------|------|---------|
| Codemagic Free | $0 | 500 build mins/month |
| Apple Developer | $99/year | Required for App Store |
| MacInCloud (optional) | $30/month | Generate certificates |

**Minimum cost: $99/year** (just Apple Developer account)

## Next Steps

1. Update bundle ID in `codemagic.yaml`
2. Push code to GitHub
3. Sign up for Codemagic
4. Start your first build!

Need help with any step? Let me know!
