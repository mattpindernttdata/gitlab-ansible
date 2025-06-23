FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 \
        python3-venv \
        python3-pip \
        curl \
        unzip \
        libc6 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o "session-manager-plugin.deb" && \
    dpkg -i session-manager-plugin.deb && \
    rm -f session-manager-plugin.deb

COPY requirements.txt /tmp/
COPY requirements2.txt /tmp/
COPY ansible-galaxy-requirements.yml /tmp/

RUN python3 -m venv /opt/ansible-venv

RUN /opt/ansible-venv/bin/pip install --upgrade pip && \
    /opt/ansible-venv/bin/pip install ansible boto3 botocore awscli

RUN /opt/ansible-venv/bin/pip install -r /tmp/requirements.txt

RUN /opt/ansible-venv/bin/pip install -r /tmp/requirements2.txt

RUN /opt/ansible-venv/bin/ansible-galaxy install -r /tmp/ansible-galaxy-requirements.yml --force

ENV PATH="/opt/ansible-venv/bin:${PATH}"

RUN apt-get purge -y --auto-remove curl unzip && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /ansible

RUN ansible --version && session-manager-plugin --version && aws --version

RUN apt update && apt install openssh-client wget -y

RUN apt install nano vim lynx nmap net-tools unzip -y

ENTRYPOINT ["/bin/bash"]
