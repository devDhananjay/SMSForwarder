#!/usr/bin/env bash
# Deploy sms-forwarder-api to ContentVerse EC2 and wire nginx.
set -euo pipefail

PEM="${PEM:-$HOME/Downloads/content.pem}"
HOST="${HOST:-ec2-user@52.66.204.66}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
REMOTE_DIR="/home/ec2-user/sms-forwarder-api"

echo "==> Free a little disk + ensure remote dir"
ssh -i "$PEM" -o StrictHostKeyChecking=no "$HOST" bash <<'REMOTE'
set -euo pipefail
pm2 flush || true
rm -rf "$HOME/.npm/_cacache" || true
mkdir -p "$HOME/sms-forwarder-api/data"
df -h /
REMOTE

echo "==> Upload API files"
rsync -az -e "ssh -i $PEM -o StrictHostKeyChecking=no" \
  "$ROOT/server.mjs" \
  "$ROOT/package.json" \
  "$ROOT/ecosystem.config.cjs" \
  "$HOST:$REMOTE_DIR/"

echo "==> Start / restart PM2 process"
ssh -i "$PEM" -o StrictHostKeyChecking=no "$HOST" bash <<'REMOTE'
set -euo pipefail
cd "$HOME/sms-forwarder-api"
if pm2 describe sms-forwarder-api >/dev/null 2>&1; then
  pm2 restart ecosystem.config.cjs --only sms-forwarder-api --update-env
else
  pm2 start ecosystem.config.cjs
fi
pm2 save || true
sleep 1
curl -sS "http://127.0.0.1:3011/health" || true
echo
REMOTE

echo "==> Ensure nginx location /sms-forwarder/"
ssh -i "$PEM" -o StrictHostKeyChecking=no "$HOST" bash <<'REMOTE'
set -euo pipefail
CONF="/etc/nginx/conf.d/contentverse.conf"
if sudo grep -q 'location /sms-forwarder/' "$CONF"; then
  echo "nginx location already present"
else
  sudo python3 - <<'PY'
from pathlib import Path
path = Path("/etc/nginx/conf.d/contentverse.conf")
text = path.read_text()
needle = "    # vehicle-inspect-api (PM2 :3010)"
block = """    # sms-forwarder-api (PM2 :3011)
    location /sms-forwarder/ {
        proxy_pass http://127.0.0.1:3011/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 15s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

"""
if "location /sms-forwarder/" in text:
    print("already present")
else:
    if needle not in text:
        raise SystemExit("anchor not found in nginx conf")
    path.write_text(text.replace(needle, block + needle, 1))
    print("nginx location inserted")
PY
  sudo nginx -t
  sudo systemctl reload nginx
fi
REMOTE

echo "==> Public smoke tests"
curl -sS "https://contentverse.co.in/sms-forwarder/health"
echo
curl -sS -X POST "https://contentverse.co.in/sms-forwarder/api/sms/fetch" \
  -H "Authorization: Bearer smsfwd_7f3a9c2e1b8d4e6a0c5f9d2b7e4a1c8f" \
  -H "Content-Type: application/json" \
  -d '{"id":"deploy-smoke","sender":"SYSTEM","body":"deploy ok","otp":null}'
echo
curl -sS "https://contentverse.co.in/sms-forwarder/api/sms/list?limit=3" \
  -H "Authorization: Bearer smsfwd_7f3a9c2e1b8d4e6a0c5f9d2b7e4a1c8f"
echo
echo "==> Deploy done"
