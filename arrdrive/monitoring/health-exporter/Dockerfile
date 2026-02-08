FROM alpine:latest
RUN apk add --no-cache wget netcat-openbsd socat coreutils bash
COPY exporter.sh /usr/local/bin/exporter.sh
RUN chmod +x /usr/local/bin/exporter.sh
EXPOSE 9112
CMD ["/usr/local/bin/exporter.sh"]
