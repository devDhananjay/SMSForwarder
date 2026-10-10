# SMS Forwarder (Flutter)

Android app that:

1. Reads inbox SMS (with permission)
2. Listens for new incoming SMS
3. Posts each SMS to your server API

> **iOS:** Apple does not allow third-party apps to read the SMS inbox. This app is Android-only for SMS.

## Setup

```bash
cd ~/Desktop/SmsForwarderApp
flutter pub get
```

### 1) API (ContentVerse)

Already configured in `lib/config/api_config.dart`:

| API | Method | URL |
|-----|--------|-----|
| Fetch (ingest) | `POST` | `https://contentverse.co.in/sms-forwarder/api/sms/fetch` |
| List | `GET` | `https://contentverse.co.in/sms-forwarder/api/sms/list` |

Auth: `Authorization: Bearer <SMS_API_KEY>`

Server code + deploy script: `server/` (PM2 on ContentVerse EC2).

### 2) Expected API payload

`POST /api/sms/fetch` JSON:

```json
{
  "id": "12345",
  "sender": "+9198XXXXXXXX",
  "body": "801805 is OTP for Aadhaar (XX6761) (valid for 10 mins) at NSDL. … -UIDAI",
  "otp": "801805",
  "received_at": "2026-10-09T11:30:00.000Z",
  "timestamp_ms": 1760000000000
}
```

OTP is extracted when the body matches known formats (UIDAI Aadhaar, “OTP is …”, etc.).

### 3) Run on Android device

```bash
flutter run
```

Grant **SMS** permission when asked.

## What it does

| Action | Behavior |
|--------|----------|
| App open | Requests SMS permission, loads recent inbox |
| New SMS | Appears in list and auto-uploads to API |
| Sync all | Uploads any not-yet-synced messages |
| Per SMS upload | Tap cloud icon on a card |

## Project layout

```
lib/
  config/api_config.dart      # server URL
  models/sms_item.dart
  services/sms_reader_service.dart
  services/sms_api_service.dart
  main.dart
```

## Permissions (Android)

- `READ_SMS`
- `RECEIVE_SMS`
- `INTERNET`
