import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:another_telephony/telephony.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sms_forwarder/config/api_config.dart';
import 'package:sms_forwarder/models/sms_item.dart';
import 'package:sms_forwarder/services/sms_sync_service.dart';
import 'package:sms_forwarder/utils/otp_parser.dart';

/// Top-level handler required by telephony for background SMS (Android).
/// Runs in a separate isolate — persist + upload (retry later if offline).
@pragma('vm:entry-point')
Future<void> backgroundSmsHandler(SmsMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  debugPrint(
    '[SMS] background: from=${message.address} body=${message.body}',
  );

  // Only Aadhaar / UIDAI OTP SMS — ignore all other messages.
  if (!OtpParser.isAadhaarOtpSms(message.body)) {
    debugPrint('[SMS] background skipped (not Aadhaar OTP)');
    return;
  }

  final item = SmsItem(
    id: '${message.address}|${message.date}|${message.body.hashCode}',
    sender: message.address?.trim().isNotEmpty == true
        ? message.address!.trim()
        : 'Unknown',
    body: message.body ?? '',
    receivedAt: DateTime.fromMillisecondsSinceEpoch(
      message.date ?? DateTime.now().millisecondsSinceEpoch,
    ),
    otp: OtpParser.extract(message.body),
  );

  try {
    final err = await SmsSyncService().syncOne(item);
    debugPrint(
      err == null
          ? '[SMS] background uploaded OK'
          : '[SMS] background queued for retry: $err',
    );
  } catch (e, st) {
    debugPrint('[SMS] background handler error: $e\n$st');
  }
}

class SmsReaderService {
  SmsReaderService();

  final Telephony _telephony = Telephony.instance;

  bool get isAndroid => !kIsWeb && Platform.isAndroid;

  Future<bool> requestPermissions() async {
    if (!isAndroid) return false;

    final existing = await Permission.sms.status.timeout(
      const Duration(seconds: 3),
      onTimeout: () => PermissionStatus.denied,
    );
    if (existing.isGranted) return true;

    try {
      final telephonyOk = await _telephony.requestPhoneAndSmsPermissions
          .timeout(const Duration(seconds: 20));
      if (telephonyOk == true) return true;
    } on TimeoutException {
      debugPrint('[SMS] telephony permission request timed out');
    } catch (e) {
      debugPrint('[SMS] telephony permission error: $e');
    }

    try {
      final sms = await Permission.sms
          .request()
          .timeout(const Duration(seconds: 20));
      final phone = await Permission.phone
          .request()
          .timeout(const Duration(seconds: 20));
      return sms.isGranted || phone.isGranted;
    } on TimeoutException {
      return false;
    }
  }

  Future<bool> hasPermissions() async {
    if (!isAndroid) return false;
    try {
      final sms =
          await Permission.sms.status.timeout(const Duration(seconds: 3));
      return sms.isGranted;
    } catch (_) {
      return false;
    }
  }

  Future<List<SmsItem>> fetchInbox({int? limit}) async {
    if (!isAndroid) return const [];

    final messages = await _telephony
        .getInboxSms(
          columns: [
            SmsColumn.ID,
            SmsColumn.ADDRESS,
            SmsColumn.BODY,
            SmsColumn.DATE,
          ],
          sortOrder: [
            OrderBy(SmsColumn.DATE, sort: Sort.DESC),
          ],
        )
        .timeout(const Duration(seconds: 15));

    final max = limit ?? ApiConfig.inboxLimit;
    // Scan recent inbox but keep only Aadhaar OTP SMS.
    final filtered = <SmsItem>[];
    for (final message in messages) {
      if (!OtpParser.isAadhaarOtpSms(message.body)) continue;
      filtered.add(_mapMessage(message));
      if (filtered.length >= max) break;
    }
    return filtered;
  }

  void listenIncoming({
    required void Function(SmsItem sms) onMessage,
    bool listenInBackground = true,
  }) {
    if (!isAndroid) return;

    _telephony.listenIncomingSms(
      onNewMessage: (SmsMessage message) {
        debugPrint(
          '[SMS] foreground: from=${message.address} body=${message.body}',
        );
        if (!OtpParser.isAadhaarOtpSms(message.body)) {
          debugPrint('[SMS] foreground skipped (not Aadhaar OTP)');
          return;
        }
        onMessage(_mapMessage(message));
      },
      onBackgroundMessage: listenInBackground ? backgroundSmsHandler : null,
      listenInBackground: listenInBackground,
    );
  }

  SmsItem _mapMessage(SmsMessage message) {
    final dateMs = message.date ?? DateTime.now().millisecondsSinceEpoch;
    final id = (message.id?.toString().isNotEmpty ?? false)
        ? message.id.toString()
        : '${message.address}|$dateMs|${message.body.hashCode}';
    final body = message.body ?? '';
    return SmsItem(
      id: id,
      sender: message.address?.trim().isNotEmpty == true
          ? message.address!.trim()
          : 'Unknown',
      body: body,
      receivedAt: DateTime.fromMillisecondsSinceEpoch(dateMs),
      otp: OtpParser.extract(body),
    );
  }
}
