# Autopause ツール

このディレクトリには、Dockerコンテナ内で動作する自動一時停止（AUTO_PAUSE）機能の実装が含まれます。

## 構成要素

### コアスクリプト

- `init.sh`: サーバー起動時に呼び出され、各コンポーネントを初期化・起動します。
- `autopause_controller.sh`: メインの制御ループ。RCON経由でプレイヤー数を監視し、スリープ（一時停止/停止）と起床を管理します。
- `autopause_knockd.sh`: パケット着信をトリガーに起床させるための knockd を設定し、`manager pause` / `manager unpause` から起動・停止を制御します。
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
7. `manager pause` 実行時に `knockd` が起動し、クライアントのUDPアクセスを検知すると `manager.sh unpause` を直接実行します。
8. 起床時（`manager unpause`）に `knockd` 常駐を停止し、フラグ整合（`sleep_*.flag` / `wake_*.flag` の整理、`last_active_*.ts` 更新）を `manager.sh unpause` 側で保証します。

## 注意点

- パケット監視によるウェイクアップ機能のため、`NET_RAW` ケーパビリティが必要です。

## トラブルシュート

- サーバーがリストから消える（休止中）
    - `eos_heartbeat.py` が正常に動作しているか、またはテンプレートファイル (`session_template.json`) が正しく生成されているか確認。
    - `EOS_HB_AGENT_LOG_PATH` (`/opt/arkserver/.signals/server_<port>/autopause/eos_hb_agent.log`) にハートビートの成功ログが出力されているか確認。

- クライアントからの接続で起きない
    - コンテナに `NET_RAW` 権限があるか確認（`podman run --cap-add=NET_RAW` など）。
    - `/opt/arkserver/.signals/server_<port>/autopause/knockd.log` に接続試行（ノック）のログが記録されているか確認。
