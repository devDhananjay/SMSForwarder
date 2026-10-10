import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:sms_forwarder/services/sms_sync_service.dart';

/// Top-level entry for the foreground-service isolate.
@pragma('vm:entry-point')
void smsForegroundStartCallback() {
  FlutterForegroundTask.setTaskHandler(SmsForegroundTaskHandler());
}

class SmsForegroundTaskHandler extends TaskHandler {
  final _sync = SmsSyncService();

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[SMS][FGS] onStart starter=${starter.name}');
    await _flush();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _flush();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint('[SMS][FGS] onDestroy timeout=$isTimeout');
  }

  @override
  void onReceiveData(Object data) {
    if (data == 'flush') {
      _flush();
    }
  }

  Future<void> _flush() async {
    try {
      final result = await _sync.flushPending();
      final text = result.fail == 0
          ? 'Background sync OK · pending clear'
          : 'Synced ${result.ok}, pending fail ${result.fail}';
      await FlutterForegroundTask.updateService(
        notificationTitle: 'SMS Forwarder · listening',
        notificationText: text,
      );
      FlutterForegroundTask.sendDataToMain({
        'ok': result.ok,
        'fail': result.fail,
        'at': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('[SMS][FGS] flush error: $e');
    }
  }
}

class ForegroundSmsService {
  ForegroundSmsService._();

  static bool _nativeReady = true;

  static void init() {
    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'sms_forwarder_sync',
          channelName: 'SMS background sync',
          channelDescription:
              'Keeps SMS Forwarder alive so messages sync in the background.',
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(20000),
          autoRunOnBoot: true,
          autoRunOnMyPackageReplaced: true,
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );
    } catch (e) {
      _nativeReady = false;
      debugPrint('[SMS][FGS] init skipped: $e');
    }
  }

  static Future<void> requestPermissions() async {
    if (!_nativeReady) return;
    try {
      final n = await FlutterForegroundTask.checkNotificationPermission();
      if (n != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      if (Platform.isAndroid) {
        if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
          await FlutterForegroundTask.requestIgnoreBatteryOptimization();
        }
      }
    } on MissingPluginException catch (e) {
      _nativeReady = false;
      debugPrint(
        '[SMS][FGS] plugin missing — do a FULL rebuild (stop app, flutter run): $e',
      );
    } catch (e) {
      debugPrint('[SMS][FGS] permission error: $e');
    }
  }

  static Future<bool> start() async {
    if (!_nativeReady) return false;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.restartService();
        return true;
      }
      final result = await FlutterForegroundTask.startService(
        serviceTypes: const [
          ForegroundServiceTypes.dataSync,
          ForegroundServiceTypes.remoteMessaging,
        ],
        serviceId: 9021,
        notificationTitle: 'SMS Forwarder · listening',
        notificationText: 'Background SMS sync is active',
        callback: smsForegroundStartCallback,
      );
      debugPrint('[SMS][FGS] start: $result');
      return result is ServiceRequestSuccess;
    } on MissingPluginException catch (e) {
      _nativeReady = false;
      debugPrint('[SMS][FGS] start skipped (need full rebuild): $e');
      return false;
    } catch (e) {
      debugPrint('[SMS][FGS] start error: $e');
      return false;
    }
  }

  static Future<void> askFlush() async {
    if (!_nativeReady) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        FlutterForegroundTask.sendDataToTask('flush');
      }
    } on MissingPluginException {
      _nativeReady = false;
    } catch (_) {}
  }
}
