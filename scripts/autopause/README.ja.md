# Autopause ツール

このディレクトリには、Dockerコンテナ内で動作する自動一時停止（AUTO_PAUSE）機能の実装が含まれます。

## 構成要素

### コアスクリプト

- `init.sh`: サーバー起動時に呼び出され、各コンポーネントを初期化・起動します。
- `autopause_controller.sh`: メインの制御ループ。RCON経由でプレイヤー数を監視し、スリープ（一時停止/停止）と起床を管理します。
- `autopause_knockd.sh`: パケット着信をトリガーに起床させるための knockd を設定し、`manager pause` / `manager unpause` から起動・停止を制御します。
- `knockd_ip_filter.sh`: knockd から渡された送信元IPをホワイト/ブラック/グレーリストで判定し、`unpause` の可否を決定します。
- `knockd_whitelist_autoupdate.sh`: ログファイル（`LOG_DIR` + `LOG_FILE` で決定される `LOG_PATH`）の `IP for incoming account ... - IP x.x.x.x` 行を解析し、正規接続IPをホワイトリストへ自動反映します。
- `knockd_greylist_append.sh`: 未許可IPやブラックリストIPのアクセス情報をグレーリストへ集約記録します（逆引き名・初回/最終時刻・回数を保持）。
- `eos_heartbeat.py`: サーバーが一時停止している間に、EOS（Epic Online Services）へサーバーが生存していることを通知する（ハートビート）自律エージェントです。

### mimtproxy

- `mitmproxy/`: mitmproxy を使用した高度なキャプチャとアドオンが含まれます。

## 動作の仕組み

1. `AUTO_PAUSE_ENABLED=true` の場合、`init.sh` は AutoPause 用のフラグやログを初期化します。
2. `manager start` で `autopause_controller.sh` の常駐を開始し、`manager stop` で常駐を停止します。
3. `autopause_controller.sh` が定期的にプレイヤー数をチェックします。
4. プレイヤーが0人の状態が `AUTO_PAUSE_IDLE_MINUES` 続くと、サーバーを一時停止します。
5. サーバー休止遷移時に `autopause_controller.sh` が `eos_heartbeat.py` を起動し、休止中のみ定期的なハートビートを EOS へ送信します。
6. 起床遷移時に `autopause_controller.sh` が `eos_heartbeat.py` を停止します。
7. `manager pause` 実行時に `knockd` が起動し、クライアントのUDPアクセスを検知すると `knockd_ip_filter.sh` で送信元IPを判定します。
8. IP 判定の優先順は「ブラックリスト優先」です。
   - ブラックリスト一致: `unpause` せずに無視（グレーリストへ記録）
   - ホワイトリスト一致: `manager.sh unpause` を実行
    - どちらにも未登録: グレーリストへ記録したうえで `manager.sh unpause` を実行
9. グレーリストには `ip|hostname|first_seen|last_seen|hit_count|last_reason` 形式で蓄積され、手動でブラックリスト昇格判断に利用できます。
10. ホワイトリストはゲームログから自動更新されます。
    - 抽出元: `LOG_PATH`（`LOG_DIR` + `LOG_FILE`、`LOG_FILE` 未設定時は `ShooterGame.log`）
    - 対象行: `IP for incoming account ... - IP x.x.x.x`
    - ブラックリストに含まれるIPは自動追加しません。
11. 起床時（`manager unpause`）に `knockd` 常駐を停止し、フラグ整合（`sleep_*.flag` / `wake_*.flag` の整理、`last_active_*.ts` 更新）を `manager.sh unpause` 側で保証します。

## knockd IPリストの保存先

- `AUTO_PAUSE_KNOCKD_WHITELIST_PATH`（既定: `/opt/arkserver/knockd_whitelist.txt`）
- `AUTO_PAUSE_KNOCKD_BLACKLIST_PATH`（既定: `/opt/arkserver/knockd_blacklist.txt`）
- `AUTO_PAUSE_KNOCKD_GREYLIST_PATH`（既定: `/opt/arkserver/knockd_greylist.txt`）

### 形式

- ホワイト/ブラックリスト: 1行1IPv4、`#` コメント可
- グレーリスト: `ip|hostname|first_seen|last_seen|hit_count|last_reason`

## ノード単位の一時無効化

- 無効化ファイル: `/opt/arkserver/.signals/server_<port>/autopause/disabled.lock`
- 無効化コマンド: `manager autopause-disable`（即時実行は `manager autopause-disable --apply`）
- 有効化コマンド: `manager autopause-enable`（即時実行は `manager autopause-enable --apply`）
- 状態確認: `manager autopause-status`

### 無効化中の挙動

- AUTO_PAUSE 起因の pause/wake 遷移を停止します。
- すでに sleep 中の場合は wake 遷移を実行して RUNNING を維持します。
- knockd による AUTO_PAUSE 起因の wake トリガーも停止します。
- lock を削除するまで無効状態を維持します。

## 注意点

- パケット監視によるウェイクアップ機能のため、`NET_RAW` ケーパビリティが必要です。

## トラブルシュート

- サーバーがリストから消える（休止中）
    - `eos_heartbeat.py` が正常に動作しているか、またはテンプレートファイル (`session_template.json`) が正しく生成されているか確認。
    - `EOS_HB_AGENT_LOG_PATH` (`/opt/arkserver/.signals/server_<port>/autopause/eos_hb_agent.log`) にハートビートの成功ログが出力されているか確認。

- クライアントからの接続で起きない
    - コンテナに `NET_RAW` 権限があるか確認（`podman run --cap-add=NET_RAW` など）。
    - `/opt/arkserver/.signals/server_<port>/autopause/knockd.log` に接続試行（ノック）のログが記録されているか確認。
