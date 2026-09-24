# Web スタートアップコンソール 公開設計（Cloudflare Tunnel + Access）

状態: **設計のみ（NOT APPLIED）** — Cloudflare への適用は人間の Y/N 後（Approval PR）。
正本: 本ファイル。上位方針: `docs/architecture/Cloudflare公開基盤仕様.md` §4/§5、`CLAUDE.md` §5。

## 1. 目的と決定事項

| 項目 | 決定 |
|---|---|
| 公開 hostname | **`claude-startuptools.mirai-dx-platform.com`** |
| 公開方式 | Cloudflare **Tunnel**（ホスト側の `127.0.0.1:3740` を公開 DNS へ出す）+ **Access** |
| アプリ側 bind | **`127.0.0.1:3740` のまま**（LAN へは bind しない。公開面は Cloudflare エッジのみ） |
| 入口認証 | **Cloudflare Access**（Google IdP）。許可は **`kensan1969@gmail.com` のみ** |
| アプリ側 Basic 認証 | 任意（多層防御）。`STARTUP_WEB_PASSWORD` を env-file 0600 に置く場合のみ有効 |
| 認可モデル | email 完全一致の `allow` 1 件 + catch-all `deny`。**ドメイン単位許可・ワイルドカード・IP 条件は禁止** |
| service token | 既定 **無効**（自動化経路は開けない。必要になった時点で別 Approval） |
| トンネル名 / unit | 既存ホスト慣例に合わせ **`claude-startuptools`** / **`claude-startuptools-cloudflared.service`**、config は `~/.cloudflared/claude-startuptools-config.yml` |

設計値（repo 管理・適用前）:

- `config/cloudflare/web-startup-tunnel.yml` … cloudflared 設定テンプレート
- `config/cloudflare/web-startup-access-policy.json` … Access application + policy

どちらも `scripts/web/public-access-config.test.js` が「許可が 1 メールのみ」「catch-all deny が最後」
「LAN/0.0.0.0 を含まない」「placeholder のみで実 ID / secret を commit していない」を機械的に固定する。

## 1.1 適用前の観察（read-only / 2026-09-24 時点）

| 観察 | 結果 | 設計への影響 |
|---|---|---|
| `cloudflared tunnel --config config/cloudflare/web-startup-tunnel.yml ingress validate` | **OK**（検証済み） | テンプレートの ingress はそのまま使える |
| `cloudflared tunnel list` | 既存トンネル多数（`civil-docs`, `asep-poc`, `bim-platform` …）。`claude-startuptools` は**未作成** | §4 の `tunnel create` が必要 |
| `dig claude-startuptools.mirai-dx-platform.com` | レコードなし（apex の NS は Cloudflare: `nia.ns` / `kareem.ns`） | `tunnel route dns` は新規レコード追加（Approval 対象） |
| 既存ホスト構成 | サービスごとに `~/.cloudflared/<name>-config.yml` + `<name>-cloudflared.service`（1 サービス 1 トンネル） | 本設計も同じ命名・粒度に合わせる |
| `cloudflared` | 導入済み (`/usr/local/bin/cloudflared`) | 導入作業は不要 |
| Cloudflare 認証 | `~/.cloudflared/cert.pem` あり（`tunnel list` 成功） | `tunnel login` は不要 |

## 2. 構成

```text
ブラウザ (kensan1969@gmail.com)
   │ https://claude-startuptools.mirai-dx-platform.com
   ▼
Cloudflare エッジ
   ├─ Access application  … 未認証は Google ログインへ / 許可外メールは拒否 (403)
   └─ Tunnel (cloudflared) … エッジ → ホストの loopback
        ▼
  127.0.0.1:3740  systemd --user `claudeos-web-startup.service`
     └─ scripts/web/startup-server.js  → bin/start-claude.sh / bin/autonomy.sh
```

- 公開面に到達できるのは Access を通った 1 アカウントのみ。LAN / インターネットから
  `3740` へ直接は到達できない（loopback bind）。
