import http from "node:http";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { WebSocket, WebSocketServer } from "ws";
import {
  isAuthorized,
  parseAcknowledgement,
  parseRelayEvent,
  validateServerConfig,
} from "./protocol.js";

const MAX_BODY_BYTES = 32 * 1024;

export function createRelayServer(options) {
  const config = {
    host: options.host ?? "127.0.0.1",
    port: options.port ?? 8787,
    channelId: options.channelId,
    token: options.token,
    databasePath: options.databasePath,
    retentionMillis: options.retentionMillis ?? 7 * 24 * 60 * 60 * 1000,
    maxEvents: options.maxEvents ?? 1000,
  };
  validateServerConfig(config);
  if (!config.databasePath) throw new Error("databasePath is required");
  if (!Number.isInteger(config.maxEvents) || config.maxEvents < 1) {
    throw new Error("maxEvents must be positive");
  }

  mkdirSync(dirname(config.databasePath), { recursive: true });
  const database = new DatabaseSync(config.databasePath);
  database.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL;");
  database.exec(`
    CREATE TABLE IF NOT EXISTS relay_events (
      channel_id TEXT NOT NULL,
      event_id TEXT NOT NULL,
      sequence INTEGER NOT NULL,
      sent_at INTEGER NOT NULL,
      nonce TEXT NOT NULL,
      ciphertext TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      PRIMARY KEY (channel_id, event_id)
    );
    CREATE INDEX IF NOT EXISTS relay_events_created_at
      ON relay_events(channel_id, created_at, sequence);
  `);

  const insertEvent = database.prepare(`
    INSERT OR IGNORE INTO relay_events
      (channel_id, event_id, sequence, sent_at, nonce, ciphertext, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  `);
  const selectEvents = database.prepare(`
    SELECT channel_id, event_id, sequence, sent_at, nonce, ciphertext
    FROM relay_events
    WHERE channel_id = ?
    ORDER BY created_at ASC, sequence ASC
  `);
  const deleteEvent = database.prepare(
    "DELETE FROM relay_events WHERE channel_id = ? AND event_id = ?"
  );
  const deleteExpired = database.prepare(
    "DELETE FROM relay_events WHERE channel_id = ? AND created_at < ?"
  );
  const deleteOverflow = database.prepare(`
    DELETE FROM relay_events
    WHERE rowid IN (
      SELECT rowid FROM relay_events
      WHERE channel_id = ?
      ORDER BY created_at DESC, sequence DESC
      LIMIT -1 OFFSET ?
    )
  `);

  const clients = new Set();
  const webSockets = new WebSocketServer({ noServer: true, maxPayload: MAX_BODY_BYTES });
  webSockets.on("connection", (socket) => {
    cleanup();
    clients.add(socket);
    socket.on("close", () => clients.delete(socket));
    socket.on("error", () => clients.delete(socket));
    for (const row of selectEvents.all(config.channelId)) {
      if (socket.readyState !== WebSocket.OPEN) break;
      socket.send(JSON.stringify(rowToEvent(row)));
    }
  });

  const server = http.createServer(async (request, response) => {
    const url = new URL(request.url ?? "/", "http://relay.invalid");
    if (request.method === "GET" && url.pathname === "/healthz") {
      return json(response, 200, { status: "ok" });
    }
    if (!isAuthorized(request.headers.authorization, config.token)) {
      return json(response, 401, { error: "unauthorized" });
    }

    try {
      if (request.method === "POST" && url.pathname === "/v1/events") {
        const event = parseRelayEvent(await readJSON(request), config.channelId);
        cleanup();
        const result = insertEvent.run(
          event.channelId,
          event.eventId,
          event.sequence,
          event.sentAt,
          event.nonce,
          event.ciphertext,
          Date.now()
        );
        cleanup();
        if (Number(result.changes) > 0) broadcast(event);
        return json(response, 200, {
          eventId: event.eventId,
          status: Number(result.changes) > 0 ? "accepted" : "duplicate",
        });
      }
      if (request.method === "POST" && url.pathname === "/v1/acks") {
        const eventId = parseAcknowledgement(await readJSON(request));
        const result = deleteEvent.run(config.channelId, eventId);
        return json(response, 200, {
          eventId,
          status: Number(result.changes) > 0 ? "acknowledged" : "not_found",
        });
      }
      return json(response, 404, { error: "not_found" });
    } catch (error) {
      const message = error instanceof Error ? error.message : "invalid request";
      return json(response, message === "request body too large" ? 413 : 400, { error: message });
    }
  });

  server.on("upgrade", (request, socket, head) => {
    const url = new URL(request.url ?? "/", "http://relay.invalid");
    if (url.pathname !== "/v1/stream") {
      return rejectUpgrade(socket, "404 Not Found");
    }
    if (!isAuthorized(request.headers.authorization, config.token)) {
      return rejectUpgrade(socket, "401 Unauthorized");
    }
    webSockets.handleUpgrade(request, socket, head, (webSocket) => {
      webSockets.emit("connection", webSocket, request);
    });
  });

  function cleanup() {
    deleteExpired.run(config.channelId, Date.now() - config.retentionMillis);
    deleteOverflow.run(config.channelId, config.maxEvents);
  }

  function broadcast(event) {
    const payload = JSON.stringify(event);
    for (const socket of clients) {
      if (socket.readyState === WebSocket.OPEN) socket.send(payload);
    }
  }

  return {
    async start() {
      cleanup();
      await new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(config.port, config.host, () => {
          server.off("error", reject);
          resolve();
        });
      });
      return server.address();
    },
    async close() {
      for (const socket of clients) socket.close(1001, "server shutdown");
      await new Promise((resolve) => webSockets.close(resolve));
      await new Promise((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      });
      database.close();
    },
  };
}

function rowToEvent(row) {
  return {
    version: 1,
    channelId: row.channel_id,
    eventId: row.event_id,
    sequence: Number(row.sequence),
    sentAt: Number(row.sent_at),
    nonce: row.nonce,
    ciphertext: row.ciphertext,
  };
}

async function readJSON(request) {
  let size = 0;
  const chunks = [];
  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) throw new Error("request body too large");
    chunks.push(chunk);
  }
  if (size === 0) throw new Error("request body is empty");
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new Error("request body is not valid JSON");
  }
}

function json(response, statusCode, body) {
  const payload = Buffer.from(JSON.stringify(body));
  response.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "content-length": payload.length,
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
  });
  response.end(payload);
}

function rejectUpgrade(socket, status) {
  socket.write(`HTTP/1.1 ${status}\r\nConnection: close\r\n\r\n`);
  socket.destroy();
}
