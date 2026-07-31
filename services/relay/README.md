# MiPopup Personal Relay

MiPopup Relay receives encrypted delivery events from Android over HTTPS and streams them to macOS over WSS. The VPS stores only opaque AES-256-GCM ciphertext. It never receives the content encryption key.

## Prerequisites

- A VPS with a public IPv4 or IPv6 address
- A domain such as `relay.example.com` whose A/AAAA record points to the VPS
- Docker Engine with the Compose plugin
- Public inbound TCP 80/443 and UDP 443; do not expose port 8787

## Generate credentials on your trusted Mac

Run the generator locally, not on the VPS. This keeps the E2EE content key off the server from the beginning:

```bash
cd services/relay
chmod +x scripts/generate-credentials.sh
./scripts/generate-credentials.sh relay.example.com
```

Keep `generated/client-config.json` on your trusted devices. Transfer only `generated/server.env` to the VPS, for example with `scp`.

## Deploy on the VPS

After copying the `services/relay` directory and `server.env` to the VPS:

```bash
cd services/relay
mv /path/to/uploaded/server.env .env
docker compose up -d --build
docker compose ps
curl https://relay.example.com/healthz
```

Caddy obtains and renews the TLS certificate automatically. The Relay container is reachable only on the private Compose network; Caddy is the sole public entry point.

Expected health response:

```json
{"status":"ok"}
```

## Configure Android and macOS

The locally generated `generated/client-config.json` is the same pairing file for both clients. Transfer it through a private end-to-end encrypted channel. Never upload it to the VPS, commit it, or paste it into issue trackers.

Android:

1. Open **MiPopup 通知采集**.
2. Paste the whole JSON into **个人 VPS 中继**.
3. Tap **保存中继配置并立即同步**.

macOS:

1. Expand MiPopup and open **中继**, or choose **配置公网中继…** from the menu bar.
2. Paste the whole JSON and select **保存并连接**.
3. Confirm that the status changes to **已连接公网中继**.

MiPopup keeps the current JSON visible for editing, validates it before replacing the existing configuration, and stores the file with mode `0600`. LAN delivery remains enabled in parallel; `eventId` deduplication prevents duplicate UI updates.

## Operations

```bash
# Follow logs; logs contain no credentials or event bodies.
docker compose logs -f --tail=200 relay caddy

# Upgrade after pulling a new source revision.
docker compose up -d --build

# Stop without deleting queued ciphertext or TLS state.
docker compose down

# Back up the named SQLite volume (ciphertext only).
docker run --rm -v relay_relay-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/mipopup-relay-data.tgz -C /data .
```

Events are deleted as soon as macOS acknowledges them. Unacknowledged ciphertext is retained for 168 hours by default, with a maximum of 1000 events. Change the two retention values in `.env` and restart the stack if necessary.

To revoke the current pairing, generate a new credential set on a trusted client, upload only the new `server.env`, redeploy, and update both clients. Old clients immediately lose access. The server credential and E2EE content key are deliberately separate: the content key appears only in `client-config.json`.
