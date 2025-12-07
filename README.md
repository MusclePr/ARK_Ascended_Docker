# ARK Survival Ascended Docker Server

This project relies on GloriousEggroll's Proton-GE in order to run the ARK Survival Ascended Server inside a docker container under Linux. This allows to run the ASA Windows server binaries on Linux easily.

<!-- TOC start (generated with https://github.com/derlin/bitdowntoc) -->
### Table of Contents
- [About the fork](#about-the-fork)
- [Usage](#usage)
- [Configuration](#configuration)
   * [Configuration variables](#configuration-variables)
- [Running multiple instances (cluster)](#running-multiple-instances-cluster)
- [Manager commands](#manager-commands)
- [Hypervisors](#hypervisors)

<!-- TOC end -->
### About the fork
This repository is a fork of [Luatan/ARK_Ascended_Docker](https://github.com/Luatan/ARK_Ascended_Docker), which provides the following features and improvements over the original [azixus/ARK_Ascended_Docker](https://github.com/azixus/ARK_Ascended_Docker):

- **Discord Notification Support**: Added support for notifying server status and events to Discord (`scripts/manager/discord.sh`).
- **Dynamic Config (Web)**: Added `web/` directory and `dynamicconfig.ini` to support dynamic configuration management.
- **Cluster Configuration Support**: Examples for cluster setups are provided.
- **Script Improvements**: Reorganized script structure (under `scripts/manager/`) and improved logic for backups and server management.
- **Enhanced Healthchecks**: Improved healthcheck functionality for Docker containers.
- **Configuration Samples**: `.env.sample` is provided to make configuration management easier.

#### Changes from the fork

- Use `cm2network/steamcmd:root` image for steamcmd.
- Added `init.sh` to include steamcmd warmup for stable downloads.
- Added `MULTIHOME` setting.
- Added `SERVER_IP` setting.
- Added `QUERY_PORT` setting.
- Added `CLUSTER_ID` setting.
- Added retry functionality for download failures.
- Added `SERVERGAMELOG` setting.
- Added `TZ` setting. (Note: log timestamps are always fixed to UTC).
- Added `SLAVE_PORTS` setting. Specify the port numbers of other servers whose saving and stopping you want to synchronize when sharing programs or backups.
- Added .env.sample with default.env for consistent referencing.
- Added a countdown function when the server is down due to maintenance.
- Added granular server status tracking via `.signals/status_${SERVER_PORT}`.

### Usage
Download the container by cloning the repo and setting permissions:
```bash
$ git clone https://github.com/Luatan/ARK_Ascended_Docker.git
$ cd ARK_Ascended_Docker
```

Before starting the container, copy or rename the [default.env](./default.env) to .env and edit it to customize the starting parameters of the server. 
```bash
$ cp default.env .env
```
You may also edit [Game.ini](./ark_data/ShooterGame/Saved/Config/WindowsServer/Game.ini) and [GameUserSettings.ini](./ark_data/ShooterGame/Saved/Config/WindowsServer/GameUserSettings.ini) for additional settings. Once this is done, start the container as follow:
```bash
$ docker compose up -d
```

During the startup of the container, the ASA server is automatically downloaded with `steamcmd` and subsequently started. You can monitor the progress with the following command:
```bash
$ ./manager.sh logs -f
asa_server  |[2023.10.31-17.06.19:714][  0]Log file open, 10/31/23 17:06:19
asa_server  |[2023.10.31-17.06.19:715][  0]LogMemory: Platform Memory Stats for WindowsServer
asa_server  |[2023.10.31-17.06.19:715][  0]LogMemory: Process Physical Memory: 319.32 MB used, 323.19 MB peak
asa_server  |[2023.10.31-17.06.19:715][  0]LogMemory: Process Virtual Memory: 269.09 MB used, 269.09 MB peak
asa_server  |[2023.10.31-17.06.19:715][  0]LogMemory: Physical Memory: 20649.80 MB used,  43520.50 MB free, 64170.30 MB total
asa_server  |[2023.10.31-17.06.19:715][  0]LogMemory: Virtual Memory: 33667.16 MB used,  63238.14 MB free, 96905.30 MB total
asa_server  |[2023.10.31-17.06.20:506][  0]ARK Version: 25.49
asa_server  |[2023.10.31-17.06.21:004][  0]Primal Game Data Took 0.35 seconds
asa_server  |[2023.10.31-17.06.58:846][  0]Server: "My Awesome ASA Server" has successfully started!
asa_server  |[2023.10.31-17.06.59:188][  0]Commandline:  TheIsland_WP?listen?SessionName="My Awesome ASA Server"?Port=7790?MaxPlayers=10?ServerPassword=MyServerPassword?ServerAdminPassword="MyArkAdminPassword"?RCONEnabled=True?RCONPort=32330?ServerCrosshair=true?OverrideStructurePlatformPrevention=true?OverrideOfficialDifficulty=5.0?ShowFloatingDamageText=true?AllowFlyerCarryPvE=true -log -NoBattlEye -WinLiveMaxPlayers=10 -ForceAllowCaveFlyers -ForceRespawnDinos -AllowRaidDinoFeeding=true -ActiveEvent=Summer
asa_server  |[2023.10.31-17.06.59:188][  0]Full Startup: 40.73 seconds
asa_server  |[2023.10.31-17.06.59:188][  0]Number of cores 6
asa_server  |[2023.10.31-17.07.03:329][  2]wp.Runtime.HLOD = "1"
```


### Configuration
The main server configuration is done through the [compose.yml](./compose.yml) file. This allows you to change the server name, port, etc.

The server files are stored in a mounted volume in the [ark_server](./ark_server/) folder. The additional configuration files are found in this folder: [Game.ini](./ark_server/ShooterGame/Saved/Config/WindowsServer/Game.ini), [GameUserSettings.ini](./ark_server/ShooterGame/Saved/Config/WindowsServer/GameUserSettings.ini).

Unlike ARK Survival Evolved, only one port must be exposed to the internet, namely the `SERVER_PORT`. It is not necessary to expose the `RCON_PORT`.

#### Configuration variables
We list some configuration options that may be used to customize the server below. Quotes in the `.env` file must not be used in most circumstances, you should only use them for certain flags such as `-BanListURL="http://banlist"`.

| Name | Description | Default |
| --- | --- | --- |
| SERVER_MAP | Server map. | TheIsland_WP |
| SESSION_NAME | Name of the server. | My Awesome ASA Server |
| SERVER_PORT | Server listening port. | 7790 |
| SLAVE_PORTS | Acts as the cluster master. Concatenate the SERVER_PORT of the slaves with a comma. | 7791,7792 |
| CLUSTER_ID | Unique string to identify the server cluster. Enables server transfers between instances with the same ID. | - |
| MAX_PLAYERS | Maximum number of players. | 10 |
| SERVER_PASSWORD | Password required to join the server. Comment the variable to disable it. | MyServerPassword |
| ARK_ADMIN_PASSWORD | Password required for cheats and RCON. | MyArkAdminPassword |
| RCON_PORT | Port used to connect through RCON. | 32330 |
| MULTIHOME | Specifies the IP address the server binds to. Useful when multiple network interfaces are available. | - |
| SERVER_IP | Sets the `-ServerIP` flag. | - |
| DISABLE_BATTLEYE | Comment to enable BattlEye on the server. | BattlEye Disabled |
| MODS | Comma-separated list of mods to install on the server. | Disabled |
| ARK_EXTRA_OPTS | Extra ?Argument=Value to add to the startup command. | ?ServerCrosshair=true?OverrideStructurePlatformPrevention=true?OverrideOfficialDifficulty=5.0?ShowFloatingDamageText=true?AllowFlyerCarryPvE=true |
| ARK_EXTRA_DASH_OPTS | Extra dash arguments to add to the startup command. | -ForceAllowCaveFlyers -ForceRespawnDinos -AllowRaidDinoFeeding=true -ActiveEvent=Summer |

To increase the available server memory, in [compose.yml](./compose.yml), increase the `deploy, resources, limits, memory: 16g` to a higher value.

### Running multiple instances (cluster)
If you want to run a cluster with two or more containers running at the same time, you will have to be aware of some things you have to change: 
- First setup all instances according to the [usage](https://github.com/azixus/ARK_Ascended_Docker/edit/cluster/README.md#usage) and [configuration](https://github.com/azixus/ARK_Ascended_Docker/edit/cluster/README.md#configuration) steps.
- For cluster configuration with shared program/mod files, see [compose.yml](./compose.yml). 
- Create all ark_* folders in your clone directory with ``mkdir`` and make sure the permissions are correct.
- Edit the shared Configuration in the [.env](./.env) file
- Every setting which is Container specific can be added to the Docker Compose file int the environement tag for example:
  ```yaml
  environment:
      SERVER_MAP: TheIsland_WP
      SESSION_NAME: My Awesome Server with The Island
  ```
  - Set the **port** to a different one for each instance, eg 7777, 7778, 7779 etc. in the docker compose file if not already correct.
  - Set the same **CLUSTER_ID** for every instance you want to cluster in the `.env` or `compose.yml`. The `CLUSTER_ID` should be a random combination of letters and numbers, don't use special characters.
    ```yaml
    environment:
        CLUSTER_ID: my-shared-cluster-123
    ```
- Be sure that you have at least about **28-32GB** of memory available, especially if you use any mods
- Start the cluster with ```docker compose up```

> **Note on Backups:** In cluster configurations where `/opt/arkserver` is shared across containers, the manager uses a high-frequency synchronization mechanism (5s interval) via the `.signals/` directory to ensure all cluster nodes execute `saveworld` before a backup is taken. This ensures data consistency across all instances. If a node fails to respond within 60 seconds, the backup will proceed with a warning to ensure the backup schedule is maintained.

#### Cluster update master / slave
- Only **one** container must be allowed to update the shared server/mod volume.
- Containers with `SLAVE_PORTS` specified are **master** nodes. They execute `manager update` at startup and enter cluster maintenance to update if necessary.
- Containers without `SLAVE_PORTS` specified are **slave** nodes. They wait for the master to complete the update check before starting (stops on SIGINT/SIGTERM).
- Set `SLAVE_PORTS` on the **master** container by concatenating the port numbers used by **slaves** with commas.
- If multiple masters are started, the later one exits after detecting the shared lock at `/opt/arkserver/.signals/master.lock`.

#### Lock and Flag Files Details (Stored in `.signals/`)
The following files are created in the shared volume (`/opt/arkserver/.signals/`) to manage the cluster state.

| Filename | Role | Description |
| --- | --- | --- |
| `maintenance.lock` | Maintenance Lock | Indicates that maintenance (like an update) is in progress. Slaves will stop or stay in a waiting state while this file exists. |
| `master.lock` | Master Declaration Lock | A directory-based lock to identify the container acting as the update master (`AUTO_UPDATE_ENABLED=true`). Contains an `owner` file with host info. |
| `update.request` | Update Request Flag | Indicates that an update has been requested via manager commands. The master will trigger maintenance upon detecting this flag. |
| `ready.flag` | Startup Permission Flag | Signal from the master that the update-check is complete and servers are allowed to start. Slaves wait for this file. |
| `waiting_${PORT}.flag` | Waiting Status Flag | Indicates that a specific server instance is waiting for maintenance to finish. Used for health checks. |
| `autoresume_${PORT}.flag` | Auto-Resume Flag | Records servers that were running when maintenance started. Only servers with this flag will be auto-started after maintenance. |
| `updating.lock` | Update in Progress Lock | Indicates that SteamCMD is currently downloading/updating files. Prevents starting the server with an incomplete installation. |

#### Manual unlock (if the lock/flags remain after kill -9)
1) Stop all containers (e.g. `docker compose down`)
2) Remove the coordination signals in the shared volume:

```bash
docker compose run --rm asa_main bash -lc 'rm -rf /opt/arkserver/.signals && mkdir /opt/arkserver/.signals'
```

### Manager commands
The manager script supports several commands that we highlight below. 

**Server start**
```bash
$ ./manager.sh start
Starting server on port 7790
Server should be up in a few minutes
```

**Server stop**
```bash
$ ./manager.sh stop
Stopping server gracefully...
Waiting 30s for the server to stop
Done
```

**Server restart**
```bash
$ ./manager.sh restart
Stopping server gracefully...
Waiting 30s for the server to stop
Done
Starting server on port 7790
Server should be up in a few minutes
```

**Server status**  
The standard status command displays some basic information about the server, the server PID, the listening port and the number of players currently connected.
```bash
$ ./manager.sh status
Server PID:     109
Server Port:    7790
Players:        0 / ?
Server is up
```

**Server logs**\
_You can optionally use `./manager.sh logs -f` to follow the logs as they are printed._
```bash
$ ./manager.sh logs
ark_ascended_docker-asa_server-1  | Connecting anonymously to Steam Public...OK
ark_ascended_docker-asa_server-1  | Waiting for client config...OK
ark_ascended_docker-asa_server-1  | Waiting for user info...OK
ark_ascended_docker-asa_server-1  |  Update state (0x3) reconfiguring, progress: 0.00 (0 / 0)
ark_ascended_docker-asa_server-1  |  Update state (0x61) downloading, progress: 0.00 (0 / 9371487164)
ark_ascended_docker-asa_server-1  |  Update state (0x61) downloading, progress: 0.60 (56039216 / 9371487164)
ark_ascended_docker-asa_server-1  |  Update state (0x61) downloading, progress: 0.93 (86770591 / 9371487164)
ark_ascended_docker-asa_server-1  |  Update state (0x61) downloading, progress: 1.76 (164837035 / 9371487164)
# ... full logs will show
```

You can obtain more information with the `--full` flag which queries the Epic Online Services by extracting the API credentials from the server binaries.
```bash
./manager.sh status --full                                             
To display the full status, the EOS API credentials will have to be extracted from the server binary files and pdb-sym2addr-rs (azixus/pdb-sym2addr-rs) will be downloaded. Do you want to proceed [y/n]?: y
Server PID:     109
Server Port:    7790
Server Name:    My Awesome ASA Server
Map:            TheIsland_WP
Day:            1
Players:        0 / 10
Mods:           -
Server Version: 26.11
Server Address: 1.2.3.4:7790
Server is up
```

**Saving the world**
```bash
$ ./manager.sh saveworld
Saving world...
Success!
```

**Server update**
```bash
$ ./manager.sh update
Updating ARK Ascended Server
Saving world...
Success!
Stopping server gracefully...
Waiting 30s for the server to stop
Done
[  0%] Checking for available updates...
[----] Verifying installation...
Steam Console Client (c) Valve Corporation - version 1698262904
 Update state (0x5) verifying install, progress: 94.34 (8987745741 / 9527248082)
Success! App '2430930' fully installed.
Update completed
Starting server on port 7790
Server should be up in a few minutes
```

**Server create Backup**

The manager supports creating backups of your savegame and all config files. Backups are stores in the ./ark_backup volume. 

_No Server shutdown needed._
```bash
./manager.sh backup
Creating backup. Backups are saved in your ./ark_backup volume.
Saving world...
Success!
Number of backups in path: 6
Size of Backup folder: 142M     /var/backups/asa-server
```

**Server restore Backup**

The manager supports restoring a previously created backup. After using `./manager.sh restore` the manager will print out a list of all created backups and simply ask you which one you want to recover from. Alternatively, you can specify the backup filename as an argument: `./manager.sh restore [filename]`.

_In a cluster environment, all servers in the cluster will be stopped during restoration._
_The server automatically gets restarted when restoring to a backup._
```bash
./manager.sh restore backup_2023-11-08_19-11-24.tar.gz
```

**Graceful Shutdown and Countdown**

When stopping the server (via `stop`, `update`, `restore`, or `restart`), if there are players connected, a 60-second countdown will be broadcasted to the server. If all players log out during the countdown, the server will stop immediately.

You can customize the messages using the following environment variables in your `.env` file:
- `MSG_MAINTENANCE_COUNTDOWN`: Message for countdown (e.g., "Server will stop for maintenance in %d seconds. Please log out in a safe place.")
- `MSG_MAINTENANCE_COUNTDOWN_SOON`: Message for short countdown (e.g., "%d seconds")

**RCON commands**
```bash
$ ./manager.sh rcon "Broadcast Hello World"   
Server received, But no response!!
```

**Server Status Monitoring**

The detailed status of each server can be checked via the file `.signals/status_${SERVER_PORT}`. This allows external tools to track the server's lifecycle more accurately:
- `WAIT_MASTER`: Waiting for the update master to complete its check.
- `WAIT_INSTALL`: Waiting for server binary verification or maintenance release.
- `UPDATING`: Updating the server via `steamcmd`.
- `STARTING`: Server process has started; waiting for RCON to become responsive.
- `RUNNING`: RCON is responsive; server is fully operational.
- `STOPPING`: Shutting down gracefully (broadcasting warnings, saving world).
- `STOPPED`: Server process has exited.
- `MAINTENANCE`: Stopped due to cluster maintenance.
- `BACKUP_SAVE`: Saving world synchronously for backup.
- `RESTORING`: Restoring from a backup.

### Hypervisors

**Proxmox VM**

The default CPU type (kvm64) in proxmox for linux VMs does not seem to implement all features needed to run the server. When running the docker container check your log files in *./ark_data/ShooterGame/Saved/Logs* you might see a .crashstack file with contents similiar to:
```
Fatal error!

CL: 450696 
0x000000007b00cdb7 kernelbase.dll!UnknownFunction []
0x0000000143c738ca ArkAscendedServer.exe!UnknownFunction []
0x00000002c74d5ef7 ucrtbase.dll!UnknownFunction []
0x00000002c74b030b ucrtbase.dll!UnknownFunction []
0x00000001400243c2 ArkAscendedServer.exe!UnknownFunction []
0x0000000144319ec7 ArkAscendedServer.exe!UnknownFunction []
0x0000000141fa99ad ArkAscendedServer.exe!UnknownFunction []
0x000000014447c9b8 ArkAscendedServer.exe!UnknownFunction []
0x0000000145d2b64d ArkAscendedServer.exe!UnknownFunction []
0x0000000145d2b051 ArkAscendedServer.exe!UnknownFunction []
0x0000000145d2d732 ArkAscendedServer.exe!UnknownFunction []
0x0000000145d10425 ArkAscendedServer.exe!UnknownFunction []
0x0000000145d01628 ArkAscendedServer.exe!UnknownFunction []
```
In that case just change your CPU type to host in the hardware settings of your VM. After a restart of the VM the container should work without any issues.
