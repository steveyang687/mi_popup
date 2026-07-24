import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { WebSocket } from "ws";
import { createRelayServer } from "../src/server.js";

const CHANNEL = "personal_channel_01";
const TOKEN = "test-token-that-is-at-least-thirty-two-characters";
const EVENT = {
  version: 1,
  channelId: CHANNEL,
  eventId: "11111111-1111-4111-8111-111111111111",
  sequence: 7,
  sentAt: 42,
  nonce: Buffer.alloc(12, 1).toString("base64"),
  ciphertext: Buffer.alloc(32, 2).toString("base64"),
};

test("stores ciphertext, streams backlog, and removes acknowledged events", async () => {
  const directory = mkdtempSync(join(tmpdir(), "mipopup-relay-"));
  const relay = createRelayServer({
    host: "127.0.0.1",
    port: 0,
    channelId: CHANNEL,
    token: TOKEN,
    databasePath: join(directory, "relay.sqlite"),
  });
  const address = await relay.start();
  const baseURL = `http://127.0.0.1:${address.port}`;
  try {
    const unauthorized = await fetch(`${baseURL}/v1/events`, {
      method: "POST",
      body: JSON.stringify(EVENT),
    });
    assert.equal(unauthorized.status, 401);

    const accepted = await post(baseURL, "/v1/events", EVENT);
    assert.equal(accepted.status, 200);
    assert.deepEqual(await accepted.json(), { eventId: EVENT.eventId, status: "accepted" });

    const duplicate = await post(baseURL, "/v1/events", EVENT);
    assert.deepEqual(await duplicate.json(), { eventId: EVENT.eventId, status: "duplicate" });

    const received = await receiveOne(`ws://127.0.0.1:${address.port}/v1/stream`);
    assert.deepEqual(received, EVENT);

    const acknowledged = await post(baseURL, "/v1/acks", { eventId: EVENT.eventId });
    assert.deepEqual(await acknowledged.json(), {
      eventId: EVENT.eventId,
      status: "acknowledged",
    });
    const alreadyGone = await post(baseURL, "/v1/acks", { eventId: EVENT.eventId });
    assert.deepEqual(await alreadyGone.json(), {
      eventId: EVENT.eventId,
      status: "not_found",
    });
  } finally {
    await relay.close();
    rmSync(directory, { recursive: true, force: true });
  }
});

test("rejects plaintext and malformed relay envelopes", async () => {
  const directory = mkdtempSync(join(tmpdir(), "mipopup-relay-"));
  const relay = createRelayServer({
    host: "127.0.0.1",
    port: 0,
    channelId: CHANNEL,
    token: TOKEN,
    databasePath: join(directory, "relay.sqlite"),
  });
  const address = await relay.start();
  try {
    const response = await post(`http://127.0.0.1:${address.port}`, "/v1/events", {
      ...EVENT,
      plaintext: "must not be accepted",
    });
    assert.equal(response.status, 400);
  } finally {
    await relay.close();
    rmSync(directory, { recursive: true, force: true });
  }
});

function post(baseURL, path, body) {
  return fetch(`${baseURL}${path}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${TOKEN}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

function receiveOne(url) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url, { headers: { authorization: `Bearer ${TOKEN}` } });
    const timeout = setTimeout(() => {
      socket.terminate();
      reject(new Error("timed out waiting for relay event"));
    }, 2_000);
    socket.once("message", (data) => {
      clearTimeout(timeout);
      socket.close();
      resolve(JSON.parse(data.toString("utf8")));
    });
    socket.once("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
  });
}
