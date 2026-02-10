#!/usr/bin/env python3
import argparse, math, struct, time, subprocess, collections

def mosquitto_pub(host, port, user, pw, topic, payload):
    cmd = ["mosquitto_pub", "-h", host, "-p", str(port), "-t", topic, "-m", str(payload), "-r"]
    if user:
        cmd += ["-u", user, "-P", pw]
    subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def rms_dbfs(samples):
    # samples: list[int16]
    if not samples:
        return None
    s2 = 0.0
    for x in samples:
        s2 += float(x) * float(x)
    rms = math.sqrt(s2 / len(samples))
    if rms <= 0:
        return -120.0
    # full-scale for int16
    return 20.0 * math.log10(rms / 32768.0)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="default")
    ap.add_argument("--rate", type=int, default=48000)
    ap.add_argument("--hop", type=float, default=0.2)
    ap.add_argument("--noise-window", type=float, default=5.0)
    ap.add_argument("--presence-window", type=float, default=2.0)
    ap.add_argument("--p-on", type=float, default=-35.0)
    ap.add_argument("--p-off", type=float, default=-42.0)

    ap.add_argument("--mqtt-host", required=True)
    ap.add_argument("--mqtt-port", type=int, default=1883)
    ap.add_argument("--mqtt-user", default="")
    ap.add_argument("--mqtt-pass", default="")
    ap.add_argument("--mqtt-prefix", required=True)
    args = ap.parse_args()

    # sox -> raw PCM stream (int16, mono)
    cmd = [
        "sox",
        "-t", "alsa", args.device,
        "-r", str(args.rate),
        "-c", "1",
        "-b", "16",
        "-e", "signed-integer",
        "-t", "raw",
        "-"
    ]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)

    hop_samples = int(args.rate * args.hop)
    hop_bytes = hop_samples * 2  # int16

    noise_buf = collections.deque()
    pres_buf = collections.deque()
    noise_keep = max(1, int(args.noise_window / args.hop))
    pres_keep = max(1, int(args.presence_window / args.hop))

    presence = 0

    while True:
        raw = p.stdout.read(hop_bytes)
        if not raw or len(raw) < hop_bytes:
            time.sleep(0.05)
            continue

        # unpack int16 little-endian
        samples = struct.unpack("<%dh" % hop_samples, raw)
        db = rms_dbfs(samples)

        noise_buf.append(db)
        pres_buf.append(db)
        while len(noise_buf) > noise_keep:
            noise_buf.popleft()
        while len(pres_buf) > pres_keep:
            pres_buf.popleft()

        avg5 = sum(noise_buf) / len(noise_buf)
        max5 = max(noise_buf)
        avg2 = sum(pres_buf) / len(pres_buf)

        if presence == 0 and avg2 > args.p_on:
            presence = 1
        elif presence == 1 and avg2 < args.p_off:
            presence = 0

        mosquitto_pub(args.mqtt_host, args.mqtt_port, args.mqtt_user, args.mqtt_pass,
                      f"{args.mqtt_prefix}/avg_db", f"{avg5:.2f}")
        mosquitto_pub(args.mqtt_host, args.mqtt_port, args.mqtt_user, args.mqtt_pass,
                      f"{args.mqtt_prefix}/max_db", f"{max5:.2f}")
        mosquitto_pub(args.mqtt_host, args.mqtt_port, args.mqtt_user, args.mqtt_pass,
                      f"{args.mqtt_prefix}/presence", str(presence))

if __name__ == "__main__":
    main()