- コンソールは Claude 起動操作を行うため、**認可モデルの変更は高リスク変更**として扱う
  （`CLAUDE.md` §5: 公開 DNS / custom domain / Cloudflare Access policy / 認証方式・認可モデル）。

## 3. Human Gate（私が実行しないこと）

次は **適用前に停止し、人間の Y/N を得る**。本設計では未実行（NOT RUN）。

1. `cloudflared tunnel create` / `route dns`（DNS レコード作成）
2. Access application / policy の作成・更新（＝認可モデル）
3. 既存トンネル・既存 Access policy の変更
4. `STARTUP_WEB_PASSWORD` の作成・変更（secret）

## 4. 手順（人間が実行）

```bash
# 0. 前提: コンソールが loopback で常駐していること
bash bin/web-startup-service.sh --register      # unit 生成 + enable --now (127.0.0.1:3740)
bash bin/web-startup-service.sh --status
curl -fsS http://127.0.0.1:3740/api/health

# 1. 前提確認（cloudflared は導入済み。cron も login も不要）
cloudflared --version

# 2. トンネル作成（← 人間 Y/N / 新規トンネル）
cloudflared tunnel create claude-startuptools        # 表示される <TUNNEL_ID> を控える

# 3. 設定配置（既存慣例: ~/.cloudflared/<name>-config.yml。値は commit しない）
cp config/cloudflare/web-startup-tunnel.yml ~/.cloudflared/claude-startuptools-config.yml
#   <TUNNEL_ID> を置換し、tunnel: / credentials-file: を実値にする
chmod 600 ~/.cloudflared/claude-startuptools-config.yml ~/.cloudflared/<TUNNEL_ID>.json
cloudflared tunnel --config ~/.cloudflared/claude-startuptools-config.yml ingress validate

# 4. DNS route（← 人間 Y/N。新規 CNAME が作られる）
cloudflared tunnel route dns claude-startuptools claude-startuptools.mirai-dx-platform.com

# 5. トンネル常駐化（既存慣例に合わせた専用 systemd unit）
sudo tee /etc/systemd/system/claude-startuptools-cloudflared.service >/dev/null <<'UNIT'
[Unit]
Description=ClaudeOS Web Startup Console Cloudflare Tunnel (claude-startuptools.mirai-dx-platform.com)
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --config /home/kensan/.cloudflared/claude-startuptools-config.yml run claude-startuptools
Restart=on-failure
RestartSec=5
User=kensan

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload && sudo systemctl enable --now claude-startuptools-cloudflared.service

# 6. Access application + policy（← 人間 Y/N。認可モデル変更）
#    config/cloudflare/web-startup-access-policy.json の設計値を API / Dashboard で適用する。
#    <GOOGLE_IDP_ID> は account 固有値へ置換（既存 hostname の Access app 設定を流用してよい）。
#    CLOUDFLARE_ACCOUNT_ID / CLOUDFLARE_API_TOKEN は環境変数から読む。
```

Access を API で適用する場合の形（値は環境変数から。API token を出力しない）:

```bash
# application 作成 → 返った <APP_ID> / <AUD> を使う
curl -sS -X POST "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/access/apps" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H 'Content-Type: application/json' \
  --data @<(jq -c '{name:.application.name,domain:.application.domain,type:.application.type,
                     session_duration:.application.session_duration,
                     allowed_idps:.application.allowed_idps,
                     auto_redirect_to_identity:.application.auto_redirect_to_identity,
                     http_only_cookie_attribute:.application.http_only_cookie_attribute,
                     enable_binding_cookie:.application.enable_binding_cookie}'
              config/cloudflare/web-startup-access-policy.json)

# policy 作成 (allow → deny の順に 1 件ずつ)
curl -sS -X POST "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/access/apps/$APP_ID/policies" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H 'Content-Type: application/json' \
  --data "$(jq -c '.policies[0]' config/cloudflare/web-startup-access-policy.json)"
curl -sS -X POST "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/access/apps/$APP_ID/policies" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H 'Content-Type: application/json' \
  --data "$(jq -c '.policies[1]' config/cloudflare/web-startup-access-policy.json)"
```

