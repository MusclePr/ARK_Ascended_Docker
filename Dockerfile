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

FROM        debian:bullseye-slim

ARG PGID=1000
ARG PUID=1000
ARG TINI_VERSION=v0.19.0
ARG ASA_APPID=2430930

ENV ASA_APPID=$ASA_APPID \
    LOG_FILE=/opt/arkserver/ShooterGame/Saved/Logs/ShooterGame.log \
    PID_FILE=/opt/arkserver/.server.pid \
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

# Use users group for unraid
RUN         groupadd -g $PGID arkuser && useradd -d /home/arkuser -u $PUID -g $PGID -G users -m arkuser; \
            mkdir /opt/arkserver;

RUN         set -ex; \
            dpkg --add-architecture i386; \
            apt update; \
            apt install -y --no-install-recommends wget curl jq jo sudo iproute2 procps software-properties-common dbus lib32gcc-s1;

# Download steamcmd
RUN         set -ex; \
            mkdir -p /opt/steamcmd; \
            cd /opt/steamcmd; \
            curl "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" | tar zxvf - ;\
            curl -sLOJ "$(curl -s https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest | grep browser_download_url | cut -d\" -f4 | egrep .tar.gz)"; \
            tar -xzf GE-Proton*.tar.gz -C /usr/local/bin/ --strip-components=1; \
            rm GE-Proton*.* \
            rm -f /etc/machine-id; \
            dbus-uuidgen --ensure=/etc/machine-id; \
            rm /var/lib/dbus/machine-id; \
            dbus-uuidgen --ensure; \
            cd /tmp/; \
            curl -sSL https://github.com/gorcon/rcon-cli/releases/download/v0.10.3/rcon-0.10.3-amd64_linux.tar.gz > rcon.tar.gz; \
            tar xvf rcon.tar.gz; \
            mv rcon-0.10.3-amd64_linux/rcon /usr/local/bin/;

# Install tini
ADD         https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /tini
RUN         chmod +x /tini;

# Latest releases available at https://github.com/aptible/supercronic/releases
ENV SUPERCRONIC_URL=https://github.com/aptible/supercronic/releases/download/v0.2.33/supercronic-linux-amd64 \
    SUPERCRONIC_SHA1SUM=71b0d58cc53f6bd72cf2f293e09e294b79c666d8 \
    SUPERCRONIC=supercronic-linux-amd64

RUN curl -fsSLO "$SUPERCRONIC_URL" \
 && echo "${SUPERCRONIC_SHA1SUM}  ${SUPERCRONIC}" | sha1sum -c - \
 && chmod +x "$SUPERCRONIC" \
 && mv "$SUPERCRONIC" "/usr/local/bin/${SUPERCRONIC}" \
 && ln -s "/usr/local/bin/${SUPERCRONIC}" /usr/local/bin/supercronic;

# Set permissions
RUN         set -ex; \
            chown -R arkuser:arkuser /opt/arkserver; \
            chown -R arkuser:arkuser /opt/steamcmd; \
            mkdir -p /var/backups;\
            chown -R arkuser:arkuser /var/backups;

COPY --chown=arkuser --chmod=755 ./scripts/start.sh /opt/start.sh
COPY --chown=arkuser --chmod=755 ./scripts/healthcheck.sh /opt/healthcheck.sh
COPY --chown=arkuser --chmod=755 ./scripts/manager /opt/manager

RUN         ln -s /opt/manager/manager.sh /usr/local/bin/manager; \
            rm -rf /tmp/*;

USER        arkuser
WORKDIR     /opt/arkserver/

HEALTHCHECK CMD /opt/healthcheck.sh
#HEALTHCHECK CMD manager health || exit 1
#on startup enter start.sh script
ENTRYPOINT ["/tini", "--", "/opt/start.sh"]
