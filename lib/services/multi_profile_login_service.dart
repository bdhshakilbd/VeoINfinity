import 'dart:async';
import 'dart:math';
import 'package:path/path.dart' as path;
import 'profile_manager_service.dart';
import 'browser_video_generator.dart';

/// Service for automated multi-profile Google OAuth login
class MultiProfileLoginService {
  final ProfileManagerService profileManager;
  final Random _random = Random();

  MultiProfileLoginService({required this.profileManager});

  /// Perform automated Google OAuth login for a single profile
  /// Returns true if login successful and token verified
  Future<bool> autoLogin({
    required ChromeProfile profile,
    required String email,
    required String password,
    int maxAttempts = 3,
  }) async {
    print('\n${'=' * 60}');
    print('[AutoLogin] ${profile.name} - Starting login for $email');
    print('=' * 60);

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (attempt > 1) {
        print('[AutoLogin] ${profile.name} - Retry attempt $attempt/$maxAttempts');
      }

      try {
        // Step 1: Clear browser data
        await _clearBrowserData(profile);

        // Step 2: Navigate to Flow
        await _navigateToFlow(profile);

        // Step 3: Wait for page load
        await Future.delayed(Duration(seconds: 3));

        // Step 4: Click "Create with Flow" button
        final clickedButton = await _clickCreateWithFlow(profile);
        if (!clickedButton) {
          print('[AutoLogin] ${profile.name} - Create button not found');
          if (attempt < maxAttempts) {
            await Future.delayed(Duration(seconds: 5));
            continue;
          }
          return false;
        }

        // Step 5: Wait for Google OAuth redirect
        await Future.delayed(Duration(seconds: 4));

        // Step 6: Check if on Google OAuth page
        final onOAuthPage = await _waitForGoogleOAuth(profile);
        if (!onOAuthPage) {
          // Might already be logged in
          print('[AutoLogin] ${profile.name} - Not on OAuth page, checking if already logged in');
          final token = await _verifyLoginWithRetry(profile);
          if (token != null) {
            profile.accessToken = token;
            profile.status = ProfileStatus.connected;
            print('[AutoLogin] ${profile.name} - ✓ Already logged in!');
            return true;
          }
          if (attempt < maxAttempts) continue;
          return false;
        }

        // Step 7: Wait for page to fully load
        print('[AutoLogin] ${profile.name} - Waiting for email page to load...');
        await _waitForPageLoad(profile);
        await Future.delayed(Duration(seconds: 3));

        // Step 8: Wait for email input field to be ready
        final emailFieldReady = await _waitForEmailField(profile);
        if (!emailFieldReady) {
          print('[AutoLogin] ${profile.name} - Email field not found');
          if (attempt < maxAttempts) continue;
          return false;
        }

        // Step 9: Enter email
        await _enterEmail(profile, email);
        await Future.delayed(Duration(seconds: 2));

        // Step 10: Click Next (email)
        await _clickNextEmail(profile);

        // Step 11: Wait for password page to load
        print('[AutoLogin] ${profile.name} - Waiting for password page to load...');
        await Future.delayed(Duration(seconds: 6));
        await _waitForPageLoad(profile);

        // Step 12: Enter password (no field detection, just try)
        await _enterPassword(profile, password);
        await Future.delayed(Duration(seconds: 2));

        // Step 13: Click Next (password)
        await _clickNextPassword(profile);

        // Step 15: Wait for redirect back to Flow
        print('[AutoLogin] ${profile.name} - Waiting for redirect to Flow...');
        await Future.delayed(Duration(seconds: 3));
        final redirected = await _waitForFlowRedirect(profile);
        if (!redirected) {
          print('[AutoLogin] ${profile.name} - Redirect timeout');
          if (attempt < maxAttempts) {
            await Future.delayed(Duration(seconds: 5));
            continue;
          }
          return false;
        }

        // Step 16: Verify login with token (3 attempts, 15s intervals)
        print('[AutoLogin] ${profile.name} - Verifying login (3 attempts, 15s intervals)...');
        final token = await _verifyLoginWithRetry(profile);

        if (token != null) {
          profile.accessToken = token;
          profile.status = ProfileStatus.connected;
          profile.consecutive403Count = 0;
          print('[AutoLogin] ${profile.name} - ✓ Login successful! Token: ${token.substring(0, 30)}...');
          return true;
        } else {
          print('[AutoLogin] ${profile.name} - ✗ Token verification failed');
          if (attempt < maxAttempts) {
            await Future.delayed(Duration(seconds: 5));
            continue;
          }
        }
      } catch (e) {
        print('[AutoLogin] ${profile.name} - Error on attempt $attempt: $e');
        if (attempt < maxAttempts) {
          await Future.delayed(Duration(seconds: 5));
          continue;
        }
      }
    }

