import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sms_forwarder/config/api_config.dart';
import 'package:sms_forwarder/models/sms_item.dart';

class SmsApiService {
  SmsApiService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'User-Agent': 'SmsForwarderApp/1.0',
        if (ApiConfig.apiKey.trim().isNotEmpty)
          'Authorization': 'Bearer ${ApiConfig.apiKey.trim()}',
      };

  /// Only allow https://… or explicit direct http://IP:3011 (never http on :443).
  Uri? _safeUri(String base, String path, [Map<String, String>? query]) {
    var normalized = base.trim().replaceAll(RegExp(r'/+$'), '');
    // Guard: http://host:443 would trigger nginx 400 plain-HTTP-to-HTTPS.
    if (normalized.contains(':443') && normalized.startsWith('http://')) {
      normalized = normalized.replaceFirst('http://', 'https://');
      normalized = normalized.replaceFirst(':443', '');
    }
    if (normalized.startsWith('http://') &&
        !normalized.contains(':3011') &&
        !normalized.contains(RegExp(r':\d+'))) {
      // Accidental http://contentverse.co.in → force https
      normalized = normalized.replaceFirst('http://', 'https://');
    }
    final uri = Uri.tryParse('$normalized$path');
    if (uri == null) return null;
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: query);
  }

  Future<http.Response> _send(
    Future<http.Response> Function() request, {
    Duration timeout = const Duration(seconds: 35),
  }) {
    return request().timeout(timeout);
  }

  String _prettyError(Object e, {String? via}) {
    final where = via ?? ApiConfig.baseUrl;
    if (e is TimeoutException) {
      return 'Timeout reaching $where';
    }
    return '[$where] $e';
  }

  List<String> get _bases {
    final list = <String>[
      ApiConfig.baseUrl.trim(),
      if (ApiConfig.directBaseUrl.trim().isNotEmpty)
        ApiConfig.directBaseUrl.trim(),
    ];
    // Prefer last known good, but never prefer a bad http://:443 style URL.
    final active = ApiConfig.activeBaseUrl?.trim();
    if (active != null &&
        active.isNotEmpty &&
        !(active.startsWith('http://') && active.contains(':443'))) {
      return [active, ...list.where((b) => b != active)];
    }
    return list;
  }

  Future<String?> pingHealth() async {
    Object? lastError;
    String? lastVia;
    for (final base in _bases) {
      final uri = _safeUri(base, '/health');
      if (uri == null) continue;
      debugPrint('[SMS][API] GET $uri');
      try {
        final res = await _send(() => _client.get(uri, headers: _headers));
        if (res.statusCode >= 200 && res.statusCode < 300) {
          ApiConfig.activeBaseUrl = base;
          return null;
        }
        lastError = 'HTTP ${res.statusCode}: ${res.body.trim()}';
        lastVia = uri.toString();
      } catch (e) {
        lastError = e;
        lastVia = uri.toString();
      }
    }
    return _prettyError(lastError ?? 'unreachable', via: lastVia);
  }

  Future<String?> uploadSms(SmsItem sms, {String? deviceId}) async {
    final body = jsonEncode(sms.toApiPayload(deviceId: deviceId));
    Object? lastError;
    String? lastVia;

    const maxAttempts = 3;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(seconds: 1 + attempt));
      }
      final timeout = Duration(seconds: 25 + (attempt * 15));

      for (final base in _bases) {
        final uri = _safeUri(base, '/api/sms/fetch');
        if (uri == null) continue;
        debugPrint('[SMS][API] POST $uri (try ${attempt + 1}/$maxAttempts)');
        try {
          final res = await _send(
            () => _client.post(uri, headers: _headers, body: body),
            timeout: timeout,
          );
          if (res.statusCode >= 200 && res.statusCode < 300) {
            ApiConfig.activeBaseUrl = base;
            return null;
          }
          lastError = 'HTTP ${res.statusCode}: ${res.body.trim()}';
          lastVia = uri.toString();
          // 4xx (except 408/429) — don't burn retries on bad request.
          if (res.statusCode >= 400 &&
              res.statusCode < 500 &&
              res.statusCode != 408 &&
              res.statusCode != 429) {
            return _prettyError(lastError, via: lastVia);
          }
        } catch (e) {
          lastError = e;
          lastVia = uri.toString();
        }
      }

      final retryable = lastError is TimeoutException ||
          lastError.toString().toLowerCase().contains('socket') ||
          lastError.toString().toLowerCase().contains('connection');
      if (!retryable || attempt == maxAttempts - 1) break;
    }
    return _prettyError(lastError ?? 'Upload failed', via: lastVia);
  }

  Future<({List<SmsItem> items, int total, String? error})> listSms({
    int limit = 50,
    int offset = 0,
    String? sender,
    String? query,
  }) async {
    Object? lastError;
    String? lastVia;

    for (final base in _bases) {
      final uri = _safeUri(base, '/api/sms/list', {
        'limit': '$limit',
        'offset': '$offset',
        if (sender != null && sender.isNotEmpty) 'sender': sender,
        if (query != null && query.isNotEmpty) 'q': query,
      });
      if (uri == null) continue;
      try {
        final res = await _send(() => _client.get(uri, headers: _headers));
        if (res.statusCode < 200 || res.statusCode >= 300) {
          lastError = 'HTTP ${res.statusCode}: ${res.body.trim()}';
          lastVia = uri.toString();
          continue;
        }
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        final rawItems = (json['items'] as List?) ?? const [];
        final items = rawItems.map((e) {
          final m = Map<String, dynamic>.from(e as Map);
          return SmsItem(
            id: m['id']?.toString() ?? '',
            sender: m['sender']?.toString() ?? 'Unknown',
            body: m['body']?.toString() ?? '',
            receivedAt: DateTime.tryParse(m['received_at']?.toString() ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(
                  (m['timestamp_ms'] as num?)?.toInt() ??
                      DateTime.now().millisecondsSinceEpoch,
                ),
            otp: m['otp']?.toString(),
            synced: true,
          );
        }).toList();
        ApiConfig.activeBaseUrl = base;
        return (
          items: items,
          total: (json['total'] as num?)?.toInt() ?? items.length,
          error: null,
        );
      } catch (e) {
        lastError = e;
        lastVia = uri.toString();
      }
    }

    return (
      items: <SmsItem>[],
      total: 0,
      error: _prettyError(lastError ?? 'List failed', via: lastVia),
    );
  }
}
