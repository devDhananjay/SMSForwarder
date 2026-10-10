class SmsItem {
  const SmsItem({
    required this.id,
    required this.sender,
    required this.body,
    required this.receivedAt,
    this.otp,
    this.synced = false,
    this.syncError,
  });

  final String id;
  final String sender;
  final String body;
  final DateTime receivedAt;
  /// Extracted OTP when the body matches a known format (e.g. UIDAI Aadhaar).
  final String? otp;
  final bool synced;
  final String? syncError;

  Map<String, dynamic> toApiPayload({String? deviceId}) {
    return {
      'id': id,
      'sender': sender,
      'body': body,
      'received_at': receivedAt.toUtc().toIso8601String(),
      'timestamp_ms': receivedAt.millisecondsSinceEpoch,
      if (otp != null && otp!.isNotEmpty) 'otp': otp,
      if (deviceId != null && deviceId.isNotEmpty) 'device_id': deviceId,
    };
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'sender': sender,
      'body': body,
      'received_at_ms': receivedAt.millisecondsSinceEpoch,
      'otp': otp,
      'synced': synced,
      'sync_error': syncError,
    };
  }

  factory SmsItem.fromJson(Map<String, dynamic> json) {
    return SmsItem(
      id: json['id'] as String? ?? '',
      sender: json['sender'] as String? ?? 'Unknown',
      body: json['body'] as String? ?? '',
      receivedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['received_at_ms'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      ),
      otp: json['otp'] as String?,
      synced: json['synced'] as bool? ?? false,
      syncError: json['sync_error'] as String?,
    );
  }

  SmsItem copyWith({
    String? otp,
    bool? synced,
    String? syncError,
  }) {
    return SmsItem(
      id: id,
      sender: sender,
      body: body,
      receivedAt: receivedAt,
      otp: otp ?? this.otp,
      synced: synced ?? this.synced,
      syncError: syncError,
    );
  }
}
