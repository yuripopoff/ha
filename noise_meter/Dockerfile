FROM alpine:3.19

RUN apk add --no-cache bash jq sox alsa-utils mosquitto-clients coreutils alsa-lib alsa-plugins alsa-plugins-pulse python3

COPY run.sh /run.sh
COPY run-py.sh /run-py.sh
COPY noise_stream.py /noise_stream.py
RUN chmod +x /run.sh
RUN chmod +x /run-py.sh

CMD ["/run-py.sh"]
