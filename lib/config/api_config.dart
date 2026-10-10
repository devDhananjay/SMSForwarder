/// ContentVerse SMS Forwarder API (deployed on contentverse.co.in).
class ApiConfig {
  /// Must be https:// (http:// on port 443 causes nginx 400).
  static const String baseUrl = 'https://contentverse.co.in/sms-forwarder';

  /// Optional plain HTTP direct to Node (only if SG opens TCP 3011).
  /// Example: 'http://52.66.204.66:3011'
  static const String directBaseUrl = '';

  /// Set at runtime after a successful health/upload.
  static String? activeBaseUrl;

  static String get smsUploadUrl =>
      '${activeBaseUrl ?? baseUrl}/api/sms/fetch';

  static String get smsListUrl => '${activeBaseUrl ?? baseUrl}/api/sms/list';

  static const String apiKey = 'smsfwd_7f3a9c2e1b8d4e6a0c5f9d2b7e4a1c8f';

  static const int inboxLimit = 50;
}