## 5. 検証（適用後の read-back・必須）

```bash
# a. 未認証 → Access のログインへリダイレクトされる (200 でコンテンツが返ったら認可が抜けている)
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://claude-startuptools.mirai-dx-platform.com/api/health

# b. 許可メールでログイン後 → 200 / {"ok":true}
#    (ブラウザで Access ログイン → コンソールが表示されること)

# c. 許可外アカウントでログイン試行 → 403 (Access に拒否される)

# d. origin が loopback のままであること (LAN から到達不能)
ss -ltnp | grep 3740                 # 127.0.0.1:3740 のみであること

# e. policy の read-back (作成した条件が設計値と一致するか)
curl -sS "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/access/apps/$APP_ID/policies" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq -c '.result[] | {name,decision,include}' | sort
```

## 6. Rollback

```bash
# 1. Access policy / application を無効化または削除 (先に入口を閉じる)
curl -sS -X DELETE "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/access/apps/$APP_ID" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"
# 2. トンネル停止
sudo systemctl disable --now cloudflared
cloudflared tunnel delete claudeos-web-startup      # DNS レコードも消える
# 3. コンソール常駐の解除 (loopback 運用に戻す / 完全停止)
bash bin/web-startup-service.sh --unregister
bash bin/web-startup.sh --stop
```

## 7. 運用

- 監査: 操作は `~/.claudeos/logs/web-startup-audit.log`（remote は Access 経由のため
  `127.0.0.1` ではなく cloudflared の loopback になる。**実際の利用者識別は Cloudflare Access の
  ログ（`cf_access` イベント）側で行う**）。
- `session_duration: 8h`。より短くしたい場合は Access 側で調整する（設計値はテストで 8h 以下に固定）。
- 追加の許可が必要になった場合は、**email 条件を増やす**（ドメイン許可・everyone は禁止）。
  変更は必ず Approval PR。
- service token を有効化する場合は、専用 token の権限を `/api/startup/*` の読み取りに限定できない
  現状の API 設計を踏まえ、別途設計レビューを行う。

## 8. 未実施・残リスク（現時点）

| 項目 | 状態 |
|---|---|
| Cloudflare への適用（tunnel create / DNS route / Access policy） | **NOT RUN**（人間 Y/N 待ち） |
| `cloudflared` の導入 | **完了済み**（`/usr/local/bin/cloudflared`、`cert.pem` あり） |
| ingress 設定の検証 | **PASS**（`cloudflared tunnel --config … ingress validate` → OK） |
| 実 hostname での外形確認 | NOT RUN（適用後に §5 を実施） |
| アプリ側 Basic 認証 | 任意・未設定（設定する場合は人間が env-file を作成） |
| 残リスク | ①Access を迂回して loopback へ到達できるのはホスト上のユーザのみ（攻撃面はホスト権限に集約）②このコンソールは Claude 起動権限を持つため、Access アカウントの侵害＝ホストでの Claude 起動と等価。MFA は IdP 側の設定に依存する ③本ホストは既存トンネルが多数稼働しており、Access 設定を流用する際に既存アプリのポリシーを誤って広げないこと（変更は approval 対象） |

## 9. Approval PR チェックリスト

- [ ] hostname は `claude-startuptools.mirai-dx-platform.com` で一致
- [ ] Access policy は `allow: email == kensan1969@gmail.com` 1 件 + `deny: everyone`（順序 = allow → deny）
- [ ] origin は `http://127.0.0.1:3740`（LAN bind なし・`ss` で確認）
- [ ] 適用後の read-back を §5 のとおり実施し、結果を PR に貼付
- [ ] rollback 手順（§6）を適用前に確認
- [ ] secret / tunnel ID / account ID を PR・ログ・本文へ書いていない
- [ ] マージ判定: Y / N（人間）
