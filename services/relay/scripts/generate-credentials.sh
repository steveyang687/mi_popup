#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 relay.example.com [output-directory]" >&2
  exit 64
fi

domain=$1
output_directory=${2:-generated}
case "$domain" in
  *[!A-Za-z0-9.-]*|.*|*.)
    echo "Invalid relay domain: $domain" >&2
    exit 64
    ;;
esac

command -v openssl >/dev/null 2>&1 || {
  echo "openssl is required" >&2
  exit 69
}

umask 077
mkdir -p "$output_directory"
channel_id="channel_$(openssl rand -hex 16)"
token=$(openssl rand -base64 48 | tr -d '\n')
encryption_key=$(openssl rand -base64 32 | tr -d '\n')

printf '%s\n' \
  "MIPOPUP_RELAY_DOMAIN=$domain" \
  "MIPOPUP_RELAY_CHANNEL_ID=$channel_id" \
  "MIPOPUP_RELAY_TOKEN=$token" \
  "MIPOPUP_RELAY_RETENTION_HOURS=168" \
  "MIPOPUP_RELAY_MAX_EVENTS=1000" \
  > "$output_directory/server.env"

printf '%s\n' \
  '{' \
  "  \"baseURL\": \"https://$domain\"," \
  "  \"channelId\": \"$channel_id\"," \
  "  \"token\": \"$token\"," \
  "  \"encryptionKey\": \"$encryption_key\"" \
  '}' \
  > "$output_directory/client-config.json"

chmod 600 "$output_directory/server.env" "$output_directory/client-config.json"
echo "Created $output_directory/server.env and $output_directory/client-config.json"
echo "Keep both files private. The encryption key is intentionally absent from server.env."
