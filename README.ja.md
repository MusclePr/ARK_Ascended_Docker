# ARK Survival Ascended Docker Server

このプロジェクトは、Linux 上の Docker コンテナ内で ARK Survival Ascended サーバーを実行するために、GloriousEggroll の Proton-GE に依存しています。これにより、ASA Windows サーバーバイナリを Linux 上で簡単に実行できます。

<!-- TOC start (generated with https://github.com/derlin/bitdowntoc) -->
### 目次
- [フォークについて](#フォークについて)
- [使用方法](#使用方法)
- [設定](#設定)
   * [設定変数](#設定変数)
- [複数インスタンスの実行 (クラスター)](#複数インスタンスの実行-クラスター)
- [マネージャーコマンド](#マネージャーコマンド)
- [ハイパーバイザー](#ハイパーバイザー)

<!-- TOC end -->
### フォークについて
このリポジトリは [Luatan/ARK_Ascended_Docker](https://github.com/Luatan/ARK_Ascended_Docker) のフォークであり、オリジナルである [azixus/ARK_Ascended_Docker](https://github.com/azixus/ARK_Ascended_Docker) に対して以下の機能追加や改善が行われています：

- **Discord 通知機能**: サーバーの状態やイベントを Discord に通知する機能 (`scripts/manager/discord.sh`) が追加されています。
- **Dynamic Config (Web)**: `web/` ディレクトリと `dynamicconfig.ini` が追加され、動的な設定管理がサポートされています。
- **クラスター設定のサポート**: クラスター向けのサンプルが提供されています。
- **スクリプトの改善**: スクリプト構成が整理され (`scripts/manager/` 配下)、バックアップやサーバー管理のロジックが改善されています。
- **ヘルスチェックの強化**: Docker コンテナのヘルスチェック機能が改善されています。
- **設定ファイルのサンプル化**: `.env.sample` が提供され、設定管理が容易になっています。

#### フォークからの改変について

- steamcmd に、cm2network/steamcmd:root イメージを使用。
- init.sh を追加し、steamcmd のウォームアップを追加し、ダウンロードの安定化。
- MULTIHOME 設定の追加
- SERVER_IP 設定の追加
- QUERY_PORT 設定の追加
- CLUSTER_ID 設定の追加
- ダウンロード失敗時のリトライ機能の追加
- SERVERGAMELOG 設定の追加
- TZ 設定の追加。ただし、ログのタイムスタンプは、常に UTC に固定。
- SLAVE_PORTS 設定の追加。プログラムやバックアップを共有する上で、保存や停止を連動させたい他のサーバーを、ポート番号で指定します。
- .env.sample を default.env に変更して常に参照化。
- サーバーメンテナンスによる停止時にカウントダウン機能を追加。
- `.signals/status_${SERVER_PORT}` による詳細なサーバー状態監視機能を追加。

### 使用方法
リポジトリをクローンし、権限を設定してコンテナをダウンロードします:
```bash
$ git clone https://github.com/MusclePr/ARK_Ascended_Docker.git
$ cd ARK_Ascended_Docker
```

コンテナを起動する前に、[default.env](./default.env) を .env にコピーし、編集してサーバーの起動パラメータをカスタマイズしてください。
```bash
$ cp default.env .env
```
追加の設定のために [Game.ini](./ark_server/ShooterGame/Saved/Config/WindowsServer/Game.ini) と [GameUserSettings.ini](./ark_server/ShooterGame/Saved/Config/WindowsServer/GameUserSettings.ini) を編集することもできます。これが完了したら、次のようにコンテナを起動します:
```bash
$ docker compose up -d
```

コンテナの起動中に、ASA サーバーは `steamcmd` で自動的にダウンロードされ、その後起動されます。次のコマンドで進行状況を監視できます:
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


### 設定
主なサーバー設定は [compose.yml](./compose.yml) ファイルで行います。これにより、サーバー名、ポートなどを変更できます。

サーバーファイルは [ark_server](./ark_server/) フォルダ内のマウントされたボリュームに保存されます。追加の設定ファイルはこのフォルダにあります: [Game.ini](./ark_server/ShooterGame/Saved/Config/WindowsServer/Game.ini), [GameUserSettings.ini](./ark_server/ShooterGame/Saved/Config/WindowsServer/GameUserSettings.ini)。

ARK Survival Evolved とは異なり、インターネットに公開する必要があるポートは `SERVER_PORT` の1つだけです。`RCON_PORT` を公開する必要はありません。

#### 設定変数
サーバーのカスタマイズに使用できるいくつかの設定オプションを以下に示します。`.env` ファイル内の引用符は、ほとんどの場合使用してはいけません。`-BanListURL="http://banlist"` のような特定のフラグにのみ使用してください。

| 名前 | 説明 | デフォルト |
| --- | --- | --- |
| SERVER_MAP | サーバーマップ。 | TheIsland_WP |
| SESSION_NAME | サーバーの名前。 | My Awesome ASA Server |
| SERVER_PORT | サーバーのリッスンポート。 | 7790 |
| SLAVE_PORTS | クラスタのマスターとして動作します。スレーブの SERVER_PORT をカンマで連結します。 | 7791,7792 |
| CLUSTER_ID | サーバークラスターを識別するためのユニークな文字列。同じIDを持つインスタンス間でのサーバー移動を有効にします。 | - |
| MAX_PLAYERS | 最大プレイヤー数。 | 10 |
| SERVER_PASSWORD | サーバーへの参加に必要なパスワード。無効にするには変数をコメントアウトしてください。 | MyServerPassword |
| ARK_ADMIN_PASSWORD | チートや RCON に必要なパスワード。 | MyArkAdminPassword |
| RCON_PORT | RCON 経由の接続に使用されるポート。 | 32330 |
| MULTIHOME | サーバーがバインドする IP アドレスを指定します。複数のネットワークインターフェースがある場合に便利です。 | - |
| SERVER_IP | `-ServerIP` フラグを設定します。 | - |
| DISABLE_BATTLEYE | サーバーで BattlEye を有効にするにはコメントアウトしてください。 | BattlEye Disabled |
| MODS | サーバーにインストールする Mod のカンマ区切りリスト。 | Disabled |
| ARK_EXTRA_OPTS | 起動コマンドに追加する追加の ?Argument=Value。 | ?ServerCrosshair=true?OverrideStructurePlatformPrevention=true?OverrideOfficialDifficulty=5.0?ShowFloatingDamageText=true?AllowFlyerCarryPvE=true |
| ARK_EXTRA_DASH_OPTS | 起動コマンドに追加する追加のダッシュ引数。 | -ForceAllowCaveFlyers -ForceRespawnDinos -AllowRaidDinoFeeding=true -ActiveEvent=Summer |

利用可能なサーバーメモリを増やすには、[compose.yml](./compose.yml) で `deploy, resources, limits, memory: 16g` をより高い値に増やしてください。

### 複数インスタンスの実行 (クラスター)
2つ以上のコンテナを同時に実行するクラスターを実行したい場合は、いくつかの変更点に注意する必要があります:
- まず、[使用方法](#使用方法) と [設定](#設定) の手順に従ってすべてのインスタンスをセットアップします。
- プログラムやMODを共有してディスクスペースを節約するクラスター構成については、[compose.yml](./compose.yml) を参照してください。
- クローンディレクトリ内にすべての ark_* フォルダを ``mkdir`` で作成し、権限が正しいことを確認してください。
- [.env](./.env) ファイル内の共有設定を編集します。
- コンテナ固有のすべての設定は、Docker Compose ファイルの environment タグに追加できます。例:
  ```yaml
  environment:
      SERVER_MAP: TheIsland_WP
      SESSION_NAME: My Awesome Server with The Island
  ```
  - まだ正しくない場合は、docker compose ファイルで各インスタンスの **ポート** を異なるもの（例: 7777, 7778, 7779 など）に設定してください。
  - クラスター化したいすべてのインスタンスに対して、`.env` または `compose.yml` で同じ **CLUSTER_ID** を設定してください。`CLUSTER_ID` は文字と数字のランダムな組み合わせである必要があり、特殊文字は使用しないでください。
    ```yaml
    environment:
        CLUSTER_ID: my-shared-cluster-123
    ```
- 特に Mod を使用する場合は、少なくとも約 **28-32GB** のメモリが利用可能であることを確認してください。
- `docker compose up` でクラスターを起動してください。

> **バックアップに関する注意:** `/opt/arkserver` を共有しているクラスター構成では、マネージャーが `.signals/` ディレクトリを用いた高頻度同期メカニズム（5秒間隔）を使用して、バックアップ開始前に**すべてのクラスターノードで `saveworld` が実行されることを保証します。** これにより、ノード間でのデータ不整合を防ぎます。万が一、特定のノードが60秒以内に応答しない場合でも、バックアップ処理は警告を出力した上で続行されます。

#### クラスター更新の master / slave
- 更新（サーバーバイナリ/共有MOD）の実行コンテナは **1つ** に限定します。
- `SLAVE_PORTS` 指定のあるコンテナが **master** です。起動時に `manager update` を実行し、必要ならクラスタメンテナンスに入り更新します。
- `SLAVE_PORTS` 指定のないコンテナは **slave** です。master が更新チェックを完了するまで起動を待機します（SIGINT/SIGTERM で停止）。
- `SLAVE_PORTS` を **master** コンテナに、**slave** が使用するポート番号をカンマで連結して設定してください。
- master が複数起動した場合は、共有ボリューム上のロック（`/opt/arkserver/.signals/master.lock`）で検知し、後発の master は終了します。

#### ロック/フラグファイルの詳細（`.signals/` 内に収容）
共有ボリューム（`/opt/arkserver/.signals/`）内には、クラスターの状態を管理するためのいくつかのファイルが作成されます。

| ファイル名 | 役割 | 詳細 |
| --- | --- | --- |
| `maintenance.lock` | メンテナンスロック | 更新作業などが進行中であることを示します。このファイルが存在する間、スレーブサーバーは停止または待機状態を維持します。 |
| master.lock | マスター宣言ロック | 更新マスター（AUTO_UPDATE_ENABLED=true）として動作しているコンテナを特定するためのディレクトリ形式のロックです。内部の `owner` ファイルに所有者情報が記録されます。 |
| `update.request` | 更新要求フラグ | マネージャーコマンド等から更新が要求されたことを示します。マスターはこのフラグを検知するとメンテナンスを開始します。 |
| `ready.flag` | 起動許可フラグ | マスターが更新チェックを完了し、各サーバーの起動が許可されたことを示します。スレーブはこのファイルを待機します。 |
| `waiting_${PORT}.flag` | 待機状態フラグ | 特定のポートのサーバーがメンテナンス終了を待っていることを示します。ヘルスチェック等で参照されます。 |
| `autoresume_${PORT}.flag` | 自動再起動フラグ | メンテナンス開始時に稼働していたサーバーを記録します。メンテナンス終了後、このファイルがあるサーバーのみが自動的に再起動されます。 |
| `updating.lock` | ダウンロード中ロック | SteamCMD によるファイル更新が進行中であることを示します。不完全な状態での起動を防止するために参照されます。 |

#### ロック/フラグの手動解除（kill -9 等で残った場合）
1) いったん全コンテナを停止します（例: `docker compose down`）
2) 共有ボリューム内の同期シグナルをリセットします。

```bash
docker compose run --rm asa_main bash -lc 'rm -rf /opt/arkserver/.signals && mkdir /opt/arkserver/.signals'
```

その後、`docker compose up -d` で再起動してください。

### マネージャーコマンド
マネージャースクリプトはいくつかのコマンドをサポートしています。以下にその一部を紹介します。

**サーバー起動**
```bash
$ ./manager.sh start
Starting server on port 7790
Server should be up in a few minutes
```

**サーバー停止**
```bash
$ ./manager.sh stop
Stopping server gracefully...
Waiting 30s for the server to stop
Done
```

**サーバー再起動**
```bash
$ ./manager.sh restart
Stopping server gracefully...
Waiting 30s for the server to stop
Done
Starting server on port 7790
Server should be up in a few minutes
```

**サーバー状態**
標準の status コマンドは、サーバーに関する基本的な情報、サーバー PID、リッスンポート、現在接続されているプレイヤー数を表示します。
```bash
$ ./manager.sh status
Server PID:     109
Server Port:    7790
Players:        0 / ?
Server is up
```

**サーバーログ**\
_`./manager.sh logs -f` を使用して、ログが出力されるのを追跡することもできます。_
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

`--full` フラグを使用すると、サーバーバイナリから API 認証情報を抽出して Epic Online Services にクエリを実行し、より詳細な情報を取得できます。
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

**ワールドの保存**
```bash
$ ./manager.sh saveworld
Saving world...
Success!
```

**サーバー更新**
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

**サーバーバックアップ作成**

マネージャーは、セーブデータとすべての設定ファイルのバックアップ作成をサポートしています。バックアップは ./ark_backup ボリュームに保存されます。

_サーバーのシャットダウンは不要です。_
```bash
./manager.sh backup
Creating backup. Backups are saved in your ./ark_backup volume.
Saving world...
Success!
Number of backups in path: 6
Size of Backup folder: 142M     /var/backups/asa-server
```

**サーバーバックアップ復元**

マネージャーは、以前に作成したバックアップの復元をサポートしています。`./manager.sh restore` を使用すると、作成されたすべてのバックアップのリストが表示され、どのバックアップから復元するかを尋ねられます。また、引数としてバックアップファイル名を直接指定することも可能です: `./manager.sh restore [filename]`

_クラスター環境では、リストア実行中にクラスター内の全サーバーが停止します。_
_バックアップへの復元時にサーバーは自動的に再起動されます。_
```bash
./manager.sh restore backup_2023-11-08_19-11-24.tar.gz
```

**猶予を持った停止とカウントダウン**

サーバーを停止する場合（`stop`, `update`, `restore`, `restart` の実行時）、プレイヤーが接続している場合は 60 秒のカウントダウンがサーバー内にブロードキャストされます。カウントダウン中に全プレイヤーがログアウトした場合は、即座に停止処理へと移行します。

以下の環境変数を `.env` ファイルに設定することで、メッセージをカスタマイズできます：
- `MSG_MAINTENANCE_COUNTDOWN`: カウントダウンメッセージ（例：「サーバーメンテナンスのため緊急停止します。安全な場所でログアウトしてください。あと%d秒。」）
- `MSG_MAINTENANCE_COUNTDOWN_SOON`: 直前カウントダウンメッセージ（例：「%d秒」）

**RCON コマンド**
```bash
$ ./manager.sh rcon "Broadcast Hello World"   
Server received, But no response!!
```

**サーバー状態の監視**

各サーバーの詳細な状態は、`.signals/status_${SERVER_PORT}` ファイルを通じて確認できます。これにより、外部ツールからサーバーのライフサイクルを正確に把握することが可能です：
- `WAIT_MASTER`: マスターサーバーのアップデート確認完了を待機中。
- `WAIT_INSTALL`: サーバーバイナリの確認、またはメンテナンス解除を待機中。
- `UPDATING`: `steamcmd` によるサーバー本体のアップデート中。
- `STARTING`: サーバープロセスが起動し、RCONの応答を待機中。
- `RUNNING`: RCONが応答し、正常に稼働中。
- `STOPPING`: 猶予を持った停止処理（警告ブロードキャスト、SaveWorld）を実行中。
- `STOPPED`: サーバープロセスが終了。
- `MAINTENANCE`: クラスターメンテナンスにより停止中。
- `BACKUP_SAVE`: バックアップ作成のための `SaveWorld` を実行中。
- `RESTORING`: バックアップからのリストア作業中。

### ハイパーバイザー

**Proxmox VM**

Proxmox の Linux VM のデフォルト CPU タイプ (kvm64) は、サーバーの実行に必要なすべての機能を実装していないようです。Docker コンテナを実行する際、*./ark_data/ShooterGame/Saved/Logs* 内のログファイルを確認すると、次のような内容の .crashstack ファイルが見つかる場合があります:
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
その場合は、VM のハードウェア設定で CPU タイプを host に変更してください。VM を再起動した後、コンテナは問題なく動作するはずです。
