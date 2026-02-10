#!/usr/bin/env bash
set -euo pipefail

# ===== Load options =====
MQTT_HOST=$(jq -r '.mqtt_host' /data/options.json)
MQTT_PORT=$(jq -r '.mqtt_port' /data/options.json)
MQTT_PREFIX=$(jq -r '.mqtt_prefix' /data/options.json)
MQTT_USER=$(jq -r '.mqtt_username' /data/options.json)
MQTT_PASS=$(jq -r '.mqtt_password' /data/options.json)

ALSA_DEVICE=$(jq -r '.alsa_device' /data/options.json)

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
  local out
  out=$(timeout 4 sox -t alsa "$ALSA_DEVICE" -n trim 0 1 stat 2>&1) || {
    echo "sox failed (exit=$?): $out" >&2
    return 1
  }
  local db
  db=$(echo "$out" | awk '/RMS lev dB/{print $4}' | tail -n 1)
  [[ -n "${db:-}" ]] || { echo "no RMS line: $out" >&2; return 1; }
  echo "$db"
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


echo "ARECORD -l:" >&2
arecord -l >&2 || true

echo "ARECORD -L (first 120 lines):" >&2
arecord -L 2>&1 | head -n 120 >&2 || true

echo "SOX: help-format alsa:" >&2
sox --help-format alsa 2>&1 | head -n 80 >&2 || true

try_dev() {
  local d="$1"
  local out db

  out=$(timeout 3 sox -t alsa "$d" -n trim 0 0.2 stat 2>&1) || {
    echo "Probe FAILED for [$d]: $out" >&2
    return 1
  }

  db=$(echo "$out" | awk '/RMS lev dB/{print $4}' | tail -n 1)
  if [[ -n "${db:-}" ]]; then
    echo "$db"
    return 0
  fi

  echo "Probe FAILED for [$d]: no RMS line. Output: $out" >&2
  return 1
}

PROBES=(
  "sysdefault:CARD=1"
  "sysdefault:CARD=2"
  "dsnoop:CARD=1,DEV=0"
  "dsnoop:CARD=2,DEV=0"
  "hw:1,0"
  "hw:2,0"
  "plughw:1,0"
  "plughw:2,0"
)

for dev in "${PROBES[@]}"; do
  echo "Probing $dev ..." >&2
  if db=$(try_dev "$dev"); then
    echo "FOUND $dev -> $db dB" >&2
    ALSA_DEV_FOUND="$dev"
    break
  fi
done

if [[ -z "${ALSA_DEV_FOUND:-}" ]]; then
  echo "No ALSA capture device found" >&2
  sleep 3600
fi


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
