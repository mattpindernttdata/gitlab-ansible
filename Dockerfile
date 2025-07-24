FROM alpine:latest

COPY postgresql-client-16.deb /tmp

ENTRYPOINT ["/bin/sh"]
