import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'dart:io';
import 'main.dart';
import 'screens/video_mastering_screen.dart';
import 'services/project_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    MediaKit.ensureInitialized();
  }

  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
    ),
    home: VideoMasteringScreen(
      projectService: ProjectService(),
      isActivated: true,
    ),
  ));
}
