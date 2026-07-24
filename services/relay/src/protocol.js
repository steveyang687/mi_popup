import { timingSafeEqual } from "node:crypto";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CHANNEL_PATTERN = /^[A-Za-z0-9_-]{8,64}$/;
const BASE64_PATTERN = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
const EVENT_FIELDS = new Set([
  "version",
  "channelId",
  "eventId",
  "sequence",
  "sentAt",
  "nonce",
  "ciphertext",
]);

export function validateServerConfig(config) {
  if (!CHANNEL_PATTERN.test(config.channelId ?? "")) {
    throw new Error("MIPOPUP_RELAY_CHANNEL_ID must be 8-64 URL-safe characters");
  }
  if (typeof config.token !== "string" || config.token.length < 32 || config.token.length > 256) {
    throw new Error("MIPOPUP_RELAY_TOKEN must be 32-256 characters");
  }
}

export function isAuthorized(header, expectedToken) {
  if (typeof header !== "string" || !header.startsWith("Bearer ")) return false;
  const actual = Buffer.from(header.slice(7), "utf8");
  const expected = Buffer.from(expectedToken, "utf8");
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

export function parseRelayEvent(value, expectedChannelId) {
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    throw new Error("body must be a JSON object");
  }
  const keys = Object.keys(value);
  if (keys.length !== EVENT_FIELDS.size || keys.some((key) => !EVENT_FIELDS.has(key))) {
    throw new Error("event fields do not match relay protocol v1");
  }
  if (value.version !== 1) throw new Error("unsupported relay version");
  if (value.channelId !== expectedChannelId) throw new Error("channelId does not match credential");
  if (!UUID_PATTERN.test(value.eventId ?? "")) throw new Error("invalid eventId");
  if (!Number.isSafeInteger(value.sequence) || value.sequence <= 0) {
    throw new Error("invalid sequence");
  }
  if (!Number.isSafeInteger(value.sentAt) || value.sentAt < 0) {
    throw new Error("invalid sentAt");
  }
  const nonce = decodeBase64(value.nonce, "nonce");
  if (nonce.length !== 12) throw new Error("nonce must be 12 bytes");
  const ciphertext = decodeBase64(value.ciphertext, "ciphertext");
  if (ciphertext.length < 17 || ciphertext.length > 24 * 1024) {
    throw new Error("ciphertext size is invalid");
  }
  return {
    version: 1,
    channelId: value.channelId,
    eventId: value.eventId,
    sequence: value.sequence,
    sentAt: value.sentAt,
    nonce: value.nonce,
    ciphertext: value.ciphertext,
  };
}

export function parseAcknowledgement(value) {
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    throw new Error("body must be a JSON object");
  }
  const keys = Object.keys(value);
  if (keys.length !== 1 || keys[0] !== "eventId" || !UUID_PATTERN.test(value.eventId ?? "")) {
    throw new Error("invalid acknowledgement");
  }
  return value.eventId;
}

function decodeBase64(value, field) {
  if (typeof value !== "string" || value.length === 0 || !BASE64_PATTERN.test(value)) {
    throw new Error(`${field} is not canonical base64`);
  }
  return Buffer.from(value, "base64");
}
