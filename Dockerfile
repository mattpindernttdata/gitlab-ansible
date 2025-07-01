FROM alpine:latest

COPY python.tar.gz /tmp

ENTRYPOINT ["/bin/sh"]
