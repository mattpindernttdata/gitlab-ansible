FROM alpine:latest

WORKDIR /tmp

RUN wget -O /tmp/gitlab-ee_17.5.3-ee.0_amd64.deb https://packages.gitlab.com/gitlab/gitlab-ee/packages/ubuntu/jammy/gitlab-ee_17.5.3-ee.0_amd64.deb/download.deb

RUN tar czf /tmp/gitlab-ee_17.5.3-ee.0_amd64.deb.tar /tmp/gitlab-ee_17.5.3-ee.0_amd64.deb
RUN split -b 100M /tmp/gitlab-ee_17.5.3-ee.0_amd64.deb.tar.gz

ENTRYPOINT ["/bin/sh"]
