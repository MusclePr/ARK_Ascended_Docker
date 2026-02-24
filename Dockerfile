# Based on ghcr.io/parkervcp/steamcmd:proton
# MIT License
#
# Copyright (c) 2020 Matthew Penner
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

FROM        cm2network/steamcmd:root

ARG PGID=1000
ARG PUID=1000
ARG ASA_APPID=2430930
ARG TZ=Etc/UTC
# https://github.com/krallin/tini/releases
ARG TINI_VERSION=v0.19.0
# https://github.com/GloriousEggroll/proton-ge-custom/releases
ARG PROTON_VERSION=tags/GE-Proton10-32
# https://github.com/gorcon/rcon-cli/releases
ARG RCON_VERSION=0.10.3
# https://github.com/mitmproxy/mitmproxy/releases
ARG MITMPROXY_VERSION=12.2.1

ENV ASA_APPID=$ASA_APPID \
    TZ=${TZ} \
    HOME=/home/arkuser \
    LOG_DIR=/opt/arkserver/ShooterGame/Saved/Logs \
    LOG_FILE=ShooterGame.log \
    STEAM_COMPAT_CLIENT_INSTALL_PATH=/home/arkuser/.steam/steam \
    STEAM_COMPAT_DATA_PATH=/home/arkuser/.steam/steam/steamapps/compatdata/${ASA_APPID} \
    SERVER_SHUTDOWN_TIMEOUT=30 \
    HEALTHCHECK_CRON_EXPRESSION="*/5 * * * *" \
    HEALTHCHECK_SELFHEALING_ENABLED=false \
    AUTO_BACKUP_ENABLED=false \
    OLD_BACKUP_DAYS=7 \
    AUTO_BACKUP_CRON_EXPRESSION="0 0 * * *" \
    AUTO_UPDATE_ENABLED=false \
    AUTO_UPDATE_CRON_EXPRESSION="0 * * * *" \
    UPDATE_WARN_MINUTES=30 \
    DISCORD_WEBHOOK_URL= \
    DISCORD_CONNECT_TIMEOUT=30 \
    DISCORD_MAX_TIMEOUT=30 

# Rename steam user to arkuser and install dependencies
RUN         set -ex; \
            groupmod -g ${PGID} -n arkuser steam; \
            usermod -u ${PUID} -g ${PGID} -l arkuser -d /home/arkuser -m steam; \
            chown -R arkuser:arkuser /home/arkuser; \
            mkdir -p /opt/arkserver; \
            ln -s /home/arkuser/steamcmd /opt/steamcmd

# Proton requires x86_64/amd64 only.
RUN         set -ex; \
            if [ "$(dpkg --print-architecture)" != "amd64" ]; then \
                echo "ERROR: This image supports amd64 only (required by Proton). Build with: docker build --platform=linux/amd64 ..."; \
                exit 1; \
            fi

