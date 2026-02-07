FROM alpine:latest
RUN apk add --no-cache wget
COPY exporter.sh /usr/local/bin/exporter.sh
RUN chmod +x /usr/local/bin/exporter.sh
EXPOSE 9101
CMD ["/usr/local/bin/exporter.sh"]
