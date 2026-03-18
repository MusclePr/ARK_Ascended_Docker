# ARK Survival Ascended Docker Server (MusclePr Fork 改変点)

このドキュメントは、オリジナルの [azixus 版](https://github.com/azixus/ARK_Ascended_Docker) と、そのフォークの [Luatan 版](https://github.com/Luatan/ARK_Ascended_Docker) に対する、さらなるフォーク（MusclePr 版）の主な変更点と追加機能について解説します。

基本的な使用方法については、[README.md](./README.md) を参照してください。

## 主な改善点と追加機能

このフォーク版（MusclePr 版）では、ベースとなった Luatan 版の機能に加え、運用の安定性と日本語環境での使い勝手を向上させるための変更が行われています。

### 1. Luatan 版の主な改善点
- **Log の基本サポート**: カラーを考慮したログシステムの追加
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
- **Discord 通知の基本サポート**: サーバーイベントを Discord へ通知する基本ロジック。
    ```ini
    DISCORD_WEBHOOK_URL=
    DISCORD_CONNECT_TIMEOUT=30
    DISCORD_MAX_TIMEOUT=30
    ```
- **詳細なステータス取得**: Epic Online Services (EOS) からサーバー名やバージョン等の情報を取得する機能 (`manager status --full`)。
- **定期的なバックアップとアップデート**: supercronic による自動化処理
    ```ini
    AUTO_BACKUP_ENABLED=false
    OLD_BACKUP_DAYS=7
    AUTO_BACKUP_CRON_EXPRESSION="0 0 * * *"
    AUTO_UPDATE_ENABLED=false
    AUTO_UPDATE_CRON_EXPRESSION="0 * * * *"
    UPDATE_WARN_MINUTES=30
    ```
  - クラスター構成では、`manager update` と `AUTO_UPDATE_ENABLED` による自動更新は `CLUSTER_MASTER=true` のコンテナのみが実行します。
- **ヘルスチェック機能の導入**: コンテナの状態と実際のゲームプロセス（Wine/Proton）の状態を同期させ、異常検知時の自動再起動（自己修復）による安定稼働を図る仕組みが追加されました。
    ```ini
    SERVER_SHUTDOWN_TIMEOUT=30
    HEALTHCHECK_CRON_EXPRESSION="*/5 * * * *"
    HEALTHCHECK_SELFHEALING_ENABLED=false
    ```
- **Web 動的設定 (Dynamic Config)**:
  - `web/dynamicconfig.ini` を介した、外部や他ツールからの動的な設定読み込みをサポート。

### 2. MusclePr 版（本フォーク）独自の追加・改善点

- 単一プログラム複数マップの実現。以下の課題を解決しました。

  ❌ マップを増やすたびに、9~11GB ずつディスク容量を圧迫していくのが嫌。

  ❌ 全マップのプログラムをアップデートしないといけない。

  ❌ MOD も設定もマップ単位に管理するのが面倒。

#### 管理・自動化の強化
- **クラスター内のサーバー同期**: 
  - 複数コンテナ間で同期制御を行い、データの整合性を保ちます。
- **詳細な状態監視システム**:
  - `.signals/server_${SERVER_PORT}/status` ファイルを介して、コンテナ外部から「アップグレード中」「バックアップ中」などの詳細なステータスを確認可能。
- **メンテナンスカウントダウン**:
  - 停止・更新時にカウントダウンをゲーム内チャットへ自動送信します。
  - これにより、`UPDATE_WARN_MINUTES` は廃止しました。

#### 安定性・ダウンロードの改善
- **SteamCMD の安定化**:
  - `init.sh` における **SteamCMD ウォームアップ**（初回ログインの安定化）と、ダウンロード失敗時の**自動リトライ機能**を実装。
- **実行権限の最適化**:
  - ベースイメージを `cm2network/steamcmd:root` に変更し、ボリュームマウント時のパーミッション問題を解消。

#### Discord 通知の拡充
- `ShooterGame.log` の内容からログイン／ログアウトを検出し、Discord に通知できる様に機能拡張しました。
- EOS 登録完了時の "The Server is up" の通知も追加しました。

#### 設定の柔軟性と拡張
- **環境変数の構造化**:
  - マップ毎のコンテナに対する個別の環境変数は、`compose.yml` で以下の様に構造化されて定義しており、`.env` にコンテナに対応する変数を定義する事で容易に設定可能にしました。
    - `"SERVER_MAP=${ASA0_SERVER_MAP}"`
    - `"SESSION_NAME=${ASA_SESSION_PREFIX}${ASA0_SESSION_NAME}"`
    - `"SERVER_PORT=${ASA0_SERVER_PORT}"`
    - `"QUERY_PORT=${ASA0_QUERY_PORT}"`
    - `"DISCORD_WEBHOOK_URL=${ASA0_DISCORD_WEBHOOK_URL:-${ASA_DISCORD_WEBHOOK_URL}}"`

    > [!NOTE]
    > 
    > `.env` は、`docker compose` が暗黙的に参照しますが、コンテナ内の環境変数としては定義されません。

  - 以下の様な共通の環境変数は、`.common.env` に定義する事で容易に設定可能にしました。
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
    - `MSG_MAINTENANCE_COUNTDOWN` ... 例）"サーバーメンテナンスのため緊急停止します。安全な場所でログアウトしてください。あと %d 秒。"
    - `MSG_MAINTENANCE_COUNTDOWN_SOON` ... 例）"%d 秒前"
    - `DISCORD_MSG_JOINED` ... 例）"%s が参加しました。"
    - `DISCORD_MSG_LEFT` ... 例）"%s が退出しました。"

  - マップの指定方法の拡張
    - `<Map Name>:<Map Mod ID>` で Map Mod ID を指定できるようになりました。

      > [!TIP]
      > 
      > The Island Reforged を指定する場合
      > 
      > `.env`:
      > ```
      > ASA0_SERVER_MAP=TheIsland_WP:1460513
      > ```
      > 

- **マスター／クラスタノード対応**:
  - 複数マップを持つクラスター構成において、以下のケースで全サーバーに対して一括操作を行うケースがあります。
    - stop: プログラムの更新時やバックアップの復元時に、全サーバーを停止する必要があります。
    - save: バックアップ前に全サーバーを保存する必要があります。

    このクラスター全体に対する停止・保存要求をメンテナンスリクエストと定義しました。
  - 同期を指揮する責任は、マスターとなるコンテナにあります。マスター自身を含む全クラスタノードが同じリクエスト経路で停止・保存を実行します。
  - マスターとなるコンテナ（`asa0`）に `CLUSTER_NODES` を定義し、クラスタノード総数を指定します。
  - 各ノードは起動時に `.signals/server_<SERVER_PORT>/` を作成し、マスターはそのディレクトリを収集して `CLUSTER_PORTS` 配列を生成します。
  - 収集数が `CLUSTER_NODES` より多い場合は、ポート番号の小さい順で `CLUSTER_NODES` 件を採用します。
  - 収集数が `CLUSTER_NODES` より少ない場合は待機し、10秒でタイムアウトしてエラー停止します。
    ```bash
    # master 環境変数
    CLUSTER_NODES=2
    CLUSTER_MASTER=true

    # 起動時に .signals/server_* から検出して CLUSTER_PORTS を生成
    # 例: 7790 7791
    ```

#### 動作確認環境の追加
- `run.sh`
  ```bash
  Usage: run.sh {up|down|build|push|shellcheck}
  ```
  - up ... docker compose up -d
  - down ... docker compose down
  - build ... docker build
  - push ... docker push
  - shellcheck ... shellcheck

## バックアップ／復元の変更（クラスター単位のバックアップ）

このフォークでは、クラスタとしての一括保存のみサポートしています。

バックアップは `/opt/arkserver/ShooterGame/Saved` の以下のサブパスのみを含みます。

1. `Saved/SavedArks — マップ／トライブ／プレイヤーのセーブ（ただし `*.profilebak`, `*.tribebak`, `${SERVER_MAP}_*.ark` は除外）
2. `Saved/SaveGames` — MOD のセーブデータ
3. `Saved/Config/WindowsServer` — `Game.ini`, `GameUserSettings.ini`, `Engine.ini` 等の設定
4. `Saved/Cluster/clusters/${CLUSTER_ID}` — クラスタメタデータ

該当ディレクトリが存在しない場合は無視されます。

## クラスタ同期処理について。（メンテナンスモードについて）

以下はこのリポジトリで追加・改善した運用ロジックの要点です（マスター/クラスタノード環境での安全な更新・バックアップ・復元を目的とした改修）。

- `scripts/manager/helper.sh` にメンテナンス操作やリクエスト操作の共通ヘルパーを追加しました。
  - `enter_maintenance`, `exit_maintenance` などで、クラスター単位の停止・作業・再開処理を再利用できます。
  - `create_request_json`, `mark_request_status`, `wait_for_response` などで、リクエスト処理を補助します。
- `scripts/manager/manager.sh` の `start()` を少し改良し、RCON 待ちのログがコンテナ PID1 に届くようバックグラウンド待機を調整しました（`rcon_wait_ready` の出力が docker logs に反映される改善）。
- `scripts/manager/request_worker.sh` は、マスター/クラスタノードの両方で起動し、`.signals/server_<PORT>/request.json` の要求を処理します。
  - これは、PID1の子プロセスとして動作する事で、実行結果を docker logs に残すためです。
  - `pause` / `unpause` は `target_port` を使って実行対象ノードを限定します（対象外ノードは要求を消費しません）。
- バックアップおよび復元処理を「リクエスト駆動」に変更しました:
  - `manager restore --request <archive>` で `/opt/arkserver/.signals/server_<PORT>/request.json` を作成（重複リクエストは拒否）。
  - コンテナ PID1 からフォークした `request_worker.sh` が `request.json` を `request-XXXXX.json` にリネームし、`restore --apply <archive>` を呼んで実際の復元を行います。
  - 処理完了後に `.done.json` または `.failed.json` にリネームしてアーカイブします（途中でプロセスが落ちても残らないようトラップで保護）。

## セッション名衝突問題

- 2026/2/13 にこれまで引数で与えていて有効だったセッション名 `?SessionName=""` が、`GameUserSettings.ini` の `SessionName=` を優先する様になったため、複数のマップサーバーで同じ名前が適用され、サーバー一覧には、単一のセッション名に対し、更新するたびに異なるマップ名が表示されるという衝突が発生した。
  - これを回避するために、`GameUserSettings.ini` のセッション名をロック付きで書き換える処理を追加しました。

## チートコマンドや RCON パスワードとなる ServerAdminPassword が起動パラメータで与えても変わらない問題

- 2026/3/10 に気づいた点として、起動パラメータの `?ServerAdminPassword=` が、`GameUserSettings.ini` の `ServerAdminPassword=` を優先する様になっていたため、同様に書き換える処理を追加しました。

## .signals ディレクトリ構成

このディレクトリは、サーバープロセス（Master/Cluster Node）、マネージャー、ヘルスチェックなどのスクリプト間で状態共有や同期を行うための中心的な場所です。ファイルベースの排他制御やシグナル伝達に使用されます。

### メンテナンス制御用
停止・更新・復元・再起動といったサーバーのライフサイクルとメンテナンスモードを管理します。

| ファイル名 | 作成タイミング (作成元) | 削除タイミング (生存期間) | 目的・用途 |
| :--- | :--- | :--- | :--- |
| `maintenance.request` | `manager update` や `stop` 実行時 (`helper.sh`) | メンテナンスモード終了時、またはスクリプト終了時 | クラスター全体のメンテナンス要求シグナル。このファイルが存在すると、各サーバーは停止するか起動を待機します。 |
| `maintenance.lock` | 管理者による手動作成を想定 | メンテナンスモード終了時 (`helper.sh`) | 強制的なメンテナンスロック。サーバーの自動起動を確実に阻止するために使用されます。 |
| `server_<PORT>/waiting.flag` | `start.sh` (メンテナンス検知時) | メンテナンス終了後の再開時 | 特定のサーバーポート (`<PORT>`) がメンテナンス待機状態にあることを示します。 |
| `master_ready.flag` | MasterサーバーのRCON接続確認後 (`manager.sh`) | メンテナンス開始前、またはサーバー起動時 | Masterサーバーが完全に起動し、接続可能であることを他のクラスタノードに通知します。各ノードはこのファイルを検知してから起動を完了します。 |
| `master.lock/` | `start.sh` (Master起動時) | Masterサーバー停止時 | Masterサーバーの多重起動を防ぐためのロックディレクトリ。 |
| `updating.lock` | `manager.sh` (Update開始時) | Update完了または失敗時 | SteamCMDによるアップデート処理が進行中であることを示し、重複実行を防ぎます。 |
| `server_<PORT>/autoresume.flag` | `start.sh` (稼働中にメンテナンスに入った場合) | メンテナンス終了後の自動再開直後 | メンテナンス開始前にサーバーが起動していたことを記録し、メンテナンス終了後に自動的に再起動させるためのフラグです。 |

### リクエスト管理用
バックアップや保存、復元など、非同期で実行されるタスクの受け渡しと排他制御を行います。

| ファイル名 | 作成タイミング (作成元) | 削除タイミング (生存期間) | 目的・用途 |
| :--- | :--- | :--- | :--- |
| `server_<PORT>/request.json` | `manager backup --request` 等の実行時 (`helper.sh`) | `request_worker.sh` が処理を開始した直後 | 非同期タスク（バックアップ・リストア・pause/unpause など）の要求ファイル。ワーカープロセスがこれを検知して処理を開始します。 |
| `server_<PORT>/request-<ID>.json` | `request_worker.sh` が `request.json` をリネーム | 処理完了時に `*.done.json` / `*.failed.json` へ移行。履歴は7日後に自動削除 (`helper.sh`) | `request.json` が処理中であることを示します。完了後は履歴ファイルとして残ります。 |
| `server_<PORT>/request.lock/` | `request_worker.sh` の処理開始時 | 処理完了時、または失敗時 | リクエスト処理の排他制御用ディレクトリ（ミューテックス）。同時に複数のリクエストが処理されるのを防ぎます。 |

### 起動遅延用
設定ファイルの競合回避など、起動プロセスにおける一時的な待機・同期を行います。

| ファイル名 | 作成タイミング (作成元) | 削除タイミング (生存期間) | 目的・用途 |
| :--- | :--- | :--- | :--- |
| `session_name.lock/` | セッション名生成/取得時 (`helper.sh`) | 生成/取得処理の完了直後 | `GameUserSettings.ini` のセッション名設定時の競合を防ぐための排他制御用ディレクトリ。 |

### 状態表示用
外部監視やステータス確認コマンドのために、現在のサーバー状態を保持します。

| ファイル名 | 作成タイミング (作成元) | 削除タイミング (生存期間) | 目的・用途 |
| :--- | :--- | :--- | :--- |
| `server_<PORT>/status` | サーバーの状態変化時 (`update_status`) | サーバー再起動時 | 外部監視用に、現在のサーバーの詳細ステータス（"Ready", "Updating", "Starting" 等）をテキストで保持します。 |
