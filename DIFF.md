# ARK Survival Ascended Docker Server (MusclePr Fork - Changes)

This document explains the main changes and added features in the MusclePr fork of the original [azixus repository](https://github.com/azixus/ARK_Ascended_Docker) and the intermediate fork by [Luatan](https://github.com/Luatan/ARK_Ascended_Docker).

Refer to [README.md](./README.md) for basic usage.

## Major Improvements and Additions

This MusclePr fork builds on Luatan's work and includes changes to improve operational stability and the user experience in Japanese environments.

### 1. Key improvements from Luatan
- **Basic log support**: added a logging system that considers colors
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
- **Basic Discord notifications**: basic logic to send server events to Discord
    ```ini
    DISCORD_WEBHOOK_URL=
    DISCORD_CONNECT_TIMEOUT=30
    DISCORD_MAX_TIMEOUT=30
    ```
- **Detailed status retrieval**: fetch server name, version, etc. from Epic Online Services (EOS) (`manager status --full`).
- **Scheduled backups and updates**: automation via supercronic
    ```ini
    AUTO_BACKUP_ENABLED=false
    OLD_BACKUP_DAYS=7
    AUTO_BACKUP_CRON_EXPRESSION="0 0 * * *"
    AUTO_UPDATE_ENABLED=false
    AUTO_UPDATE_CRON_EXPRESSION="0 * * * *"
    UPDATE_WARN_MINUTES=30
    ```
- **Health check feature**: synchronizes container state with the actual game process (Wine/Proton), detects anomalies, and attempts auto-restart (self-healing) for stable operation
    ```ini
    SERVER_SHUTDOWN_TIMEOUT=30
    HEALTHCHECK_CRON_EXPRESSION="*/5 * * * *"
    HEALTHCHECK_SELFHEALING_ENABLED=false
    ```
- **Web dynamic config**:
  - Supports loading dynamic settings from external tools via `web/dynamicconfig.ini`.

### 2. MusclePr fork — unique additions and improvements

- Implemented multi-map support with a single program, addressing these issues:

  ❌ Disk bloat of ~11GB per added map.

  ❌ Needing to update the program for all maps every time.

  ❌ Managing MODs and settings per map is cumbersome.

#### Management and Automation Enhancements
- **Cluster synchronization (Master-Slave mode)**:
  - Provides exclusive control for updates and backups across multiple containers to maintain data consistency.
- **Detailed status monitoring system**:
  - External tools can check detailed statuses such as "upgrading" or "backing up" via `.signals/status_${SERVER_PORT}` files.
- **Maintenance countdown**:
  - Sends countdown messages automatically to in-game chat when shutting down or updating.
  - `UPDATE_WARN_MINUTES` has been removed in favor of this mechanism.

#### Stability and Download Improvements
- **SteamCMD stabilization**:
  - Implemented SteamCMD "warm-up" (stabilize first login) in `init.sh` and automatic retry on download failures.
- **Execution permission optimization**:
  - Changed the base image to `cm2network/steamcmd:root` to avoid permission issues with volume mounts.

#### Expanded Discord notifications
- Extended capability to detect login/logout events from `ShooterGame.log` and notify Discord.

#### Configuration flexibility and extensibility
- **Structured environment variables**:
  - Per-map container environment variables are structured in `compose.yml`, making per-container configuration easy by setting variables in `.env`, for example:
    - "SERVER_MAP=${ASA0_SERVER_MAP}"
    - "SESSION_NAME=${ASA_SESSION_PREFIX}${ASA0_SESSION_NAME}"
    - "SERVER_PORT=${ASA0_SERVER_PORT}"
    - "QUERY_PORT=${ASA0_QUERY_PORT}"
    - "DISCORD_WEBHOOK_URL=${ASA0_DISCORD_WEBHOOK_URL:-${ASA_DISCORD_WEBHOOK_URL}}"

    > [!NOTES]
    >
    > `.env` is implicitly read by `docker compose`, but variables from `.env` are not automatically exported as container environment variables unless defined in the compose config.

  - Common environment variables can be defined in `.common.env` for easy configuration, such as:
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
    - `MSG_MAINTENANCE_COUNTDOWN` — e.g. "Server maintenance: shutting down. Please log out in a safe place. %d seconds remaining."
    - `MSG_MAINTENANCE_COUNTDOWN_SOON` — e.g. "%d seconds left"
    - `DISCORD_MSG_JOINED` — e.g. "%s joined."
    - `DISCORD_MSG_LEFT` — e.g. "%s left."

- **Master/Slave support**:
  - The master container is responsible for safely stopping all servers during program updates; slaves synchronize and stop safely upon the master's request.
  - The container named `asa0` acts as master by defining the `SLAVE_PORTS` environment variable, listing slave `SERVER_PORT` values (asa1, etc.) separated by commas.
  - The container that defines `SLAVE_PORTS` becomes the master.
  - To run a single container without slaves, explicitly set `CLUSTER_MASTER=true` to indicate it is the master.

#### Additional environment for verification
- `run.sh`
  ```bash
  Usage: run.sh {up|down|build|push|shellcheck}
  ```
  - up ... docker compose up -d
  - down ... docker compose down
  - build ... docker build
  - push ... docker push
  - shellcheck ... shellcheck

## Backup/Restore changes (cluster-level backups)

This fork supports backups at the cluster level only.

Backups include only the following subpaths under `/opt/arkserver/ShooterGame/Saved`:

1. `Saved/SavedArks` — map/tribe/player saves (excluding `*.profilebak`, `*.tribebak`, and `${SERVER_MAP}_*.ark`)
2. `Saved/SaveGames` — MOD save data
3. `Saved/Config/WindowsServer` — configuration files such as `Game.ini`, `GameUserSettings.ini`, `Engine.ini`
4. `Saved/Cluster/clusters/${CLUSTER_ID}` — cluster metadata

Directories that do not exist are ignored.

## Cluster synchronization (maintenance mode)

The following summarizes operational logic added or improved in this repository to support safe updates, backups, and restores in master/slave environments.

- Added common helpers for maintenance and request operations in `scripts/manager/helper.sh`:
  - Reusable functions like `enter_maintenance`, `exit_maintenance`, and `with_maintenance` for cluster-wide stop/work/resume workflows.
  - Helpers such as `create_request_json`, `mark_request_status`, and `wait_for_response` to assist request processing.
- Slight improvement to `scripts/manager/manager.sh`'s `start()` so that RCON wait logs reach the container's PID 1, allowing `rcon_wait_ready` output to appear in `docker logs`.
- Added `scripts/manager/request_worker.sh` to accept requests to the master:
  - This runs as a child process of PID 1 so the execution result is retained in logs.
- Backup and restore operations are now request-driven:
  - `manager restore --request <archive>` creates `/opt/arkserver/.signals/request.json` (duplicate requests are rejected).
  - A `request_worker.sh` forked from PID 1 renames `request.json` to `request-XXXXX.json` and calls `restore --apply <archive>` to perform the actual restore.
  - Upon completion the worker renames the file to `.done.json` or `.failed.json` to archive the result (protected by traps so files aren't left behind if the process dies).

