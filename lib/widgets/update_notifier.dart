import 'package:flutter/material.dart';
import '../services/update_service.dart';

/// Global update notifier that can be accessed from anywhere
class UpdateNotifier extends ChangeNotifier {
  static final UpdateNotifier _instance = UpdateNotifier._internal();
  factory UpdateNotifier() => _instance;
  UpdateNotifier._internal();

  bool _updateAvailable = false;
  UpdateInfo? _updateInfo;

  bool get updateAvailable => _updateAvailable;
  UpdateInfo? get updateInfo => _updateInfo;

  void setUpdateAvailable(UpdateInfo info) {
    _updateAvailable = true;
    _updateInfo = info;
    notifyListeners();
  }

  void clear() {
    _updateAvailable = false;
    _updateInfo = null;
    notifyListeners();
  }
}

/// Widget that listens to update status
class UpdateAwareBuilder extends StatefulWidget {
  final Widget Function(BuildContext context, bool updateAvailable, UpdateInfo? updateInfo) builder;

  const UpdateAwareBuilder({
    Key? key,
    required this.builder,
  }) : super(key: key);

  @override
  State<UpdateAwareBuilder> createState() => _UpdateAwareBuilderState();
}

class _UpdateAwareBuilderState extends State<UpdateAwareBuilder> {
  final _notifier = UpdateNotifier();

  @override
  void initState() {
    super.initState();
    _notifier.addListener(_onUpdateChanged);
  }

  @override
  void dispose() {
    _notifier.removeListener(_onUpdateChanged);
    super.dispose();
  }

  void _onUpdateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _notifier.updateAvailable, _notifier.updateInfo);
  }
}