    print('[AutoLogin] ${profile.name} - ✗ Login failed after $maxAttempts attempts');
    profile.status = ProfileStatus.error;
    return false;
  }

  /// Relogin a single profile after 403 errors
  Future<void> reloginProfile(
    ChromeProfile profile,
    String email,
    String password,
  ) async {
    print('\n[Relogin] ${profile.name} - Too many 403 errors, relogging...');
    profile.status = ProfileStatus.relogging;
    profile.consecutive403Count = 0;

    final success = await autoLogin(
      profile: profile,
      email: email,
      password: password,
      maxAttempts: 3,
    );

    if (success) {
      print('[Relogin] ${profile.name} - ✓ Relogin successful');
    } else {
      print('[Relogin] ${profile.name} - ✗ Relogin failed, will retry in 60s...');
      // Don't mark as error - keep as disconnected so it can be retried
      profile.status = ProfileStatus.disconnected;
      
      // Schedule another relogin attempt after delay
      Future.delayed(Duration(seconds: 60), () {
        if (profile.status == ProfileStatus.disconnected) {
          print('[Relogin] ${profile.name} - Retrying relogin...');
          reloginProfile(profile, email, password);
        }
      });
    }
  }

  /// Login all profiles in sequence
  Future<void> loginAllProfiles(
    int count,
    String email,
    String password,
  ) async {
    print('\n${'=' * 60}');
    print('MULTI-PROFILE LOGIN - Launching $count profiles');
    print('=' * 60);

    // Initialize profiles
    await profileManager.initializeProfiles(count);

    int successCount = 0;

    for (var i = 0; i < profileManager.profiles.length; i++) {
      final profile = profileManager.profiles[i];

      print('\n[Profile ${i + 1}/$count] Setting up ${profile.name}...');

      // Launch Chrome
      final launched = await profileManager.launchProfile(profile);
      if (!launched) {
        print('[Profile ${i + 1}/$count] ✗ Failed to launch Chrome');
        continue;
      }

      // Connect to Chrome (without waiting for token)
      final connected = await profileManager.connectToProfileWithoutToken(profile);
      if (!connected) {
        print('[Profile ${i + 1}/$count] ✗ Failed to connect to Chrome');
        continue;
      }

      // Perform auto-login (this will get the token)
      print('[Profile ${i + 1}/$count] Performing auto-login...');
      final loginSuccess = await autoLogin(
        profile: profile,
        email: email,
        password: password,
      );

      if (loginSuccess) {
        successCount++;
      }

      // Small delay between profiles
      await Future.delayed(Duration(seconds: 2));
    }

    print('\n${'=' * 60}');
    print('MULTI-PROFILE LOGIN COMPLETE - $successCount/$count connected');
    print('=' * 60);
  }

  // ========== HELPER METHODS ==========

  Future<void> _clearBrowserData(ChromeProfile profile) async {
    try {
      print('[AutoLogin] ${profile.name} - Clearing browser data...');
      
      if (profile.generator == null) {
        final gen = BrowserVideoGenerator(debugPort: profile.debugPort);
        await gen.connect();
        profile.generator = gen;
      }

      await profile.generator!.sendCommand('Network.enable');
      await profile.generator!.sendCommand('Storage.enable');
      await profile.generator!.sendCommand('Network.clearBrowserCache');
      await profile.generator!.sendCommand('Network.clearBrowserCookies');
      await profile.generator!.sendCommand('Storage.clearDataForOrigin', {
        'origin': '*',
        'storageTypes': 'all',
      });

      // Clear via JavaScript too
      await profile.generator!.executeJs('''
        (function() {
          try {
            localStorage.clear();
            sessionStorage.clear();
          } catch(e) {}
        })();
      ''');

      print('[AutoLogin] ${profile.name} - ✓ Browser data cleared');
    } catch (e) {
      print('[AutoLogin] ${profile.name} - Warning: Error clearing data: $e');
    }
  }

  Future<void> _navigateToFlow(ChromeProfile profile) async {
    print('[AutoLogin] ${profile.name} - Navigating to Flow...');
    await profile.generator!.executeJs("window.location.href = 'https://labs.google/fx/tools/flow'");
    await Future.delayed(Duration(seconds: 5));
  }

  Future<bool> _clickCreateWithFlow(ChromeProfile profile) async {
    print('[AutoLogin] ${profile.name} - Looking for "Create with Flow" button...');

    for (var i = 0; i < 15; i++) {
      try {
        final clicked = await profile.generator!.executeJs('''
          (async function() {
            const buttons = Array.from(document.querySelectorAll('button, div[role="button"], a'));
            const createBtn = buttons.find(b => 
              b.innerText && b.innerText.includes('Create with Flow')
            );
            if (createBtn) {
              createBtn.scrollIntoView({block: "center"});
              await new Promise(r => setTimeout(r, 1000));
              createBtn.click();
              return true;
            }
            return false;
          })()
        ''');

        if (clicked == true) {
          print('[AutoLogin] ${profile.name} - ✓ Clicked "Create with Flow"');
          return true;
        }

        await Future.delayed(Duration(seconds: 2));
      } catch (e) {
        print('[AutoLogin] ${profile.name} - Error clicking button: $e');
      }
    }

    return false;
  }

  Future<bool> _waitForGoogleOAuth(ChromeProfile profile, {int maxSeconds = 15}) async {
    for (var i = 0; i < maxSeconds; i++) {
      try {
        final url = await profile.generator!.getCurrentUrl();
        if (url.contains('accounts.google.com')) {
          print('[AutoLogin] ${profile.name} - ✓ On Google OAuth page');
          return true;
        }
      } catch (e) {}
      await Future.delayed(Duration(seconds: 1));
    }
    return false;
  }

  Future<bool> _waitForPageLoad(ChromeProfile profile, {int maxSeconds = 10}) async {
    for (var i = 0; i < maxSeconds; i++) {
      try {
        final ready = await profile.generator!.executeJs('''
          (function() {
            return document.readyState === 'complete';
          })()
        ''');
        if (ready == true) {
          print('[AutoLogin] ${profile.name} - ✓ Page loaded');
          return true;
        }
      } catch (e) {}
      await Future.delayed(Duration(seconds: 2));
    }
    return false;
  }

  Future<bool> _waitForEmailField(ChromeProfile profile, {int maxSeconds = 15}) async {
    print('[AutoLogin] ${profile.name} - Waiting for email input field...');
    for (var i = 0; i < maxSeconds; i++) {
      try {
        final found = await profile.generator!.executeJs('''
          (function() {
            const input = document.getElementById('identifierId');
            return input !== null && input.offsetParent !== null;
          })()
        ''');
        if (found == true) {
          print('[AutoLogin] ${profile.name} - ✓ Email field ready');
          return true;
        }
      } catch (e) {}
      await Future.delayed(Duration(seconds: 1));
    }
    return false;
  }

  Future<bool> _waitForPasswordField(ChromeProfile profile, {int maxSeconds = 15}) async {
    print('[AutoLogin] ${profile.name} - Waiting for password input field...');
    for (var i = 0; i < maxSeconds; i++) {
      try {
        final found = await profile.generator!.executeJs('''
          (function() {
            const input = document.querySelector('input[name="Passwd"]');
            return input !== null && input.offsetParent !== null;
          })()
        ''');
        if (found == true) {
          print('[AutoLogin] ${profile.name} - ✓ Password field ready');
          return true;
        }
      } catch (e) {}
      await Future.delayed(Duration(seconds: 1));
    }
    return false;
  }

  Future<void> _enterEmail(ChromeProfile profile, String email) async {
    print('[AutoLogin] ${profile.name} - Entering email...');
    await profile.generator!.executeJs('''
      (async function() {
        const input = document.getElementById('identifierId');
        if (input) {
          input.focus();
          await new Promise(r => setTimeout(r, 500));
          input.value = '$email';
          input.dispatchEvent(new Event('input', { bubbles: true }));
          await new Promise(r => setTimeout(r, 500));
        }
      })()
    ''');
  }

  Future<void> _clickNextEmail(ChromeProfile profile) async {
    print('[AutoLogin] ${profile.name} - Clicking Next (email)...');
    await profile.generator!.executeJs('''
      (async function() {
        const btn = document.getElementById('identifierNext');
        if (btn) {
          btn.scrollIntoView({block: "center"});
          await new Promise(r => setTimeout(r, 500));
          btn.click();
        }
      })()
    ''');
  }

  Future<void> _enterPassword(ChromeProfile profile, String password) async {
    print('[AutoLogin] ${profile.name} - Entering password...');
    await profile.generator!.executeJs('''
      (async function() {
        const input = document.querySelector('input[name="Passwd"]');
        if (input) {
          input.focus();
          await new Promise(r => setTimeout(r, 500));
          input.value = '$password';
          input.dispatchEvent(new Event('input', { bubbles: true }));
          await new Promise(r => setTimeout(r, 500));
        }
      })()
    ''');
  }

  Future<void> _clickNextPassword(ChromeProfile profile) async {
    print('[AutoLogin] ${profile.name} - Clicking Next (password)...');
    await profile.generator!.executeJs('''
      (async function() {
        const btn = document.querySelector('#passwordNext');
        if (btn) {
          btn.scrollIntoView({block: "center"});
          await new Promise(r => setTimeout(r, 500));
          btn.click();
        }
      })()
    ''');
  }

  Future<bool> _waitForFlowRedirect(ChromeProfile profile, {int maxSeconds = 20}) async {
    for (var i = 0; i < maxSeconds; i++) {
      try {
        final url = await profile.generator!.getCurrentUrl();
        if (url.contains('labs.google')) {
          print('[AutoLogin] ${profile.name} - ✓ Redirected to Flow');
          return true;
        }
      } catch (e) {}
      await Future.delayed(Duration(seconds: 1));
    }
    return false;
  }

  Future<String?> _verifyLoginWithRetry(ChromeProfile profile, {int maxAttempts = 6}) async {
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      await Future.delayed(Duration(seconds: 15));
      print('[AutoLogin] ${profile.name} - Token verification attempt $attempt/$maxAttempts...');

      try {
        // Reconnect if needed
        if (profile.generator == null) {
          final gen = BrowserVideoGenerator(debugPort: profile.debugPort);
          await gen.connect();
          profile.generator = gen;
        }

        final token = await profile.generator!.getAccessToken();
        if (token != null) {
          return token;
        }
      } catch (e) {
        print('[AutoLogin] ${profile.name} - Token check error: $e');
      }
    }

    return null;
  }
}
