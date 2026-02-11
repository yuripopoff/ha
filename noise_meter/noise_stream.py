#!/usr/bin/env python3
# noise_stream.py - reads audio from ALSA device using sox, calculates noise level in dBFS and presence, and publishes to MQTT.

import argparse, math, struct, time, subprocess, collections, select

def log(msg: str):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    log(f"{ts}: {msg}")

def mosquitto_pub(host, port, user, pw, topic, payload):
    cmd = ["mosquitto_pub", "-h", host, "-p", str(port), "-t", topic, "-m", str(payload), "-r"]
    if user:
        cmd += ["-u", user, "-P", pw]

    # timeout чтобы не зависнуть на DNS/сети/брокере
    r = subprocess.run(cmd, check=False, capture_output=True, text=True, timeout=3)

    if r.returncode != 0:
        log(f"mosquitto_pub failed rc={r.returncode} topic={topic} stderr={r.stderr.strip()}")

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

def start_sox(cmd):
    log("PY: starting sox:", cmd)
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0
    )
    log("PY: sox started, pid=", proc.pid)
    return proc

def q01(x: float) -> float:
    # quantize to 0.1 dB
    return round(x, 1)

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

    ap.add_argument("--avg1m-delta", type=float, default=0.5)
    ap.add_argument("--avg1h-delta", type=float, default=1.0)
    ap.add_argument("--avg1m-force-every", type=float, default=60.0)
    ap.add_argument("--avg1h-force-every", type=float, default=300.0)

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

    p = start_sox(cmd)

    hop_samples = int(args.rate * args.hop)
    hop_bytes = hop_samples * 2  # int16

    noise_buf = collections.deque()
    pres_buf = collections.deque()
    noise_keep = max(1, int(args.noise_window / args.hop))
    pres_keep = max(1, int(args.presence_window / args.hop))

    min_keep = max(1, int(60.0 / args.hop))      # 1 minute window
    hour_keep = max(1, int(3600.0 / args.hop))   # 1 hour window
    min_buf = collections.deque()
    hour_buf = collections.deque()

    presence = 0
    buf = bytearray()
    stall_seconds = 0.0
    last_rx = time.time()       # когда пришли последние байты
    last_buf_len = 0            # чтобы видеть, растёт ли буфер
    stall_start = None          # когда реально началась стагнация

    last_pub_avg5 = None
    last_pub_max5 = None
    last_pub_avg1m = None
    last_pub_avg1h = None
    last_pub_presence = None

    i_pub_total=0
    i_pub_avg5 = 0
    i_pub_max5 = 0
    i_pub_avg1m = 0
    i_pub_avg1h = 0
    i_pub_presence = 0

    last_log_ts = 0.0          # когда последний раз печатали таблицу

    while True:
        # ждём данные максимум 2 секунды
        rlist, _, _ = select.select([p.stdout], [], [], 2.0)
        if not rlist:
            # если sox реально умер — рестартим
            rc = p.poll()
            if rc is not None:
                err = (p.stderr.read() or b"").decode("utf-8", "ignore")
                log(f"sox exited rc={rc}. stderr:\n{err}")
                time.sleep(0.2)
                p = start_sox(cmd)
                buf.clear()
                last_rx = time.time()
                last_buf_len = 0
                stall_start = None
                continue

            now = time.time()

            # Если буфер уже почти собрался — не считаем это проблемой, просто ждём.
            # (например, >= 80% окна)
            if len(buf) >= int(hop_bytes * 0.8):
                continue

            # Если давно не было НОВЫХ байтов — считаем стагнацией
            if now - last_rx >= 10.0:  # тут 10s — “подозрительно”, но ещё не рестарт
                if stall_start is None:
                    stall_start = now

                # логируем редко, раз в 10 сек
                # (можно оставить как есть или убрать)
                if int(now) % 10 == 0:
                    log(f"PY: no new audio bytes for {now - last_rx:.0f}s (buf={len(buf)} of {hop_bytes})")

                # рестарт только если реально давно нет байтов
                if now - last_rx >= 30.0:  # 30s — рестарт
                    log("PY: restarting sox due to stalled stream (no new bytes 30s)")
                    try:
                        p.kill()
                    except Exception:
                        pass
                    time.sleep(0.2)
                    p = start_sox(cmd)
                    buf.clear()
                    last_rx = time.time()
                    last_buf_len = 0
                    stall_start = None

            continue

        # читаем сколько есть (не пытаемся сразу hop_bytes)
        chunk = p.stdout.read(4096)
        if not chunk:
            continue

        last_rx = time.time()

        buf.extend(chunk)

        # если буфер растёт — сбрасываем стагнацию
        if len(buf) != last_buf_len:
            last_buf_len = len(buf)
            stall_start = None

        if len(buf) < hop_bytes:
            # ещё не набрали окно
            continue

        raw = bytes(buf[:hop_bytes])
        del buf[:hop_bytes]

        stall_seconds = 0.0

        # unpack int16 little-endian
        samples = struct.unpack("<%dh" % hop_samples, raw)
        db = rms_dbfs(samples)

        noise_buf.append(db)
        pres_buf.append(db)
        while len(noise_buf) > noise_keep:
            noise_buf.popleft()
        while len(pres_buf) > pres_keep:
            pres_buf.popleft()

        min_buf.append(db)
        hour_buf.append(db)

        while len(min_buf) > min_keep:
            min_buf.popleft()
        while len(hour_buf) > hour_keep:
            hour_buf.popleft()

        avg5 = q01(sum(noise_buf) / len(noise_buf))
        max5 = q01(max(noise_buf))
        avg2 = q01(sum(pres_buf) / len(pres_buf))
        avg1m = q01(sum(min_buf) / len(min_buf))
        avg1h = q01(sum(hour_buf) / len(hour_buf))

        if presence == 0 and avg2 > args.p_on:
            presence = 1
        elif presence == 1 and avg2 < args.p_off:
            presence = 0

        i_pub_total += 1

        # avg 5s
        if last_pub_avg5 is None or avg5q != last_pub_avg5:
            mosquitto_pub(args.mqtt_host, args.mqtt_port, args.mqtt_user, args.mqtt_pass,
                          f"{args.mqtt_prefix}/avg_db", f"{avg5q:.1f}")
            last_pub_avg5 = avg5q
            i_pub_avg5+=1

        # max 5s
        if last_pub_max5 is None or max5q != last_pub_max5:
            mosquitto_pub(args.mqtt_host, args.mqtt_port, args.mqtt_user, args.mqtt_pass,
                          f"{args.mqtt_prefix}/max_db", f"{max5q:.1f}")
            last_pub_max5 = max5q
            i_pub_max5+=1

        # avg 1m
        if last_pub_avg1m is None or avg1mq != last_pub_avg1m:
            mosquitto_pub(args.mqtt_host, args.mqtt_port, args.mqtt_user, args.mqtt_pass,
                          f"{args.mqtt_prefix}/avg_1m_db", f"{avg1mq:.1f}")
            last_pub_avg1m = avg1mq
            i_pub_avg1m+=1

        # avg 1h
        if last_pub_avg1h is None or avg1hq != last_pub_avg1h:
            mosquitto_pub(args.mqtt_host, args.mqtt_port, args.mqtt_user, args.mqtt_pass,
                          f"{args.mqtt_prefix}/avg_1h_db", f"{avg1hq:.1f}")
            last_pub_avg1h = avg1hq
            i_pub_avg1h+=1

        # presence (не квантовать)
        if last_pub_presence is None or presence != last_pub_presence:
            mosquitto_pub(args.mqtt_host, args.mqtt_port, args.mqtt_user, args.mqtt_pass,
                          f"{args.mqtt_prefix}/presence", str(presence))
            last_pub_presence = presence
            i_pub_presence+=1

        now = time.time()
        if now - last_log_ts >= 60:
            last_log_ts = now
            presence_str = "true" if presence else "false"

            log(
                "\n"
                "+-------------------------------+------------+\n"
                "| metric            value       | published  |\n"
                "+-------------------------------+------------+\n"
                f"| db (current)   {db:8.2f} dB | {i_pub_total:10d} |\n"
                f"| avg5           {avg5:8.2f} dB | {i_pub_avg5:10d} |\n"
                f"| max5           {max5:8.2f} dB | {i_pub_max5:10d} |\n"
                f"| avg1m          {avg1m:8.2f} dB | {i_pub_avg1m:10d} |\n"
                f"| avg1h          {avg1h:8.2f} dB | {i_pub_avg1h:10d} |\n"
                f"| presence       {presence_str:>8} | {i_pub_presence:10d} |\n"
                "+-------------------------------+------------+"
            )

log("PY module loaded.")

if __name__ == "__main__":
    main()
