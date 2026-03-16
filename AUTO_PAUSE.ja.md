# 自動一時停止機能の設計

オンラインプレイヤーが0人の状態が一定期間続くと、専用サーバーをスリープ状態へ遷移させて一時停止する機能です。
これによりゲーム内時間を停止し、省電力化を行います。
一時停止中でもクライアントからの接続を成立させるため、**knockd** でポート監視を行い、即座にスリープ解除してサーバーを再開します。
専用サーバーが一時停止している間はハートビート等が行えず、クラウド上でサーバーリストを管理している EOS からはオンラインサーバーとして死んでいる状態に映ります。
これを回避するため、サーバー休止中は**自律的な代理応答エージェント**が、EOS に対して定期的に生存報告（ハートビート）を送信します。

# 分析

後述のキャプチャ例から、専用サーバーが外部へ送信している定期通信と、その要件を整理します。

- セッション更新: `POST .../sessions/{id}/lastupdated` を定期的に送信し、204を受け取って「生存」を維持する。
- セッション登録: `POST /wildcard/matchmaking/v1/.../sessions` でセッションを作成し、201でセッションID等を取得する。

## 参考: 更新周期の目安

- `sessions/*/lastupdated`: 約60-120秒

一時停止中はゲームサーバーが止まるため、外部からは「オフライン扱い」になりやすい。そのため、スリープ中に最小限の生存報告（ハートビート）を自律的に送信し、外部上（サーバーブラウザ等）は「稼働中」に見せつつ、実際の接続試行は **knockd** で検知して即時起床させる方針です。

# 設計プラン

## 1. 代理送信の対象

- セッション維持（ハートビート）
	- 対象: `/wildcard/matchmaking/v1/.../sessions/{id}/lastupdated`
	- 目的: EOS上のセッションがタイムアウトしてリストから消えないようにすること。
	- 方針: サーバー起動時に取得・保存した有効なセッションIDとアクセストークンを使用し、一時停止中にエージェントが自律的に `curl` 相当のリクエストを送信する。

## 2. 役割分担

- 稼働中
	- ゲームサーバーが本来の通信を実施。
	- 代理エージェントは停止状態とする（常駐させない）。

- 一時停止中
	- **knockd**: ゲームポート(UDP)へのパケット到着を監視し、検知したら即時起床（サーバー再開）させる。
	- **代理エージェント**: sleep 遷移時に起動し、定期的に EOS へ生存報告を送信してサーバーリストへの掲載を維持する。

## 3. 代理方式

- 代理エージェント（Pythonスクリプト）が直接 `https://api.epicgames.dev` へリクエストを送信する。

## 4. セッション管理

- サーバーが稼働中に使用している最新のセッション情報を、`AUTO_PAUSE_WORK_DIR` 配下の共有ファイルとして保持する。
	- `session_template.json` (`EOS_SESSION_TEMPLATE`): セッション登録レスポンス、`x-epic-locks`、URL、ヘッダー。
	- `eos_creds.json` (`EOS_CREDS_FILE`): `basic_auth` / `deployment_id` / `access_token` など。
- これらは主に `mitmproxy` アドオン（`scripts/autopause/mitmproxy/addons/capture.py`）で更新され、heartbeat エージェントが参照する。

## 5. フェイルセーフ

- 代理送信に失敗しても、`knockd` によるウェイクアップ機能には影響を与えない独立した設計とする。
- `SaveWorld` が失敗した場合は、pause遷移を中止する。

## 6. Save 整合性（pause 連携）

- `manager pause --apply` は `SaveWorld` 成功を必須とし、失敗時は `PAUSED` へ遷移しない。
- autopause は `SaveWorld` を直接実行せず、pause処理は `manager pause --apply` に一元化する。
- メンテナンス `save` 要求時にサーバーが `PAUSED` の場合は、`SaveWorld` 成功済みとしてACKする。

## 7. 解析用ツール

- `AUTO_PAUSE_DEBUG=true` の時は、`mitmweb` を使用して解析に利用します。
  この時、8081 ポートを使用しますので、ブラウザで確認する際は、ports 指定も必要です。

```yaml
    ports:
      - "8081:8081/tcp" # For proxy web interface (if AUTO_PAUSE_DEBUG enabled)
```

# 実装プラン

## ノード単位のAUTO_PAUSE無効化

