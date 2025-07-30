FROM alpine:latest

COPY trivy_0.41.0_Linux-64bit.deb /tmp

ENTRYPOINT ["/bin/sh"]
