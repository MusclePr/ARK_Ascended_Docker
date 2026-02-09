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

  ❌ マップを増やすたびに、11GB ずつディスク容量を圧迫していくのが嫌。

  ❌ 全マップのプログラムをアップデートしないといけない。

  ❌ MOD も設定もマップ単位に管理するのが面倒。

#### 管理・自動化の強化
- **クラスター間同期 (Master-Slave モード)**: 
  - `SLAVE_PORTS` 設定により、複数コンテナ間でのアップデートやバックアップの排他制御を行い、データの整合性を保ちます。
- **詳細な状態監視システム**:
  - `.signals/status_${SERVER_PORT}` ファイルを介して、コンテナ外部から「アップグレード中」「バックアップ中」などの詳細なステータスを確認可能。
- **メンテナンスカウントダウン**: 
  - 停止・更新時にカウントダウンをゲーム内チャットへ自動送信します。（現在は日本語）

#### 安定性・ダウンロードの改善
- **SteamCMD の安定化**:
  - `init.sh` における **SteamCMD ウォームアップ**（初回ログインの安定化）と、ダウンロード失敗時の**自動リトライ機能**を実装。
- **実行権限の最適化**:
  - ベースイメージを `cm2network/steamcmd:root` に変更し、ボリュームマウント時のパーミッション問題を解消。

#### Discord 通知の拡充
- `ShooterGame.log` の内容からログイン／ログアウトを検出し、Discord に通知できる様に機能拡張しました。

#### 設定の柔軟性と拡張
- **環境変数の構造化**:
  - マップ毎のコンテナに対する個別の環境変数は、`compose.yml` で以下の様に構造化されて定義しており、`.env` にコンテナに対応する変数を定義する事で容易に設定可能にしました。
    - `"SERVER_MAP=${ASA0_SERVER_MAP}"`
    - `"SESSION_NAME=${ASA_SESSION_PREFIX}${ASA0_SESSION_NAME}"`
    - `"SERVER_PORT=${ASA0_SERVER_PORT}"`
    - `"QUERY_PORT=${ASA0_QUERY_PORT}"`
    - `"DISCORD_WEBHOOK_URL=${ASA0_DISCORD_WEBHOOK_URL:-${ASA_DISCORD_WEBHOOK_URL}}"`

    > [!WARNING]
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

- **マスター／スレーブ対応**:
  - プログラムの更新時に全サーバーを安全に停止する責任がマスターにあり、スレーブはマスターの要求に対して安全に停止する同期処理を行います。
  - `asa0` のコンテナはマスターとして、マスターのみに与えられる環境変数 `SLAVE_PORTS` を定義し、各スレーブ（`asa1`～）に定義されている `SERVER_PORT` のポート番号をカンマで列挙する事で連動可能になります。

#### 動作確認環境の追加
- `run.sh`
  ```bash
  Usage: run.sh {up|down|build|push}
  ```
  - up ... docker compose up -d
  - down ... docker compose down
  - build ... docker build
  - push ... docker push

## バックアップ／復元の変更（サーバー単体の限定バックアップ）

このフォークでは、クラスタとして複数マップの一括保存をサポートしていません。

バックアップは `/opt/arkserver/ShooterGame/Saved` の以下のサブパスのみを含みます。

1. `Saved/SavedArks/${SERVER_MAP}` — マップ／トライブ／プレイヤーのセーブ（ただし `*.profilebak`, `*.tribebak`, `${SERVER_MAP}_*.ark` は除外）
2. `Saved/SaveGames` — MOD のセーブデータ
3. `Saved/Config/WindowsServer` — `Game.ini`, `GameUserSettings.ini`, `Engine.ini` 等の設定
4. `Saved/Cluster/clusters/${CLUSTER_ID}` — クラスタメタデータ

該当ディレクトリが存在しない場合は無視されます。

復元には以下のオプションを追加しました。

- `--no-cluster` — クラスタデータを復元しない
- `--no-mod` — MOD の `SaveGames` を復元しない
- `--no-config` — `Config/WindowsServer` を復元しない
- `--map-only` — 省略形。`--no-cluster --no-mod --no-config` と同等
- `--no-start` — 復元後に自動でサーバーを起動しない

これによりバックアップ容量を削減し、単体ノードでの復元が容易になります。詳細は `manager restore --help` を参照してください。
