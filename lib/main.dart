import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sms_forwarder/config/api_config.dart';
import 'package:sms_forwarder/models/sms_item.dart';
import 'package:sms_forwarder/services/foreground_sms_service.dart';
import 'package:sms_forwarder/services/sms_api_service.dart';
import 'package:sms_forwarder/services/sms_pending_store.dart';
import 'package:sms_forwarder/services/sms_reader_service.dart';
import 'package:sms_forwarder/services/sms_sync_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  // Reset any stale base from a previous isolate run.
  ApiConfig.activeBaseUrl = null;
  runApp(const SmsForwarderApp());
}

class SmsForwarderApp extends StatelessWidget {
  const SmsForwarderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: MaterialApp(
        title: 'SMS Forwarder',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F766E)),
          useMaterial3: true,
        ),
        home: const HomePage(),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final _reader = SmsReaderService();
  final _api = SmsApiService();
  final _sync = SmsSyncService();

  final List<SmsItem> _messages = [];
  bool _loading = true;
  bool _listening = false;
  bool _permissionGranted = false;
  bool _backgroundSyncOn = false;
  String? _status;
  final Set<String> _syncingIds = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FlutterForegroundTask.addTaskDataCallback(_onFgData);
    ForegroundSmsService.init();
    _bootstrap();
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onFgData);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onFgData(Object data) {
    if (!mounted) return;
    if (data is Map && data['ok'] != null) {
      setState(() {
        _status =
            'Background flush: synced ${data['ok']}, failed ${data['fail']}';
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _permissionGranted) {
      unawaited(_refreshFromDevice(syncCatchUp: true));
      unawaited(ForegroundSmsService.askFlush());
    }
  }

  Future<void> _bootstrap() async {
    if (!_reader.isAndroid) {
      setState(() {
        _loading = false;
        _status = 'SMS reading works only on Android.';
      });
      return;
    }

    final granted = await _reader.requestPermissions();
    if (!mounted) return;
    setState(() {
      _permissionGranted = granted;
      _status = granted ? 'Permission granted' : 'SMS permission denied';
    });

    if (!granted) {
      setState(() => _loading = false);
      return;
    }

    // Notification + battery exemption so background sync can run.
    // Requires a FULL app rebuild after adding flutter_foreground_task
    // (hot restart is not enough — native plugin won't be registered).
    await ForegroundSmsService.requestPermissions();
    final fgsOk = await ForegroundSmsService.start();
    if (!mounted) return;
    setState(() => _backgroundSyncOn = fgsOk);

    // Register listener ASAP so foreground channel is ready.
    _startListening();

    final apiErr = await _api.pingHealth();
    if (!mounted) return;
    if (apiErr != null) {
      setState(() => _status = 'API unreachable: $apiErr');
    } else {
      setState(() {
        _status = fgsOk
            ? 'Background sync ON · API OK'
            : 'API OK · enable notification for background sync';
      });
    }

    await _refreshFromDevice(syncCatchUp: true);
  }

  Future<void> _refreshFromDevice({bool syncCatchUp = false}) async {
    setState(() {
      _loading = true;
      _status = 'Loading SMS…';
    });
    try {
      final pending = await SmsPendingStore.peekAll()
          .timeout(const Duration(seconds: 5), onTimeout: () => <SmsItem>[]);
      final inbox = await _reader.fetchInbox();
      if (!mounted) return;

      _mergeMessages([...pending, ...inbox]);
      setState(() {
        _loading = false;
        _status = 'Showing ${_messages.length} Aadhaar OTP SMS'
            '${pending.isEmpty ? '' : ' (${pending.length} pending sync)'}';
      });

      if (syncCatchUp) {
        unawaited(_catchUpSync(inbox));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _status = 'Inbox error: $e';
      });
    }
  }

  Future<void> _catchUpSync(List<SmsItem> inbox) async {
    final flush = await _sync.flushPending();
    if (!mounted) return;
    if (flush.networkDown) {
      setState(() {
        _status =
            'Network down — ${flush.ok} synced, rest queued. Try mobile data.';
      });
      return;
    }
    // Recent inbox only — avoid uploading entire history every resume.
    final recent = inbox.take(10).toList();
    final result = await _sync.syncInbox(recent);
    if (!mounted) return;
    final syncedIds = recent.map((r) => r.id).toSet();
    setState(() {
      if (result.networkDown) {
        _status =
            'Network down after +${result.ok + flush.ok} synced — rest queued.';
      } else {
        _status =
            'Catch-up: +${result.ok + flush.ok} synced, ${result.fail + flush.fail} failed, ${result.skipped} already done';
      }
      if (result.ok + flush.ok > 0) {
        for (var i = 0; i < _messages.length; i++) {
          final m = _messages[i];
          if (syncedIds.contains(m.id)) {
            _messages[i] = m.copyWith(synced: true, syncError: null);
          }
        }
      }
    });
  }

  String _contentKey(SmsItem sms) {
    // Background SMS has no inbox ID — dedupe by sender/body/second.
    final sec = sms.receivedAt.millisecondsSinceEpoch ~/ 1000;
    return '${sms.sender}|${sms.body}|$sec';
  }

  void _mergeMessages(List<SmsItem> incoming) {
    final byId = <String, SmsItem>{};
    final byContent = <String, String>{};

    void put(SmsItem sms) {
      final content = _contentKey(sms);
      final existingId = byContent[content];
      if (existingId != null) {
        final existing = byId[existingId]!;
        // Prefer real inbox id over synthetic background id.
        final keepId = int.tryParse(sms.id) != null ? sms.id : existingId;
        final dropId = keepId == sms.id ? existingId : sms.id;
        byId.remove(dropId);
        byId[keepId] = SmsItem(
          id: keepId,
          sender: sms.sender,
          body: sms.body,
          receivedAt: sms.receivedAt,
          otp: sms.otp ?? existing.otp,
          synced: existing.synced || sms.synced,
          syncError: existing.syncError ?? sms.syncError,
        );
        byContent[content] = keepId;
        return;
      }
      byId[sms.id] = sms;
      byContent[content] = sms.id;
    }

    for (final m in _messages) {
      put(m);
    }
    for (final sms in incoming) {
      put(sms);
    }

    final merged = byId.values.toList()
      ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    setState(() {
      _messages
        ..clear()
        ..addAll(merged);
    });
  }

  void _startListening() {
    if (_listening) return;
    _reader.listenIncoming(
      onMessage: (sms) {
        if (!mounted) return;
        setState(() {
          _messages.removeWhere((m) => m.id == sms.id);
          _messages.insert(0, sms);
          _status = 'Aadhaar OTP from ${sms.sender}';
        });
        unawaited(_uploadOne(sms));
      },
    );
    setState(() => _listening = true);
  }

  Future<void> _uploadOne(SmsItem sms) async {
    if (_syncingIds.contains(sms.id)) return;
    setState(() => _syncingIds.add(sms.id));

    final err = await _sync.syncOne(sms);
    if (!mounted) return;

    setState(() {
      _syncingIds.remove(sms.id);
      final idx = _messages.indexWhere((m) => m.id == sms.id);
      if (idx >= 0) {
        _messages[idx] = _messages[idx].copyWith(
          synced: err == null,
          syncError: err,
        );
      }
      _status = err == null
          ? 'Synced SMS from ${sms.sender}'
          : 'Sync failed (queued): $err';
    });
  }

  Future<void> _uploadAll() async {
    setState(() => _status = 'Flushing pending + syncing list…');
    final flush = await _sync.flushPending();
    final pending = _messages.where((m) => !m.synced).toList();
    for (final sms in pending) {
      await _uploadOne(sms);
    }
    if (!mounted) return;
    setState(() {
      _status =
          'Sync done · flushed ${flush.ok}, failed ${flush.fail}, list pending ${pending.length}';
    });
    unawaited(ForegroundSmsService.askFlush());
  }

  Future<void> _openSettings() async {
    await openAppSettings();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('SMS Forwarder'),
        actions: [
          IconButton(
            tooltip: 'Refresh inbox',
            onPressed: _permissionGranted ? _refreshFromDevice : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          _StatusBanner(
            permissionGranted: _permissionGranted,
            listening: _listening,
            backgroundSyncOn: _backgroundSyncOn,
            status: _status,
            apiUrl: ApiConfig.smsUploadUrl,
          ),
          if (_loading)
            const LinearProgressIndicator(minHeight: 2)
          else
            const SizedBox(height: 2),
          Expanded(
            child: !_permissionGranted
                ? _EmptyState(
                    icon: Icons.sms_failed_outlined,
                    title: 'SMS permission needed',
                    subtitle:
                        'Allow SMS + Phone permission. On Xiaomi also enable Autostart for this app in Settings.',
                    actionLabel: 'Grant permission',
                    onAction: _bootstrap,
                    secondaryLabel: 'Open app settings',
                    onSecondary: _openSettings,
                  )
                : _messages.isEmpty
                    ? _EmptyState(
                        icon: Icons.inbox_outlined,
                        title: 'No SMS yet',
                        subtitle:
                            'Only UIDAI Aadhaar OTP SMS are shown & synced. Tap refresh after one arrives.',
                        actionLabel: 'Refresh',
                        onAction: _refreshFromDevice,
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                        itemCount: _messages.length,
                        separatorBuilder: (context, index) =>
                            const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final sms = _messages[index];
                          final syncing = _syncingIds.contains(sms.id);
                          return _SmsCard(
                            sms: sms,
                            syncing: syncing,
                            onUpload: () => _uploadOne(sms),
                          );
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton: _permissionGranted
          ? FloatingActionButton.extended(
              onPressed: _uploadAll,
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('Sync all'),
            )
          : null,
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            'Android only. Configure API in lib/config/api_config.dart',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.permissionGranted,
    required this.listening,
    required this.backgroundSyncOn,
    required this.status,
    required this.apiUrl,
  });

  final bool permissionGranted;
  final bool listening;
  final bool backgroundSyncOn;
  final String? status;
  final String apiUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Chip(
                label: permissionGranted ? 'SMS OK' : 'No SMS permission',
                ok: permissionGranted,
              ),
              _Chip(
                label: listening ? 'Listening' : 'Not listening',
                ok: listening,
              ),
              _Chip(
                label: backgroundSyncOn ? 'BG sync ON' : 'BG sync OFF',
                ok: backgroundSyncOn,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            status ?? '',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'API: $apiUrl',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.ok});

  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final color = ok ? Colors.teal : Colors.orange;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color.shade800,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SmsCard extends StatelessWidget {
  const _SmsCard({
    required this.sms,
    required this.syncing,
    required this.onUpload,
  });

  final SmsItem sms;
  final bool syncing;
  final VoidCallback onUpload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = sms.synced
        ? Colors.teal
        : (sms.syncError != null ? Colors.red : Colors.grey);

    return Card(
      elevation: 0,
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    sms.sender,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (syncing)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    sms.synced
                        ? Icons.cloud_done
                        : Icons.cloud_off_outlined,
                    size: 18,
                    color: statusColor,
                  ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Upload to server',
                  onPressed: syncing ? null : onUpload,
                  icon: const Icon(Icons.upload_outlined),
                ),
              ],
            ),
            if (sms.otp != null) ...[
              const SizedBox(height: 6),
              Text(
                'OTP: ${sms.otp}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
            const SizedBox(height: 6),
            Text(sms.body, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 8),
            Text(
              sms.receivedAt.toLocal().toString(),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (sms.syncError != null) ...[
              const SizedBox(height: 6),
              Text(
                sms.syncError!,
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.red),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
            if (secondaryLabel != null && onSecondary != null) ...[
              const SizedBox(height: 8),
              TextButton(onPressed: onSecondary, child: Text(secondaryLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
