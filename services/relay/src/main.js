import { createRelayServer } from "./server.js";

const server = createRelayServer({
  host: process.env.MIPOPUP_RELAY_HOST ?? "127.0.0.1",
  port: numberFromEnvironment("MIPOPUP_RELAY_PORT", 8787),
  channelId: process.env.MIPOPUP_RELAY_CHANNEL_ID,
  token: process.env.MIPOPUP_RELAY_TOKEN,
  databasePath: process.env.MIPOPUP_RELAY_DATABASE ?? "/var/lib/mipopup-relay/relay.sqlite",
  retentionMillis: numberFromEnvironment("MIPOPUP_RELAY_RETENTION_HOURS", 168) * 60 * 60 * 1000,
  maxEvents: numberFromEnvironment("MIPOPUP_RELAY_MAX_EVENTS", 1000),
});

const address = await server.start();
console.log(`MiPopup Relay listening on ${address.address}:${address.port}`);

let stopping = false;
async function stop(signal) {
  if (stopping) return;
  stopping = true;
  console.log(`MiPopup Relay received ${signal}; shutting down`);
  await server.close();
}

process.on("SIGTERM", () => stop("SIGTERM").then(() => process.exit(0)));
process.on("SIGINT", () => stop("SIGINT").then(() => process.exit(0)));

function numberFromEnvironment(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined) return fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value <= 0) throw new Error(`${name} must be positive`);
  return value;
}
