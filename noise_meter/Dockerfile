FROM alpine:3.19

RUN apk add --no-cache bash jq sox alsa-utils mosquitto-clients coreutils alsa-lib alsa-plugins alsa-plugins-pulse

COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
