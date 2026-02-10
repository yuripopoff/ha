#!/usr/bin/env bash
set -euo pipefail

# Load options
MQTT_HOST=$(jq -r '.mqtt_host' /data/options.json)
MQTT_PORT=$(jq -r '.mqtt_port' /data/options.json)
MQTT_PREFIX=$(jq -r '.mqtt_prefix' /data/options.json)

P_ON=$(jq -r '.presence_on_db' /data/options.json)
P_OFF=$(jq -r '.presence_off_db' /data/options.json)

W_P=$(jq -r '.presence_window_s' /data/options.json)
W_N=$(jq -r '.noise_window_s' /data/options.json)

topic_presence="${MQTT_PREFIX}/presence"
topic_avg="${MQTT_PREFIX}/avg_db"
topic_max="${MQTT_PREFIX}/max_db"

# One measurement = 1 second audio, deterministic
measure_db() {
  # Output example line contains: "RMS lev dB     -32.45"
  sox -d -n trim 0 1 stat 2>&1 | awk '/RMS lev dB/{print $4}'
}

publish() {
  local topic="$1"
  local payload="$2"
  mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -t "$topic" -m "$payload" -r
}

# Ring buffers in plain text files (простая реализация)
tmpdir="/tmp/noise"
mkdir -p "$tmpdir"
pfile="$tmpdir/presence_samples.txt"
nfile="$tmpdir/noise_samples.txt"
: > "$pfile"
: > "$nfile"

presence_state="0"
last_avg=""
last_max=""

echo "Noise Meter started. MQTT ${MQTT_HOST}:${MQTT_PORT}, prefix=${MQTT_PREFIX}"
echo "Presence on>${P_ON} off<${P_OFF}, windows: presence=${W_P}s noise=${W_N}s"

while true; do
  db=$(measure_db || true)

  # Если микрофон не отдал число — пропустим итерацию
  if [[ -z "${db}" ]]; then
    continue
  fi

  # Append samples (1 sample = 1 second)
  echo "$db" >> "$pfile"
  echo "$db" >> "$nfile"

  # Trim to windows (keep last N lines)
  tail -n "$W_P" "$pfile" > "${pfile}.tmp" && mv "${pfile}.tmp" "$pfile"
  tail -n "$W_N" "$nfile" > "${nfile}.tmp" && mv "${nfile}.tmp" "$nfile"

  # Compute avg/max for noise window
  avg=$(awk '{s+=$1} END {if(NR>0) printf("%.2f", s/NR); else print ""}' "$nfile")
  max=$(awk 'NR==1{m=$1} {if($1>m)m=$1} END {if(NR>0) printf("%.2f", m); else print ""}' "$nfile")

  # Presence logic: use avg over presence window + hysteresis
  p_avg=$(awk '{s+=$1} END {if(NR>0) printf("%.2f", s/NR); else print ""}' "$pfile")

  if [[ -n "$p_avg" ]]; then
    if [[ "$presence_state" == "0" ]]; then
      # turn ON if above P_ON
      if awk -v x="$p_avg" -v t="$P_ON" 'BEGIN{exit !(x>t)}'; then
        presence_state="1"
      fi
    else
      # turn OFF if below P_OFF
      if awk -v x="$p_avg" -v t="$P_OFF" 'BEGIN{exit !(x<t)}'; then
        presence_state="0"
      fi
    fi
  fi

  # Publish retained values (простая версия — публикуем всегда)
  publish "$topic_presence" "$presence_state"
  publish "$topic_avg" "$avg"
  publish "$topic_max" "$max"
done
