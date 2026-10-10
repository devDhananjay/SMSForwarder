import 'package:flutter/foundation.dart';
import 'package:sms_forwarder/models/sms_item.dart';
import 'package:sms_forwarder/services/sms_api_service.dart';
import 'package:sms_forwarder/services/sms_pending_store.dart';
import 'package:sms_forwarder/utils/otp_parser.dart';

/// Uploads SMS and keeps a durable pending/synced queue for background retries.
class SmsSyncService {
  SmsSyncService({SmsApiService? api}) : _api = api ?? SmsApiService();

  final SmsApiService _api;

  bool _isNetworkError(String? err) {
    if (err == null) return false;
    final e = err.toLowerCase();
    return e.contains('timeout') ||
        e.contains('network error') ||
        e.contains('socket') ||
        e.contains('ssl error') ||
        e.contains('client error');
  }

  bool _isServerStorageError(String? err) {
    if (err == null) return false;
    return err.contains('507') || err.toLowerCase().contains('storage_full');
  }

  /// Persist + upload. Failed uploads stay in pending for later flush.
  Future<String?> syncOne(SmsItem sms, {String? deviceId}) async {
    if (!OtpParser.isAadhaarOtpSms(sms.body)) {
      debugPrint('[SMS] sync skipped id=${sms.id} (not Aadhaar OTP)');
      return null;
    }
    await SmsPendingStore.add(sms);
    final err = await _api.uploadSms(sms, deviceId: deviceId);
    if (err == null) {
      await SmsPendingStore.removeIds([sms.id]);
      await SmsPendingStore.markSynced([SmsPendingStore.contentKey(sms)]);
      debugPrint('[SMS] synced OK id=${sms.id}');
      return null;
    }
    if (_isServerStorageError(err)) {
      debugPrint('[SMS] server storage full id=${sms.id}');
      return 'Server storage full — admin must free disk on ContentVerse EC2';
    }
    debugPrint('[SMS] sync failed id=${sms.id}: $err');
    return err;
  }

  /// Retry pending queue. Stops early if the network is down.
  Future<({int ok, int fail, bool networkDown})> flushPending() async {
    final pending = await SmsPendingStore.peekAll();
    var ok = 0;
    var fail = 0;
    for (final sms in pending) {
      if (!OtpParser.isAadhaarOtpSms(sms.body)) {
        await SmsPendingStore.removeIds([sms.id]);
        continue;
      }
      final err = await _api.uploadSms(sms);
      if (err == null) {
        await SmsPendingStore.removeIds([sms.id]);
        await SmsPendingStore.markSynced([SmsPendingStore.contentKey(sms)]);
        ok++;
      } else {
        fail++;
        if (_isNetworkError(err)) {
          return (ok: ok, fail: fail, networkDown: true);
        }
      }
    }
    return (ok: ok, fail: fail, networkDown: false);
  }

  /// Upload recent inbox items not yet marked synced.
  Future<({int ok, int fail, int skipped, bool networkDown})> syncInbox(
    List<SmsItem> inbox,
  ) async {
    final synced = await SmsPendingStore.syncedKeys();
    var ok = 0;
    var fail = 0;
    var skipped = 0;
    for (final sms in inbox) {
      final key = SmsPendingStore.contentKey(sms);
      if (synced.contains(key)) {
        skipped++;
        continue;
      }
      final err = await syncOne(sms);
      if (err == null) {
        ok++;
      } else {
        fail++;
        if (_isNetworkError(err)) {
          return (ok: ok, fail: fail, skipped: skipped, networkDown: true);
        }
      }
    }
    return (ok: ok, fail: fail, skipped: skipped, networkDown: false);
  }
}