- 無効化状態は `AUTO_PAUSE_WORK_DIR` 配下の `disabled.lock` で管理します。
	- 実体パス: `/opt/arkserver/.signals/server_<port>/autopause/disabled.lock`
- `disabled.lock` の作成/削除だけで、対象 server_<port> の AUTO_PAUSE を無効化/有効化できます。
- `disabled.lock` が存在する間は、AUTO_PAUSE 起因の pause/wake を停止します。
- sleep 中に `disabled.lock` が作成された場合は、コントローラーが wake 遷移を行い RUNNING を維持します。
- 操作は `manager autopause-disable` / `manager autopause-enable` / `manager autopause-status` を使用します。

## 1. 代理送信エージェント

- `scripts/autopause/eos_heartbeat.py` は、自律送信クライアントとして動作する。
- 動作仕様:
  - 指定されたセッションIDを使用して `POST .../lastupdated` を送信。
  - 60秒程度の間隔でループ実行。
  - HTTPS 通信は標準ライブラリ（`urllib.request`）で実施し、OS レベルの証明書設定のみを利用する。
  - `401/403` を受けた場合はトークンを再取得し、1回だけ再送する。
  - `404` を受けた場合はセッション失効とみなし、`POST /sessions` で再作成後に heartbeat を再送する。
  - `409` は lock 不整合 (`invalid_lock`) の可能性が高く、`x-epic-locks` とセッション再作成状態を確認する。
- ログは `EOS_HB_AGENT_LOG_PATH` に送信結果（Success/Fail）を出力。

### 起動タイミング

Dockerコンテナ内では、`scripts/autopause/autopause_controller.sh` が sleep 遷移時にエージェントを起動し、wake 遷移時に停止します。

### ログ出力の例

コンテナ内の `/opt/arkserver/.signals/server_<port>/autopause/` 配下に以下のようなログが出力されます：

- `autopause.log`: コントローラーのメインログ
- `eos_hb_agent.log`: エージェントの動作ログ
- `eos_hb_agent_stdout.log`: エージェント標準出力/標準エラー
- `knockd.log`: knockdのログ

# キャプチャログ

## トークン要求

### リクエスト POST /auth/v1/oauth/token

Basic 認証の資格情報と、deployment_id は、`manager.sh` の `full_status_setup()` が生成する、`/opt/manager/.eos.config` が利用できます。
しかし、運用上としては、mitmproxy の `capture.py` プラグインによって、専用サーバーが実際に通信したパケットから得られた実際のものを利用しています。

```http title="リクエスト"
POST /auth/v1/oauth/token HTTP/1.1
Host: api.epicgames.dev
Accept-Encoding: identity
Content-Type: application/x-www-form-urlencoded
Accept: application/json
Authorization: Basic (credential)
X-Epic-Correlation-ID: EOS-3-tEgVjoEkqobdoS5Nfqgg-f4nvMjam-0el2UhAE8_RFg
User-Agent: EOS-SDK/1.16.2-32273396 (Wine/10.0) ARK Survival Ascended/0.0.1
X-EOS-Version: 1.16.2-32273396
Content-Length: 76

grant_type=client_credentials&deployment_id=ad9a8feffb3b4b2ca315546f038c3ae2
```

### レスポンス

```json title="JSON レスポンス"
{
	"access_token":"(Omitted for credential)",
	"token_type":"bearer",
	"expires_at":"2026-03-06T01:16:51.551Z",
	"features":[
		"Achievements","Connect","Ecom","Leaderboards","Matchmaking","Metrics","Stats","Voice"
	],
	"organization_id":"o-usvfbmlqdt678vrp36qvm2d5cz2cpr",
	"product_id":"985dc4d67ff142588b6393c46b1dff84",
	"sandbox_id":"dae80c0d4e3b4d648498b48af609b8bb",
	"deployment_id":"ad9a8feffb3b4b2ca315546f038c3ae2",
	"expires_in":3599
}
```

<details>
<summary>詳細</summary>

