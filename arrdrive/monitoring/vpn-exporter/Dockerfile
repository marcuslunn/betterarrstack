FROM alpine:latest
RUN apk add --no-cache wget netcat-openbsd coreutils docker-cli
COPY exporter.sh /usr/local/bin/exporter.sh
RUN chmod +x /usr/local/bin/exporter.sh
EXPOSE 9101
CMD ["/usr/local/bin/exporter.sh"]
