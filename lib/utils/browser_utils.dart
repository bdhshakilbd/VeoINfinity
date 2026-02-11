import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';

class BrowserUtils {
  /// Chrome arguments for desktop browsers to ensure they don't throttle in background
  /// and work reliably for automation/polling.
  /// 
  /// AMD Ryzen optimizations:
  /// - Added --disable-features=RendererCodeIntegrity for better Ryzen compatibility
  /// - Added --disable-hang-monitor to prevent false "not responding" detection
  static List<String> getChromeArgs({
    required int debugPort,
    required String profilePath,
    String? url,
    String? windowPosition,
    String? windowSize,
  }) {
    final args = [
      '--remote-debugging-port=$debugPort',
      '--remote-allow-origins=*',
      '--user-data-dir=$profilePath',
      '--profile-directory=Default',
      '--disable-background-timer-throttling',
      '--disable-backgrounding-occluded-windows',
      '--disable-renderer-backgrounding',
      '--disable-hang-monitor', // Prevents "not responding" detection
      '--disable-features=RendererCodeIntegrity', // AMD Ryzen compatibility
      '--no-first-run',
      '--no-default-browser-check',
      '--window-size=${windowSize ?? "800,600"}', // Larger window for desktop view
    ];

    if (windowPosition != null) {
      args.add('--window-position=$windowPosition');
    }
    
    if (url != null) {
      args.add(url);
    }

    return args;
  }

  /// Force a window to be Always-On-Top and optionally position it at the bottom-left (Windows only)
  /// Uses async PowerShell execution to avoid blocking the main thread
  static Future<void> forceAlwaysOnTop(int pid, {int? width, int? height, int offsetIndex = 0}) async {
    if (!Platform.isWindows) return;

    try {
      // Small delay to allow window to be created
      await Future.delayed(const Duration(milliseconds: 100));
      
      final psCommand = '''
        Add-Type -AssemblyName System.Windows.Forms
        \$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        \$screenHeight = \$screen.Height
        
        \$p = Get-Process -Id $pid -ErrorAction SilentlyContinue;
        if (\$p) {
            \$count = 0;
            while (\$p.MainWindowHandle -eq 0 -and \$count -lt 20) {
                Start-Sleep -m 200;
                \$p = Get-Process -Id $pid -ErrorAction SilentlyContinue;
                \$count++;
            }
            if (\$p.MainWindowHandle -ne 0) {
                \$h = \$p.MainWindowHandle;
                
                # Default size if not provided (should match Chrome launch args)
                \$w = ${width ?? 200}
                \$height = ${height ?? 350}
                
                # Calculate Column and Stack index (wrap after 5 browsers)
                \$idx = $offsetIndex
                \$maxInStack = 5
                \$stackIdx = \$idx % \$maxInStack
                \$columnIdx = [Math]::Floor(\$idx / \$maxInStack)
                
                # Position from bottom-left
                # xPos: column width + a small stagger
                # yPos: screen height - window height - taskbar(40) - stack stagger
                \$xPos = (\$columnIdx * (\$w + 20)) + (\$stackIdx * 15)
                \$yPos = \$screenHeight - \$height - 40 - (\$stackIdx * 25)
                
                \$signature = '[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);';
                \$typeName = "Win32SetWindowPos" + [Guid]::NewGuid().ToString("N")
                \$type = Add-Type -MemberDefinition \$signature -Name \$typeName -PassThru;
                
                # uFlags: 0x0040 (SHOWWINDOW)
                # hWndInsertAfter: -1 (HWND_TOPMOST)
                \$type::SetWindowPos(\$h, [IntPtr](-1), \$xPos, \$yPos, \$w, \$height, 0x0040)
            }
        }
      ''';

      // Run PowerShell with timeout to prevent blocking
      await Process.run('powershell', ['-Command', psCommand])
          .timeout(const Duration(seconds: 10), onTimeout: () {
        print('[BrowserUtils] PowerShell timeout - continuing anyway');
        return ProcessResult(0, 0, '', '');
      });
    } catch (e) {
      print('[BrowserUtils] Error applying Always-On-Top/Position: $e');
    }
  }
  
  /// Apply mobile device emulation via CDP
  /// DISABLED: Mobile emulation causes 500 errors. Using desktop mode instead.
  static Future<void> applyMobileEmulation(int debugPort) async {
    // DISABLED - Mobile emulation causes 500 Internal Server errors
    // Using desktop mode with larger window instead
    print('[MobileEmulation] Skipped - using desktop mode');
    return;
  }
  
  /// Set high performance process affinity for Chrome (AMD Ryzen optimization)
  /// Sets process to High priority and allocates to first 8 cores (typically performance cores)
  static Future<void> setHighPerformanceAffinity(int pid) async {
    if (!Platform.isWindows) return;
    
    try {
      final psCommand = '''
        \$p = Get-Process -Id $pid -ErrorAction SilentlyContinue
        if (\$p) {
          # Set high priority
          \$p.PriorityClass = 'High'
          
          # On AMD Ryzen, set affinity to first 8 cores (typically performance cores)
          # 0xFF = binary 11111111 = first 8 cores
          \$p.ProcessorAffinity = 0xFF
          
          Write-Host "Set process $pid to High priority with affinity 0xFF"
        }
      ''';
      
      await Process.run('powershell', ['-Command', psCommand])
          .timeout(const Duration(seconds: 5), onTimeout: () {
        print('[BrowserUtils] Affinity command timeout');
        return ProcessResult(0, 0, '', '');
      });
      
      print('[BrowserUtils] High performance affinity set for PID $pid');
    } catch (e) {
      print('[BrowserUtils] Error setting affinity: $e');
    }
  }
  
  /// Prevent CPU throttling on AMD Ryzen by disabling core parking temporarily
  /// This helps prevent the "not responding" issue on Ryzen CPUs
  static Future<void> preventCpuThrottling() async {
    if (!Platform.isWindows) return;
    
    try {
      final psCommand = '''
        # Set power plan to High Performance for current session
        powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>\$null
        
        # Disable core parking (helps with AMD Ryzen responsiveness)
        powercfg /setacvalueindex scheme_current sub_processor CPMINCORES 100 2>\$null
        powercfg /setactive scheme_current 2>\$null
        
        Write-Host "CPU throttling prevention applied"
      ''';
      
      await Process.run('powershell', ['-Command', psCommand])
          .timeout(const Duration(seconds: 5), onTimeout: () {
        print('[BrowserUtils] CPU throttling command timeout');
        return ProcessResult(0, 0, '', '');
      });
      
      print('[BrowserUtils] CPU throttling prevention applied');
    } catch (e) {
      print('[BrowserUtils] Error preventing CPU throttling: $e');
    }
  }
  
  /// Run PowerShell command asynchronously in isolate to avoid blocking main thread
  /// This is especially important on AMD Ryzen where PowerShell can be slower
  static Future<String> runPowerShellAsync(String command) async {
    if (!Platform.isWindows) return '';
    
    try {
      final result = await compute(_runPowerShellIsolate, command);
      return result;
    } catch (e) {
      print('[BrowserUtils] PowerShell async error: $e');
      return '';
    }
  }
  
  /// Internal function to run PowerShell in isolate
  static Future<String> _runPowerShellIsolate(String command) async {
    try {
      final result = await Process.run('powershell', ['-Command', command])
          .timeout(const Duration(seconds: 30));
      return result.stdout.toString();
    } catch (e) {
      return 'Error: $e';
    }
  }
}

