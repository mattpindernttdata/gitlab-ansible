FROM alpine:latest

COPY final.tar.gz /tmp

ENTRYPOINT ["/bin/sh"]
