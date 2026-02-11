#!/usr/bin/env bash
set -euo pipefail

MQTT_HOST=$(jq -r '.mqtt_host' /data/options.json)
MQTT_PORT=$(jq -r '.mqtt_port' /data/options.json)
MQTT_PREFIX=$(jq -r '.mqtt_prefix' /data/options.json)
MQTT_USER=$(jq -r '.mqtt_username' /data/options.json)
MQTT_PASS=$(jq -r '.mqtt_password' /data/options.json)

DEVICE_ID="noise_meter_usb"
DEVICE_NAME="Noise Meter (USB mic)"
DISCOVERY_PREFIX="homeassistant"

pub() {
  mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$1" -m "$2" -r
}

# avg noise sensor
pub "$DISCOVERY_PREFIX/sensor/$DEVICE_ID/avg_db/config" "$(jq -nc \
  --arg name "Noise level (avg)" \
  --arg uid "${DEVICE_ID}_avg" \
  --arg topic "$MQTT_PREFIX/avg_db" \
  --arg dev "$DEVICE_ID" \
  --arg dname "$DEVICE_NAME" \
  '{
    name: $name,
    unique_id: $uid,
    state_topic: $topic,
    unit_of_measurement: "dB",
    device_class: "sound_pressure",
    device: { identifiers: [$dev], name: $dname }
  }'
)"

# max noise sensor
pub "$DISCOVERY_PREFIX/sensor/$DEVICE_ID/max_db/config" "$(jq -nc \
  --arg name "Noise level (max)" \
  --arg uid "${DEVICE_ID}_max" \
  --arg topic "$MQTT_PREFIX/max_db" \
  --arg dev "$DEVICE_ID" \
  --arg dname "$DEVICE_NAME" \
  '{
    name: $name,
    unique_id: $uid,
    state_topic: $topic,
    unit_of_measurement: "dB",
    device_class: "sound_pressure",
    device: { identifiers: [$dev], name: $dname }
  }'
)"

# presence binary sensor
pub "$DISCOVERY_PREFIX/binary_sensor/$DEVICE_ID/presence/config" "$(jq -nc \
  --arg name "Presence (by noise)" \
  --arg uid "${DEVICE_ID}_presence" \
  --arg topic "$MQTT_PREFIX/presence" \
  --arg dev "$DEVICE_ID" \
  --arg dname "$DEVICE_NAME" \
  '{
    name: $name,
    unique_id: $uid,
    state_topic: $topic,
    payload_on: "1",
    payload_off: "0",
    device_class: "occupancy",
    device: { identifiers: [$dev], name: $dname }
  }'
)"
