import http from "node:http";
import fs from "node:fs";
import path from "node:path";

const port = Number(process.env.PORT || 8080);
const dataDir = process.env.DATA_DIR || "/data";
const dataFile = path.join(dataDir, "queue.json");
const relayToken = process.env.RELAY_TOKEN || "";
const maxPacketBytes = 256 * 1024;
const maxQueueAge = 7 * 24 * 60 * 60 * 1000;

fs.mkdirSync(dataDir, { recursive: true });
let queues = new Map();

try {
  const saved = JSON.parse(fs.readFileSync(dataFile, "utf8"));
  queues = new Map(Object.entries(saved));
} catch {}

function persist() {
  const temporary = `${dataFile}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(Object.fromEntries(queues)));
  fs.renameSync(temporary, dataFile);
}

function authorized(request) {
  return !relayToken || request.headers.authorization === `Bearer ${relayToken}`;
}

function json(response, status, value) {
  response.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" });
  response.end(JSON.stringify(value));
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    let body = "";
    request.on("data", chunk => {
      body += chunk;
      if (Buffer.byteLength(body) > maxPacketBytes) request.destroy();
    });
    request.on("end", () => resolve(body));
    request.on("error", reject);
  });
}

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url, `http://${request.headers.host || "localhost"}`);
  if (request.method === "GET" && url.pathname === "/health") return json(response, 200, { ok: true });
  if (!authorized(request)) return json(response, 401, { error: "unauthorized" });

  if (request.method === "POST" && url.pathname === "/v1/messages") {
    try {
      const packet = JSON.parse(await readBody(request));
      if (!packet.id || !packet.to || !packet.from || !packet.ciphertext || !packet.senderPublicKey) {
        return json(response, 400, { error: "invalid packet" });
      }
      const queue = queues.get(packet.to) || [];
      if (!queue.some(item => item.id === packet.id)) queue.push({ ...packet, queuedAt: Date.now() });
      queues.set(packet.to, queue.filter(item => Date.now() - item.queuedAt < maxQueueAge));
      persist();
      return json(response, 202, { queued: true });
    } catch {
      return json(response, 400, { error: "invalid json" });
    }
  }

  const match = url.pathname.match(/^\/v1\/messages\/([A-Za-z0-9_-]+)$/);
  if (request.method === "GET" && match) {
    const device = match[1];
    const queue = (queues.get(device) || []).filter(item => Date.now() - item.queuedAt < maxQueueAge);
    queues.set(device, []);
    persist();
    return json(response, 200, queue);
  }

  json(response, 404, { error: "not found" });
});

server.listen(port, "0.0.0.0", () => console.log(`EndChat relay listening on ${port}`));
