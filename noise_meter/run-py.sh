#!/usr/bin/env bash
set -euo pipefail

MQTT_HOST=$(jq -r '.mqtt_host' /data/options.json)
MQTT_PORT=$(jq -r '.mqtt_port' /data/options.json)
MQTT_PREFIX=$(jq -r '.mqtt_prefix' /data/options.json)
MQTT_USER=$(jq -r '.mqtt_username' /data/options.json)
MQTT_PASS=$(jq -r '.mqtt_password' /data/options.json)

P_ON=$(jq -r '.presence_on_db' /data/options.json)
P_OFF=$(jq -r '.presence_off_db' /data/options.json)
W_P=$(jq -r '.presence_window_s' /data/options.json)
W_N=$(jq -r '.noise_window_s' /data/options.json)

HOP_S=$(jq -r '.hop_s' /data/options.json)
AUDIO_DEVICE=$(jq -r '.audio_device' /data/options.json)
SAMPLE_RATE=$(jq -r '.sample_rate' /data/options.json)

echo "Noise Meter started. device=${AUDIO_DEVICE}, rate=${SAMPLE_RATE}, hop=${HOP_S}s v1"

exec python3 /noise_stream.py \
  --device "$AUDIO_DEVICE" \
  --rate "$SAMPLE_RATE" \
  --hop "$HOP_S" \
  --noise-window "$W_N" \
  --presence-window "$W_P" \
  --p-on "$P_ON" \
  --p-off "$P_OFF" \
  --mqtt-host "$MQTT_HOST" --mqtt-port "$MQTT_PORT" \
  --mqtt-user "$MQTT_USER" --mqtt-pass "$MQTT_PASS" \
  --mqtt-prefix "$MQTT_PREFIX"