# Install required packages
RUN         set -ex; \
            export DEBIAN_FRONTEND=noninteractive; \
            dpkg --add-architecture i386; \
            find /usr/lib/python3* -type f -name '*.pyc' -delete || true; \
            find /usr/lib/python3* -type d -name '__pycache__' -prune -exec rm -rf '{}' + || true; \
            apt-get update; \
            apt-get install -y --no-install-recommends tzdata wget curl jq jo sudo iproute2 procps dbus python3 libfreetype6 libvulkan1 libfontconfig1 inotify-tools netcat-openbsd \
            libcap2-bin libpcap0.8 ca-certificates; \
            dpkg --configure -a; \
            echo "${TZ}" > /etc/timezone; \
            ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime; \
            dpkg-reconfigure -f noninteractive tzdata; \
            apt-get clean; \
            rm -rf /var/lib/apt/lists/*

# Install proton-ge-custom
# https://github.com/GloriousEggroll/proton-ge-custom
RUN         set -ex; \
            cd /tmp/; \
            curl -sLOJ "$(curl -s https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/${PROTON_VERSION} | jq -r '.assets[].browser_download_url' | egrep .tar.gz)"; \
            tar -xzf GE-Proton*.tar.gz -C /usr/local/bin/ --strip-components=1; \
            rm GE-Proton*.*; \
            rm -f /etc/machine-id; \
            dbus-uuidgen --ensure=/etc/machine-id; \
            rm /var/lib/dbus/machine-id; \
            dbus-uuidgen --ensure

# Install rcon-cli
# https://github.com/gorcon/rcon-cli
RUN         set -ex; \
            cd /tmp/; \
            curl -sSL https://github.com/gorcon/rcon-cli/releases/download/v${RCON_VERSION}/rcon-${RCON_VERSION}-amd64_linux.tar.gz > rcon.tar.gz; \
            tar xvf rcon.tar.gz; \
            mv rcon-${RCON_VERSION}-amd64_linux/rcon /usr/local/bin/

# Install tini
# https://github.com/krallin/tini
ADD         https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /tini
RUN         chmod +x /tini

# Latest releases available at https://github.com/aptible/supercronic/releases
ENV SUPERCRONIC_URL=https://github.com/aptible/supercronic/releases/download/v0.2.43/supercronic-linux-amd64 \
    SUPERCRONIC_SHA1SUM=f97b92132b61a8f827c3faf67106dc0e4467ccf2  \
    SUPERCRONIC=supercronic-linux-amd64

RUN curl -fsSLO "$SUPERCRONIC_URL" \
 && echo "${SUPERCRONIC_SHA1SUM}  ${SUPERCRONIC}" | sha1sum -c - \
 && chmod +x "$SUPERCRONIC" \
 && mv "$SUPERCRONIC" "/usr/local/bin/${SUPERCRONIC}" \
 && ln -s "/usr/local/bin/${SUPERCRONIC}" /usr/local/bin/supercronic

# install patched knockd (as same as https://github.com/itzg/docker-minecraft-server/blob/master/build/ubuntu/install-packages.sh)
RUN curl -fsSL -o /tmp/knock.tar.gz https://github.com/Metalcape/knock/releases/download/0.8.1/knock-0.8.1-amd64.tar.gz && \
    tar -xf /tmp/knock.tar.gz -C /usr/local/ && rm /tmp/knock.tar.gz && \
    ln -s /usr/local/sbin/knockd /usr/sbin/knockd && \
    setcap cap_net_raw=ep /usr/local/sbin/knockd && \
    find /usr/lib -name 'libpcap.so.0.8' -execdir cp '{}' libpcap.so.1 \;

# install mitmproxy (amd64 prebuilt binary)
RUN set -ex; \
    cd /tmp/; \
    curl -fsSL -o mitmproxy.tar.gz "https://downloads.mitmproxy.org/${MITMPROXY_VERSION}/mitmproxy-${MITMPROXY_VERSION}-linux-x86_64.tar.gz"; \
    tar -xzf mitmproxy.tar.gz -C /usr/local/bin; \
    rm -f mitmproxy.tar.gz

# Generate mitmproxy CA certificate and add it to trusted certificates
RUN mkdir -p ${HOME}/.mitmproxy && \
    openssl genrsa -out ca.key 2048 && \
    openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt -addext keyUsage=critical,keyCertSign -subj "/CN=rootca" && \
    cat ca.key ca.crt > ${HOME}/.mitmproxy/mitmproxy-ca.pem && \
    chown -R arkuser:arkuser ${HOME}/.mitmproxy && \
    rm ca.key && \
    mv ca.crt /usr/local/share/ca-certificates/mitmproxy.crt && \
    update-ca-certificates

# Set permissions
RUN         set -ex; \
            mkdir -p /var/backups;\
            chown -R arkuser:arkuser /var/backups;

COPY --chown=arkuser --chmod=755 ./scripts/ /opt/

RUN         ln -s /opt/manager/manager.sh /usr/local/bin/manager; \
            rm -rf /tmp/*;

WORKDIR     /opt/arkserver/

HEALTHCHECK CMD /opt/healthcheck.sh
ENTRYPOINT ["/tini", "--", "/opt/init.sh"]
