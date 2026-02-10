#!/usr/bin/env bash
set -euo pipefail

# ===== Load options =====
MQTT_HOST=$(jq -r '.mqtt_host' /data/options.json)
MQTT_PORT=$(jq -r '.mqtt_port' /data/options.json)
MQTT_PREFIX=$(jq -r '.mqtt_prefix' /data/options.json)
MQTT_USER=$(jq -r '.mqtt_username' /data/options.json)
MQTT_PASS=$(jq -r '.mqtt_password' /data/options.json)

P_ON=$(jq -r '.presence_on_db' /data/options.json)
P_OFF=$(jq -r '.presence_off_db' /data/options.json)

W_P=$(jq -r '.presence_window_s' /data/options.json)
W_N=$(jq -r '.noise_window_s' /data/options.json)

SAMPLE_PERIOD=5   # seconds between measurements
DEVICE_ID="noise_meter_usb"
DEVICE_NAME="Noise Meter (USB mic)"

# ===== MQTT helpers =====
pub() {
  mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$1" -m "$2" -r
}

# ===== MQTT Discovery =====
DISCOVERY_PREFIX="homeassistant"

publish_discovery() {
  # avg noise sensor
  pub "$DISCOVERY_PREFIX/sensor/$DEVICE_ID/avg_db/config" "$(jq -nc \
    --arg name "Noise level (avg)" \
    --arg uid "${DEVICE_ID}_avg" \
    --arg topic "$MQTT_PREFIX/avg_db" \
    --arg dev "$DEVICE_ID" \
    '{
      name: $name,
      unique_id: $uid,
      state_topic: $topic,
      unit_of_measurement: "dB",
      device_class: "sound_pressure",
      device: { identifiers: [$dev], name: "Noise Meter (USB mic)" }
    }'
  )"

  # max noise sensor
  pub "$DISCOVERY_PREFIX/sensor/$DEVICE_ID/max_db/config" "$(jq -nc \
    --arg name "Noise level (max)" \
    --arg uid "${DEVICE_ID}_max" \
    --arg topic "$MQTT_PREFIX/max_db" \
    --arg dev "$DEVICE_ID" \
    '{
      name: $name,
      unique_id: $uid,
      state_topic: $topic,
      unit_of_measurement: "dB",
      device_class: "sound_pressure",
      device: { identifiers: [$dev], name: "Noise Meter (USB mic)" }
    }'
  )"

  # presence binary sensor
  pub "$DISCOVERY_PREFIX/binary_sensor/$DEVICE_ID/presence/config" "$(jq -nc \
    --arg name "Presence (by noise)" \
    --arg uid "${DEVICE_ID}_presence" \
    --arg topic "$MQTT_PREFIX/presence" \
    --arg dev "$DEVICE_ID" \
    '{
      name: $name,
      unique_id: $uid,
      state_topic: $topic,
      payload_on: "1",
      payload_off: "0",
      device_class: "occupancy",
      device: { identifiers: [$dev], name: "Noise Meter (USB mic)" }
    }'
  )"
}

# ===== Audio measurement =====
measure_db() {
  timeout 3 sox -d -n trim 0 1 stat 2>&1 | awk '/RMS lev dB/{print $4}'
}

ceil_div() {
  awk -v a="$1" -v b="$2" 'BEGIN{print int((a + b - 1)/b)}'
}

P_SAMPLES=$(ceil_div "$W_P" "$SAMPLE_PERIOD")
N_SAMPLES=$(ceil_div "$W_N" "$SAMPLE_PERIOD")

tmpdir="/tmp/noise"
mkdir -p "$tmpdir"
pfile="$tmpdir/p.txt"
nfile="$tmpdir/n.txt"
: > "$pfile"
: > "$nfile"

presence="0"

echo "Noise Meter started. MQTT ${MQTT_HOST}:${MQTT_PORT}, prefix=${MQTT_PREFIX}"
publish_discovery

# ===== Main loop =====
while true; do
  db=$(measure_db || true)
  db="${db//$'\n'/}"

  if ! awk -v x="$db" 'BEGIN{exit !(x ~ /^-?[0-9]+(\.[0-9]+)?$/)}'; then
    sleep "$SAMPLE_PERIOD"
    continue
  fi

  echo "$db" >> "$pfile"
  echo "$db" >> "$nfile"

  tail -n "$P_SAMPLES" "$pfile" > "$pfile.tmp" && mv "$pfile.tmp" "$pfile"
  tail -n "$N_SAMPLES" "$nfile" > "$nfile.tmp" && mv "$nfile.tmp" "$nfile"

  avg=$(awk '{s+=$1} END{printf "%.2f", s/NR}' "$nfile")
  max=$(awk 'NR==1{m=$1}{if($1>m)m=$1} END{printf "%.2f", m}' "$nfile")
  pavg=$(awk '{s+=$1} END{printf "%.2f", s/NR}' "$pfile")

  if [[ "$presence" == "0" ]]; then
    awk -v x="$pavg" -v t="$P_ON" 'BEGIN{exit !(x>t)}' && presence="1"
  else
    awk -v x="$pavg" -v t="$P_OFF" 'BEGIN{exit !(x<t)}' && presence="0"
  fi

  pub "$MQTT_PREFIX/avg_db" "$avg"
  pub "$MQTT_PREFIX/max_db" "$max"
  pub "$MQTT_PREFIX/presence" "$presence"

  sleep "$SAMPLE_PERIOD"
done
