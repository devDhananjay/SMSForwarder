import http from "node:http";
import { URL } from "node:url";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 3011);
const HOST = process.env.HOST || "0.0.0.0";
const API_KEY = (process.env.SMS_API_KEY || "").trim();
const DATA_DIR = process.env.SMS_DATA_DIR || path.join(__dirname, "data");
const DATA_FILE = path.join(DATA_DIR, "messages.json");
const MAX_MESSAGES = Number(process.env.SMS_MAX_MESSAGES || 2000);

fs.mkdirSync(DATA_DIR, { recursive: true });
if (!fs.existsSync(DATA_FILE)) {
  fs.writeFileSync(DATA_FILE, "[]\n", "utf8");
}

function readAll() {
  try {
    const raw = fs.readFileSync(DATA_FILE, "utf8");
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function writeAll(list) {
  try {
    const tmp = `${DATA_FILE}.tmp`;
    fs.writeFileSync(tmp, `${JSON.stringify(list, null, 2)}\n`, "utf8");
    fs.renameSync(tmp, DATA_FILE);
  } catch (e) {
    const err = new Error(`DISK_WRITE_FAILED: ${e.message}`);
    err.code = "ENOSPC";
    throw err;
  }
}

function sendJson(res, status, body) {
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Cache-Control": "no-store",
  });
  res.end(JSON.stringify(body));
}

function unauthorized(res) {
  sendJson(res, 401, {
    ok: false,
    error: { code: "UNAUTHORIZED", message: "Invalid or missing API key" },
  });
}

function checkAuth(req) {
  if (!API_KEY) return true; // open if unset (local only)
  const header = req.headers.authorization || "";
  if (header === `Bearer ${API_KEY}`) return true;
  const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
  return url.searchParams.get("api_key") === API_KEY;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > 1_000_000) {
        reject(new Error("Body too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      if (!raw.trim()) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(raw));
      } catch {
        reject(new Error("Invalid JSON"));
      }
    });
    req.on("error", reject);
  });
}

function normalizeSms(input) {
  const now = Date.now();
  const sender = String(input.sender ?? input.address ?? "Unknown").trim() || "Unknown";
  const body = String(input.body ?? input.message ?? "").trim();
  const receivedAt =
    input.received_at ||
    (input.timestamp_ms
      ? new Date(Number(input.timestamp_ms)).toISOString()
      : new Date(now).toISOString());
  const timestampMs = Number(input.timestamp_ms) || Date.parse(receivedAt) || now;
  const id =
    String(input.id ?? "").trim() ||
    `${sender}|${timestampMs}|${Buffer.from(body).toString("base64url").slice(0, 16)}`;

  return {
    id,
    sender,
    body,
    otp: input.otp ? String(input.otp) : null,
    device_id: input.device_id ? String(input.device_id) : null,
    received_at: receivedAt,
    timestamp_ms: timestampMs,
    stored_at: new Date().toISOString(),
  };
}

async function handleFetch(req, res) {
  if (!checkAuth(req)) return unauthorized(res);
  let payload;
  try {
    payload = await readBody(req);
  } catch (e) {
    return sendJson(res, 400, {
      ok: false,
      error: { code: "BAD_REQUEST", message: e.message || "Invalid body" },
    });
  }

  const sms = normalizeSms(payload);
  if (!sms.body) {
    return sendJson(res, 400, {
      ok: false,
      error: { code: "MISSING_BODY", message: "body is required" },
    });
  }

  const list = readAll();
  const idx = list.findIndex((m) => m.id === sms.id);
  if (idx >= 0) {
    list[idx] = { ...list[idx], ...sms, stored_at: list[idx].stored_at };
  } else {
    list.unshift(sms);
  }
  try {
    writeAll(list.slice(0, MAX_MESSAGES));
  } catch (e) {
    console.error("[sms-forwarder-api] write failed:", e);
    return sendJson(res, 507, {
      ok: false,
      error: {
        code: "STORAGE_FULL",
        message: "Server disk full — cannot save SMS. Contact admin.",
      },
    });
  }

  return sendJson(res, 200, { ok: true, sms });
}

function handleList(req, res) {
  if (!checkAuth(req)) return unauthorized(res);
  const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
  const limit = Math.min(Number(url.searchParams.get("limit") || 50), 500);
  const offset = Math.max(Number(url.searchParams.get("offset") || 0), 0);
  const sender = (url.searchParams.get("sender") || "").trim().toLowerCase();
  const q = (url.searchParams.get("q") || "").trim().toLowerCase();

  let list = readAll();
  if (sender) {
    list = list.filter((m) => String(m.sender).toLowerCase().includes(sender));
  }
  if (q) {
    list = list.filter(
      (m) =>
        String(m.body).toLowerCase().includes(q) ||
        String(m.otp || "").toLowerCase().includes(q) ||
        String(m.sender).toLowerCase().includes(q)
    );
  }

  const total = list.length;
  const items = list.slice(offset, offset + limit);
  return sendJson(res, 200, { ok: true, total, limit, offset, items });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
  const pathname = url.pathname.replace(/\/+$/, "") || "/";

  if (req.method === "OPTIONS") {
    return sendJson(res, 204, {});
  }

  if (pathname === "/health" && req.method === "GET") {
    return sendJson(res, 200, {
      ok: true,
      service: "sms-forwarder-api",
      count: readAll().length,
    });
  }

  // POST /api/sms/fetch  (also accept /fetch)
  if (
    req.method === "POST" &&
    (pathname === "/api/sms/fetch" || pathname === "/fetch")
  ) {
    return handleFetch(req, res);
  }

  // GET /api/sms/list  (also accept /list)
  if (
    req.method === "GET" &&
    (pathname === "/api/sms/list" || pathname === "/list")
  ) {
    return handleList(req, res);
  }

  return sendJson(res, 404, {
    ok: false,
    error: {
      code: "NOT_FOUND",
      message: "Use POST /api/sms/fetch or GET /api/sms/list",
    },
  });
});

server.listen(PORT, HOST, () => {
  console.log(`[sms-forwarder-api] listening on http://${HOST}:${PORT}`);
  console.log(`[sms-forwarder-api] auth ${API_KEY ? "enabled" : "DISABLED (set SMS_API_KEY)"}`);
});
