/// Extracts OTP only from UIDAI / Aadhaar SMS formats.
///
/// Example:
/// `801805 is OTP for Aadhaar (XX6761) (valid for 10 mins) at NSDL.
///  Send SMS to 1947/visit uidai.gov.in to lock/unlock your biometrics -UIDAI`
class OtpParser {
  OtpParser._();

  /// Must look like Aadhaar OTP SMS (not bank/other OTPs).
  static final RegExp _aadhaarSms = RegExp(
    r'(?=.*\bAadhaar\b)(?=.*\bOTP\b).*\b(?:UIDAI|NSDL|uidai\.gov\.in)\b',
    caseSensitive: false,
    dotAll: true,
  );

  /// Prefer: "801805 is OTP for Aadhaar"
  static final RegExp _otpForAadhaar = RegExp(
    r'\b(\d{4,8})\s+is\s+OTP\s+for\s+Aadhaar\b',
    caseSensitive: false,
  );

  /// Fallback inside confirmed Aadhaar SMS: "OTP is 801805" / "OTP: 801805"
  static final RegExp _otpGeneric = RegExp(
    r'\bOTP\s*(?:is\s*)?[:\-]?\s*(\d{4,8})\b',
    caseSensitive: false,
  );

  /// True only for Aadhaar / UIDAI OTP messages — ignore everything else.
  static bool isAadhaarOtpSms(String? body) {
    if (body == null || body.trim().isEmpty) return false;
    final text = body.trim();
    if (!_aadhaarSms.hasMatch(text)) return false;
    return extract(text) != null;
  }

  /// Returns OTP digits from an Aadhaar SMS, or null.
  static String? extract(String? body) {
    if (body == null || body.trim().isEmpty) return null;
    final text = body.trim();

    // Strict path: require Aadhaar + UIDAI/NSDL markers.
    if (!_aadhaarSms.hasMatch(text)) return null;

    final specific = _otpForAadhaar.firstMatch(text);
    if (specific != null) {
      final code = specific.group(1);
      if (code != null && code.isNotEmpty) return code;
    }

    final generic = _otpGeneric.firstMatch(text);
    final code = generic?.group(1);
    if (code != null && code.isNotEmpty) return code;
    return null;
  }

  static bool hasOtp(String? body) => extract(body) != null;
}