```http title="レスポンス"
HTTP/1.1 200 OK
Date: Fri, 06 Mar 2026 00:16:51 GMT
Content-Type: application/json
Transfer-Encoding: chunked
Connection: keep-alive
CF-RAY: 9d7d2c90a97a52ae-KIX
Cache-Control: no-store
pragma: no-cache
x-epic-correlation-id: EOS-3-tEgVjoEkqobdoS5Nfqgg-f4nvMjam-0el2UhAE8_RFg
vary: Accept-Encoding
cf-cache-status: DYNAMIC
Set-Cookie: __cf_bm=eZwk38oDLkgQHwSc_V38kaEbdm3qcL3yON_X8U6twrw-1772756211-1.0.1.1-ZecV5KBYpiCff8uqIDzzg7zgYC_hAimGrz0OMU3YnpRTcy.zUKefn1lcydkdDfnVJCZeO8.8hwAXCppf5NommD03.DeldmGpujcp6cAksMo; path=/; expires=Fri, 06-Mar-26 00:46:51 GMT; domain=.epicgames.dev; HttpOnly; Secure; SameSite=None
Server: cloudflare
alt-svc: h3=":443"; ma=86400

5b1
{"access_token":"(Omitted for credential)","token_type":"bearer","expires_at":"2026-03-06T01:16:51.551Z","features":["Achievements","Connect","Ecom","Leaderboards","Matchmaking","Metrics","Stats","Voice"],"organization_id":"o-usvfbmlqdt678vrp36qvm2d5cz2cpr","product_id":"985dc4d67ff142588b6393c46b1dff84","sandbox_id":"dae80c0d4e3b4d648498b48af609b8bb","deployment_id":"ad9a8feffb3b4b2ca315546f038c3ae2","expires_in":3599}
0


```

</details>

## セッションの登録

### リクエスト POST /wildcard/matchmaking/v1/{deployment_id}/sessions

```json
{
	"deployment":"ad9a8feffb3b4b2ca315546f038c3ae2",
	"id":"",
	"bucket":"TestGameMode_C:<None>:TheIsland_WP",
	"settings":{
		"maxPublicPlayers":10,
		"allowInvites":true,
		"shouldAdvertise":true,
		"allowReadById":true,
		"allowJoinViaPresence":true,
		"allowJoinInProgress":true,
		"allowConferenceRoom":false,
		"checkSanctions":false,
		"allowMigration":false,
		"rejoinAfterKick":""
	},
	"totalPlayers":0,
	"openPublicPlayers":10,
	"publicPlayers":[],
	"started":false,
	"attributes":{
		"ADDRESSBOUND_s":"0.0.0.0:7790",
		"ADDRESSDEV_s":"172.30.1.4,127.0.0.1",
		"__EOS_BLISTENING_b":true,
		"__EOS_BUSESPRESENCE_b":true,
		"ENABLEDMODS_s":"929800,929420,935408,928793,933975,940975,1460513",
		"ENABLEDMODSFILEIDS_s":"6765175,7060909,7232573,6889149,6570666,7709272,7662488",
		"SESSIONNAME_s":"A-B-C-D - TEST2 - Alpha - (v83.24)",
		"SESSIONNAMEUPPER_s":"A-B-C-D - TEST2 - ALPHA - (V83.24)",
		"GAMEMODE_s":"TestGameMode_C",
		"MAPNAME_s":"TheIsland_WP",
		"FRIENDLYMAPNAME_s":"TheIsland_WP",
		"DAYTIME_s":"4",
		"MATCHTIMEOUT_d":120,
		"SEARCHKEYWORDS_s":"Custom",
		"MODID_l":0,
		"CUSTOMSERVERNAME_s":"A-B-C-D - TEST2 - Alpha",
		"SERVERPASSWORD_b":false,
		"BUILDID_s":"83",
		"SOTFMATCHSTARTED_b":false,
		"EOSSERVERPING_l":81,
		"MINORBUILDID_s":"24",
		"CLUSTERID_s":"abcd",
		"ALLOWDOWNLOADCHARS_l":1,
		"ALLOWDOWNLOADDINOS_l":1,
		"ALLOWDOWNLOADITEMS_l":1,
		"SERVERUSESBATTLEYE_b":false,
		"OFFICIALSERVER_s":"0",
		"STEELSHIELDENABLED_l":0,
		"SERVERPLATFORMTYPE_s":"PC+XSX+WINGDK+PS5",
		"ISPRIVATE_l":0,
		"SESSIONISPVE_l":0,
		"LEGACY_l":0
	}
}
```

<details>
<summary>詳細</summary>

