import 'package:flutter/material.dart';
import 'template_page.dart';
import '../services/profile_manager_service.dart';
import '../services/multi_profile_login_service.dart';

/// Templates screen - Story Prompt Processor
class TemplatesScreen extends StatefulWidget {
  final ProfileManagerService? profileManager;
  final MultiProfileLoginService? loginService;
  
  const TemplatesScreen({
    super.key,
    this.profileManager,
    this.loginService,
  });

  @override
  State<TemplatesScreen> createState() => _TemplatesScreenState();
}

class _TemplatesScreenState extends State<TemplatesScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    
    return MainScreen(
      profileManager: widget.profileManager,
      loginService: widget.loginService,
    );
  }
}
