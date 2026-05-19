FROM alpine:latest

COPY script.sh /tmp

ENTRYPOINT ["/bin/sh"]