```http title="リクエスト"
POST /wildcard/matchmaking/v1/ad9a8feffb3b4b2ca315546f038c3ae2/sessions HTTP/1.1
Host: api.epicgames.dev
Accept-Encoding: identity
Content-Type: application/json
Accept: application/json
Authorization: Bearer (credential)
X-Epic-Correlation-ID: EOS-3-tEgVjoEkqobdoS5Nfqgg-I-Vs8A3adkiJ5h7dK3r6Vw
User-Agent: EOS-SDK/1.16.2-32273396 (Wine/10.0) ARK Survival Ascended/0.0.1
X-EOS-Version: 1.16.2-32273396
Content-Length: 1419

{"deployment":"ad9a8feffb3b4b2ca315546f038c3ae2","id":"","bucket":"TestGameMode_C:<None>:TheIsland_WP","settings":{"maxPublicPlayers":10,"allowInvites":true,"shouldAdvertise":true,"allowReadById":true,"allowJoinViaPresence":true,"allowJoinInProgress":true,"allowConferenceRoom":false,"checkSanctions":false,"allowMigration":false,"rejoinAfterKick":""},"totalPlayers":0,"openPublicPlayers":10,"publicPlayers":[],"started":false,"attributes":{"ADDRESSBOUND_s":"0.0.0.0:7790","ADDRESSDEV_s":"172.30.1.4,127.0.0.1","__EOS_BLISTENING_b":true,"__EOS_BUSESPRESENCE_b":true,"ENABLEDMODS_s":"929800,929420,935408,928793,933975,940975,1460513","ENABLEDMODSFILEIDS_s":"6765175,7060909,7232573,6889149,6570666,7709272,7662488","SESSIONNAME_s":"A-B-C-D - TEST2 - Alpha - (v83.24)","SESSIONNAMEUPPER_s":"A-B-C-D - TEST2 - ALPHA - (V83.24)","GAMEMODE_s":"TestGameMode_C","MAPNAME_s":"TheIsland_WP","FRIENDLYMAPNAME_s":"TheIsland_WP","DAYTIME_s":"4","MATCHTIMEOUT_d":120,"SEARCHKEYWORDS_s":"Custom","MODID_l":0,"CUSTOMSERVERNAME_s":"A-B-C-D - TEST2 - Alpha","SERVERPASSWORD_b":false,"BUILDID_s":"83","SOTFMATCHSTARTED_b":false,"EOSSERVERPING_l":81,"MINORBUILDID_s":"24","CLUSTERID_s":"abcd","ALLOWDOWNLOADCHARS_l":1,"ALLOWDOWNLOADDINOS_l":1,"ALLOWDOWNLOADITEMS_l":1,"SERVERUSESBATTLEYE_b":false,"OFFICIALSERVER_s":"0","STEELSHIELDENABLED_l":0,"SERVERPLATFORMTYPE_s":"PC+XSX+WINGDK+PS5","ISPRIVATE_l":0,"SESSIONISPVE_l":0,"LEGACY_l":0}}

```

</details>

### レスポンス

