import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sms_forwarder/models/sms_item.dart';
import 'package:sms_forwarder/utils/otp_parser.dart';

/// Durable queue via SharedPreferences (avoids path_provider JNI issues).
class SmsPendingStore {
  static const _pendingKey = 'pending_sms_v2';
  static const _syncedKey = 'synced_sms_ids_v1';

  static Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  static Future<void> addFromTelephony({
    required String? address,
    required String? body,
    required String? date,
  }) async {
    final dateMs =
        int.tryParse(date ?? '') ?? DateTime.now().millisecondsSinceEpoch;
    final text = body ?? '';
    final sender =
        (address != null && address.trim().isNotEmpty) ? address.trim() : 'Unknown';
    await add(
      SmsItem(
        id: '$sender|$dateMs|${text.hashCode}',
        sender: sender,
        body: text,
        receivedAt: DateTime.fromMillisecondsSinceEpoch(dateMs),
        otp: OtpParser.extract(text),
      ),
    );
  }

  static Future<void> add(SmsItem item) async {
    final prefs = await _prefs();
    final list = prefs.getStringList(_pendingKey) ?? <String>[];
    list.removeWhere((raw) {
      try {
        return (jsonDecode(raw) as Map)['id'] == item.id;
      } catch (_) {
        return false;
      }
    });
    list.insert(0, jsonEncode(item.toJson()));
    await prefs.setStringList(_pendingKey, list.take(200).toList());
  }

  static Future<List<SmsItem>> peekAll() async {
    final prefs = await _prefs();
    final list = prefs.getStringList(_pendingKey) ?? <String>[];
    return list
        .map((raw) {
          try {
            return SmsItem.fromJson(jsonDecode(raw) as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<SmsItem>()
        .toList();
  }

  static Future<List<SmsItem>> takeAll() async {
    final items = await peekAll();
    final prefs = await _prefs();
    await prefs.remove(_pendingKey);
    return items;
  }

  static Future<void> removeIds(Iterable<String> ids) async {
    final remove = ids.toSet();
    if (remove.isEmpty) return;
    final prefs = await _prefs();
    final list = prefs.getStringList(_pendingKey) ?? <String>[];
    list.removeWhere((raw) {
      try {
        return remove.contains((jsonDecode(raw) as Map)['id']);
      } catch (_) {
        return false;
      }
    });
    await prefs.setStringList(_pendingKey, list);
  }

  static String contentKey(SmsItem sms) {
    final sec = sms.receivedAt.millisecondsSinceEpoch ~/ 1000;
    return '${sms.sender}|${sms.body}|$sec';
  }

  static Future<Set<String>> syncedKeys() async {
    final prefs = await _prefs();
    return (prefs.getStringList(_syncedKey) ?? <String>[]).toSet();
  }

  static Future<void> markSynced(Iterable<String> keys) async {
    final prefs = await _prefs();
    final set = (prefs.getStringList(_syncedKey) ?? <String>[]).toSet()
      ..addAll(keys);
    final trimmed = set.toList().reversed.take(800).toList().reversed.toList();
    await prefs.setStringList(_syncedKey, trimmed);
  }
}
