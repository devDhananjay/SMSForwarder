import 'package:flutter_test/flutter_test.dart';
import 'package:sms_forwarder/utils/otp_parser.dart';

void main() {
  group('OtpParser', () {
    test('extracts UIDAI Aadhaar OTP format', () {
      const body =
          '801805 is OTP for Aadhaar (XX6761) (valid for 10 mins) at NSDL. '
          'Send SMS to 1947/visit uidai.gov.in to lock/unlock your biometrics -UIDAI';
      expect(OtpParser.extract(body), '801805');
    });

    test('extracts "OTP is" format', () {
      expect(OtpParser.extract('Your OTP is 123456'), '123456');
    });

    test('extracts "is OTP" format', () {
      expect(OtpParser.extract('654321 is your OTP for login'), '654321');
    });

    test('returns null when no OTP', () {
      expect(OtpParser.extract('Hello, how are you?'), isNull);
    });
  });
}