注意: 下の JSON は「差分説明のために人手でコメント化した抜粋」です。実際の EOS レスポンスはコメント無しの通常 JSON で返却されます。
```json title="変化なし部分はコメントアウト"
{
	"publicData":{
		//"deployment":"ad9a8feffb3b4b2ca315546f038c3ae2",
		"id":"126361609d5b41b9888df3bddf25d4e4",
		//"bucket":"TestGameMode_C:<None>:TheIsland_WP",
		"settings":{
			//"maxPublicPlayers":10,
			//"allowInvites":true,
			//"shouldAdvertise":true,
			//"allowReadById":true,
			//"allowJoinViaPresence":true,
			//"allowJoinInProgress":true,
			//"allowConferenceRoom":false,
			//"checkSanctions":false,
			//"allowMigration":false,
			//"rejoinAfterKick":"",
			"platforms":null
		},
		//"totalPlayers":0,
		//"openPublicPlayers":10,
		//"publicPlayers":[],
		//"started":false,
		"lastUpdated":"2026-03-06T00:18:29.659Z",
		"attributes":{
			//"MINORBUILDID_s":"24",
			//"MODID_l":0,
			//"CUSTOMSERVERNAME_s":"A-B-C-D - TEST2 - Alpha",
			//"ADDRESSDEV_s":"172.30.1.4,127.0.0.1",
			//"ISPRIVATE_l":0,
			//"SERVERPASSWORD_b":false,
			//"MATCHTIMEOUT_d":120.0,
			//"ENABLEDMODSFILEIDS_s":"6765175,7060909,7232573,6889149,6570666,7709272,7662488",
			//"DAYTIME_s":"4",
			//"SOTFMATCHSTARTED_b":false,
			//"STEELSHIELDENABLED_l":0,
			//"FRIENDLYMAPNAME_s":"TheIsland_WP",
			//"SERVERUSESBATTLEYE_b":false,
			//"EOSSERVERPING_l":81,
			//"ALLOWDOWNLOADDINOS_l":1,
			//"ALLOWDOWNLOADCHARS_l":1,
			//"OFFICIALSERVER_s":"0",
			//"GAMEMODE_s":"TestGameMode_C",
			"ADDRESS_s":"123.45.67.89",
			//"SEARCHKEYWORDS_s":"Custom",
			//"__EOS_BLISTENING_b":true,
			//"ALLOWDOWNLOADITEMS_l":1,
			//"LEGACY_l":0,
			//"ADDRESSBOUND_s":"0.0.0.0:7790",
			//"SESSIONISPVE_l":0,
			//"__EOS_BUSESPRESENCE_b":true,
			//"CLUSTERID_s":"abcd",
			//"ENABLEDMODS_s":"929800,929420,935408,928793,933975,940975,1460513",
			//"SESSIONNAMEUPPER_s":"A-B-C-D - TEST2 - ALPHA - (V83.24)",
			//"SERVERPLATFORMTYPE_s":"PC+XSX+WINGDK+PS5",
			//"MAPNAME_s":"TheIsland_WP",
			//"BUILDID_s":"83",
			//"SESSIONNAME_s":"A-B-C-D - TEST2 - Alpha - (v83.24)"
		},
		"owner":"Client_xyza7891muomRmynIIHaJB9COBKkwj6n",
		"ownerPlatformId":null
	},
	"privateData":{
		"index":-1008513096,
		"lock":"3ce8bd66237f4c3cafaedc0d9778d3a3",
		"invites":[],
		"historicalPlayers":[],
		"pendingDelete":null
	}
}

```

<details>
<summary>詳細</summary>

```http title="レスポンス"
HTTP/1.1 200 OK
Date: Fri, 06 Mar 2026 00:18:29 GMT
Content-Type: application/json
Transfer-Encoding: chunked
Connection: keep-alive
CF-RAY: 9d7d2ef6c83252ae-KIX
x-epic-correlation-id: EOS-3-tEgVjoEkqobdoS5Nfqgg-I-Vs8A3adkiJ5h7dK3r6Vw
vary: Accept-Encoding
cf-cache-status: DYNAMIC
Set-Cookie: __cf_bm=cSHl19YxFK6aPa4RjaRfjUEyoZT7XsgOAts_YjFDBrc-1772756309-1.0.1.1-07r6AkAfqTyRDqy7W8RaC3ghoXhE6n5RJutHW6MDfpFXpYTjSVmwgN8hp8VumsauCf7gheD6c1egZ5poKFYqzWWO3K9LwJzskqbSXuo1PA8; path=/; expires=Fri, 06-Mar-26 00:48:29 GMT; domain=.epicgames.dev; HttpOnly; Secure; SameSite=None
Server: cloudflare
alt-svc: h3=":443"; ma=86400

6e2
{"publicData":{"deployment":"ad9a8feffb3b4b2ca315546f038c3ae2","id":"126361609d5b41b9888df3bddf25d4e4","bucket":"TestGameMode_C:<None>:TheIsland_WP","settings":{"maxPublicPlayers":10,"allowInvites":true,"shouldAdvertise":true,"allowReadById":true,"allowJoinViaPresence":true,"allowJoinInProgress":true,"allowConferenceRoom":false,"checkSanctions":false,"allowMigration":false,"rejoinAfterKick":"","platforms":null},"totalPlayers":0,"openPublicPlayers":10,"publicPlayers":[],"started":false,"lastUpdated":"2026-03-06T00:18:29.659Z","attributes":{"MINORBUILDID_s":"24","MODID_l":0,"CUSTOMSERVERNAME_s":"A-B-C-D - TEST2 - Alpha","ADDRESSDEV_s":"172.30.1.4,127.0.0.1","ISPRIVATE_l":0,"SERVERPASSWORD_b":false,"MATCHTIMEOUT_d":120.0,"ENABLEDMODSFILEIDS_s":"6765175,7060909,7232573,6889149,6570666,7709272,7662488","DAYTIME_s":"4","SOTFMATCHSTARTED_b":false,"STEELSHIELDENABLED_l":0,"FRIENDLYMAPNAME_s":"TheIsland_WP","SERVERUSESBATTLEYE_b":false,"EOSSERVERPING_l":81,"ALLOWDOWNLOADDINOS_l":1,"ALLOWDOWNLOADCHARS_l":1,"OFFICIALSERVER_s":"0","GAMEMODE_s":"TestGameMode_C","ADDRESS_s":"123.45.67.89","SEARCHKEYWORDS_s":"Custom","__EOS_BLISTENING_b":true,"ALLOWDOWNLOADITEMS_l":1,"LEGACY_l":0,"ADDRESSBOUND_s":"0.0.0.0:7790","SESSIONISPVE_l":0,"__EOS_BUSESPRESENCE_b":true,"CLUSTERID_s":"abcd","ENABLEDMODS_s":"929800,929420,935408,928793,933975,940975,1460513","SESSIONNAMEUPPER_s":"A-B-C-D - TEST2 - ALPHA - (V83.24)","SERVERPLATFORMTYPE_s":"PC+XSX+WINGDK+PS5","MAPNAME_s":"TheIsland_WP","BUILDID_s":"83","SESSIONNAME_s":"A-B-C-D - TEST2 - Alpha - (v83.24)"},"owner":"Client_xyza7891muomRmynIIHaJB9COBKkwj6n","ownerPlatformId":null},"privateData":{"index":-1008513096,"lock":"3ce8bd66237f4c3cafaedc0d9778d3a3","invites":[],"historicalPlayers":[],"pendingDelete":null}}
0


```

