import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android owns only process importance, a notification and a bounded CPU
/// lease. Commands and all work remain with the existing Dart task owners.
abstract interface class BackgroundTasksPlatform {
  bool get supported;
  void setActionHandler(Future<void> Function(String action)? handler);
  Future<bool> update(Map<String, Object> state);
}

final class AndroidBackgroundTasksPlatform implements BackgroundTasksPlatform {
  static const channel = MethodChannel('dev.zic.zic/background_tasks');

  @override
  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void setActionHandler(Future<void> Function(String action)? handler) {
    if (!supported) return;
    channel.setMethodCallHandler(handler == null ? null : (call) async {
      if (call.method == 'action') await handler(call.arguments as String);
    });
  }

  @override
  Future<bool> update(Map<String, Object> state) async {
    if (!supported) return false;
    try {
      return await channel.invokeMethod<bool>('update', state)
          .timeout(const Duration(seconds: 8)) ?? false;
    } on MissingPluginException {
      return false;
    } on TimeoutException {
      debugPrint('Android background task service acknowledgement timed out');
      return false;
    } on PlatformException catch (error) {
      debugPrint('Android background task service unavailable: ${error.code}');
      return false;
    }
  }

  static Future<bool> openSettings({bool battery = false}) async {
    try {
      return await channel.invokeMethod<bool>(battery ? 'batterySettings' : 'notificationSettings') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
