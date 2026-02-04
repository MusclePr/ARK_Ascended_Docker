# ARK Survival Ascended Docker Server (MusclePr Fork — Changes)

This document explains the main changes and added features in the MusclePr fork of the ARK Survival Ascended Docker Server, built on top of the original azixus repository (https://github.com/azixus/ARK_Ascended_Docker) and the Luatan fork (https://github.com/Luatan/ARK_Ascended_Docker).

For basic usage and setup, see [README.md](./README.md).

## Major improvements and added features

This MusclePr fork builds on the Luatan base and includes changes aimed at improving operational stability and usability for Japanese environments.

### 1. Key improvements from the Luatan fork
- **Basic log support**: Added a logging system with color-aware helpers
```bash
LogInfo() {
    Log "$1" "$WhiteText"
}
LogWarn() {
    Log "$1" "$YellowBoldText"
}
LogError() {
    Log "$1" "$RedBoldText"
}
LogSuccess() {
    Log "$1" "$GreenBoldText"
}
```
- **Basic Discord notification support**: Basic logic to notify Discord about server events
```ini
DISCORD_WEBHOOK_URL=
DISCORD_CONNECT_TIMEOUT=30
DISCORD_MAX_TIMEOUT=30
```
- **Detailed status retrieval**: Ability to fetch server name, version and other details from Epic Online Services (EOS) using `manager status --full`.
- **Scheduled backups and updates**: Automated tasks with supercronic
```ini
AUTO_BACKUP_ENABLED=false
OLD_BACKUP_DAYS=7
AUTO_BACKUP_CRON_EXPRESSION="0 0 * * *"
AUTO_UPDATE_ENABLED=false
AUTO_UPDATE_CRON_EXPRESSION="0 * * * *"
UPDATE_WARN_MINUTES=30
```
- **Healthcheck system**: Synchronizes container state with the actual game process (Wine/Proton) and supports auto-restart (self-healing) when anomalies are detected.
```ini
SERVER_SHUTDOWN_TIMEOUT=30
HEALTHCHECK_CRON_EXPRESSION="*/5 * * * *"
HEALTHCHECK_SELFHEALING_ENABLED=false
```
- **Dynamic web configuration**:
  - Support for loading settings dynamically from `web/dynamicconfig.ini` so external tools can change configuration at runtime.

### 2. MusclePr fork — unique additions and improvements

This fork addresses running multiple maps with a single program while solving the following problems:

❌ Each additional map consuming ~11GB of disk space per map.

❌ Requirement to update program files for all maps when updating.

❌ Managing mods and settings separately per map was cumbersome.

#### Management and automation improvements
- **Cluster synchronization (Master-Slave mode)**:
  - Using the `SLAVE_PORTS` setting to coordinate updates and backups between containers to ensure data consistency.
- **Detailed status monitoring**:
  - External visibility into states like "upgrading" or "backing up" via `.signals/status_${SERVER_PORT}` files.
- **Maintenance countdown**:
  - Automatically sends countdown messages to in-game chat when stopping/updating servers (currently in Japanese).

#### Stability and download improvements
- **SteamCMD stabilization**:
  - Implemented a SteamCMD warm-up on initial login and automatic retry logic for failed downloads in `init.sh`.
- **Permission optimizations**:
  - Changed the base image to `cm2network/steamcmd:root` to avoid permission issues when mounting volumes.

#### Extended Discord notifications
- Extended detection from `ShooterGame.log` to notify Discord on player login/logout events.

#### Configuration flexibility and extensibility
- **Structured environment variables**:
  - Per-map container variables are structured in `compose.yml` and can be set via `.env`. Examples:
    - "SERVER_MAP=${ASA0_SERVER_MAP}"
    - "SESSION_NAME=${ASA_SESSION_PREFIX}${ASA0_SESSION_NAME}"
    - "SERVER_PORT=${ASA0_SERVER_PORT}"
    - "QUERY_PORT=${ASA0_QUERY_PORT}"
    - "DISCORD_WEBHOOK_URL=${ASA0_DISCORD_WEBHOOK_URL:-${ASA_DISCORD_WEBHOOK_URL}}"

    > [!WARNING]
    >
    > `.env` is read implicitly by `docker compose` but is not automatically exported as container environment variables.

  - Common variables can be defined in `.common.env` for easy reuse. Examples include:
    - `MAX_PLAYERS`
    - `HEALTHCHECK_SELFHEALING_ENABLED`
    - `SERVER_PASSWORD`
    - `ARK_ADMIN_PASSWORD`
    - `RCON_PORT`
    - `MULTIHOME`
    - `SERVER_IP`
    - `DISABLE_BATTLEYE`
    - `MODS`
    - `SERVERGAMELOG`
    - `CLUSTER_ID`
    - `DYNAMIC_CONFIG_URL`
    - `ARK_EXTRA_OPTS`
    - `ARK_EXTRA_DASH_OPTS`
    - `MSG_MAINTENANCE_COUNTDOWN` e.g. "Server will shut down for maintenance. Please log out safely. %d seconds left."
    - `MSG_MAINTENANCE_COUNTDOWN_SOON` e.g. "%d"
    - `DISCORD_MSG_JOINED` e.g. "%s joined"
    - `DISCORD_MSG_LEFT` e.g. "%s left"

- **Master/Slave support**:
  - Master coordinates safe shutdowns and restores and instructs slaves to save world and sync during updates/backups. The `asa0` container acts as master and can be given `SLAVE_PORTS` to list slave `SERVER_PORT` values.

#### Test/run helpers
- `run.sh`
```bash
Usage: run.sh {up|down|build|push}
```
  - `up` ... `docker compose up -d`
  - `down` ... `docker compose down`
  - `build` ... `docker build`
  - `push` ... `docker push`