</details>

## セッションの更新

### リクエスト /wildcard/matchmaking/v1/{deployment_id}/sessions/{id}/lastupdated

`x-epic-locks: 3ce8bd66237f4c3cafaedc0d9778d3a3` のように、セッション登録で得られた lock をヘッダーで指定する必要があります。

補足: lock が古い場合は `409 invalid_lock` になり、heartbeat は失敗します。実装ではこのケースをログで検知できるため、必要に応じてセッション再作成（`POST /sessions`）で lock を更新します。

<details>
<summary>詳細</summary>

```http title="リクエスト"
POST /wildcard/matchmaking/v1/ad9a8feffb3b4b2ca315546f038c3ae2/sessions/126361609d5b41b9888df3bddf25d4e4/lastupdated HTTP/1.1
Host: api.epicgames.dev
Accept: */*
Accept-Encoding: identity
x-epic-locks: 3ce8bd66237f4c3cafaedc0d9778d3a3
Content-Type: application/x-www-form-urlencoded
Authorization: Bearer (credential)
X-Epic-Correlation-ID: EOS-3-tEgVjoEkqobdoS5Nfqgg-kiLZgRJapkKzXYg1wPGaIg
User-Agent: EOS-SDK/1.16.2-32273396 (Wine/10.0) ARK Survival Ascended/0.0.1
X-EOS-Version: 1.16.2-32273396
Content-Length: 0

```

</details>

### レスポンス

<details>
<summary>詳細</summary>

```http title="レスポンス"
HTTP/1.1 204 No Content
Date: Fri, 06 Mar 2026 00:19:00 GMT
Connection: keep-alive
CF-RAY: 9d7d2fb41b8b52ae-KIX
x-epic-correlation-id: EOS-3-tEgVjoEkqobdoS5Nfqgg-kiLZgRJapkKzXYg1wPGaIg
vary: Accept-Encoding
cf-cache-status: DYNAMIC
Set-Cookie: __cf_bm=D8FBMdPTS6BlADoe3fSvtoATr0sDsd9MYi9scji.0rM-1772756340-1.0.1.1-ItAsdQu9q5FntuAOaglrIPp_X1tZFC0JEmv32YwvtatjhupdixLW2jj8C3hc9n.TYsM0xVN153KRyloPNnwXU87zUrvZSkb5RImsHNtRYe4; path=/; expires=Fri, 06-Mar-26 00:49:00 GMT; domain=.epicgames.dev; HttpOnly; Secure; SameSite=None
Server: cloudflare
alt-svc: h3=":443"; ma=86400

```

</details>
