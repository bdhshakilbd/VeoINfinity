import 'package:flutter/foundation.dart';

class AppLogger {
  static void i(String msg) => debugPrint(msg);
  static void w(String msg) => debugPrint('WARN: $msg');
  static void e(String msg) => debugPrint('ERROR: $msg');
}
