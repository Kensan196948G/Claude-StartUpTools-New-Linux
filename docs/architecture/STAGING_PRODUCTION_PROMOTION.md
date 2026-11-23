# Staging → 本番 昇格の設計と第 1 バッチ 10 項目計画

状態: **2026-11-23 起案**（実測に基づく）。第 1 バッチ 10 項目を並列実装中で、本書は設計と受け入れ条件の正本です。
対象: 本リポジトリの Web スタートアップコンソール（`scripts/web/startup-server.js`）とダッシュボード（`scripts/dashboards/serve-dashboard.js`）。

## 1. 目的

1. 本リポジトリ専用の **Staging**（本番と同型・状態分離・公開しない先行稼働環境）を成立させる。
2. **本番をリリース成果物（不変 artifact）から起動**する構成へ移行し、同一 artifact を Staging で検証してから昇格する経路を作る。
3. 失敗時は自動ロールバックし、昇格の判断と結果を台帳（`promotions.jsonl`）に残す。
4. 第 1 バッチ 10 項目を並列実装し、通常 PR は Required Checks PASS 後に Squash 自動マージする。

## 2. 実測した現状（2026-11-23 09:48〜09:56 JST）

| # | 事実 | 根拠 |
|---|---|---|
| 1 | 本番 4 unit はすべて active / NRestarts=0 | `systemctl --user show` |
| 2 | 3740 `/api/health` = 200 `{"ok":true,"service":"claudeos-web-startup"}` | `curl` |
| 3 | 3737 `/api/health` = 200（uptime 594689s / trust.score 0.9） | `curl` |
| 4 | 3741 `/terminal/` = 200、3 ポートとも loopback のみ listen | `ss -ltnp` |
| 5 | 公開 URL は `/`・`/api/health`・`/terminal/` とも 302 → Cloudflare Access | `curl -w '%{http_code} %{redirect_url}'` |
| 6 | 本番 unit は作業ツリー直実行。`WorkingDirectory=/home/kensan/Projects/Claude-StartUpTools-New-Linux`、commit 指定なし、`CLAUDEOS_HOME` 未設定 | `systemctl --user cat` |
| 7 | 本番起動 06:46:37 に対し HEAD は 09:41:47（起動後に 4 commit 追加・再起動なし） | `git log` + unit の `ExecMainStartTimestamp` |
| 8 | 作業ツリーは 14 件 dirty（うち `.claude/claudeos/data/*.json` は実行時データ） | `git status --short` |
| 9 | `~/.claudeos/releases/` は無い。release / staging 用ディレクトリも無い | `ls` |
| 10 | claude* の staging unit は存在しない。3742/3743/3744 は FREE | `systemctl --user list-units` / `ss -ltn` |
| 11 | `serve-dashboard.js` は `~/.claudeos` を 6 箇所ハードコード（`CLAUDEOS_HOME` 非対応） | コード読み（L23,L24,L83,L1244,L1566,L1586 付近） |
| 12 | `bin/web-startup-service.sh` は unit 名固定（`claudeos-web-startup.service`） | コード読み |
| 13 | `startup-server.js` は `--port`/`--host`/`--root`/`--pid-file`/`--allow-no-auth` と `CLAUDEOS_HOME` で状態分離できる | `--help` + コード読み |
| 14 | CI は `linux-validate` と `e2e-console` の 2 ジョブ。staging/deploy 用ジョブは無い | `.github/workflows/ci.yml` |
| 15 | ruleset `central-auto-merge` が active。必須チェックは `Secrets scan (gitleaks)` と `linux-validate`、`strict=true`、squash のみ | `gh api .../rulesets` |
| 16 | baseline は緑: bats 1070 ok / node 459 pass 0 fail / shellcheck 0（`2cf0639` の隔離 worktree、09:48〜09:56） | `npm test` / `npm run lint` |

**結論**: Staging は「無い」。本番は作業ツリー直実行のため artifact 同一性が担保できず、起動後にコードが進んでも実態が変わらない（#6〜#8）。まず成果物化と状態分離を作り、そのうえで昇格経路を作る。

## 3. 定義

| 用語 | 定義 |
|---|---|
| Release artifact | `$CLAUDEOS_HOME/releases/<40桁commit>/`。`git archive` で取得した tracked files のみ + `manifest.json`（per-file sha256 と `tree_sha256`） |
| Staging | `claudeos-web-startup-stg.service`（127.0.0.1:3742）。`CLAUDEOS_HOME=~/.claudeos-stg`、`--root` は release dir。公開 hostname を持たない |
| Production | `claudeos-web-startup.service`（127.0.0.1:3740）+ dashboard 3737 + ttyd 3741。Cloudflare Tunnel + Access で公開 |
| 昇格 | 「Staging で同一 `tree_sha256` を検証済みの artifact」を Production の起動対象へ切り替える操作 |

## 4. 構成（目標）

| 役割 | unit | port | root（起動対象） | 状態 |
|---|---|---|---|---|
| Production コンソール | `claudeos-web-startup.service` | 3740 | `~/.claudeos/releases/production-current` → `<sha>/` | `~/.claudeos` |
| Staging コンソール | `claudeos-web-startup-stg.service` | 3742 | `~/.claudeos-stg/releases/staging-current` → `<sha>/` | `~/.claudeos-stg` |
| Production dashboard | `claude-startuptools-dashboard.service` | 3737 | 現状どおり | `~/.claudeos` |
| Staging dashboard（任意） | `claude-startuptools-dashboard-stg.service` | 3743 | 現状どおり | `~/.claudeos-stg` |

- 本番と Staging は **同じ sha の artifact** を起動対象にする（コードの同一性を sha で担保）。
- Staging の env-file は `~/.config/claudeos-web-startup-stg.env`（0600）。**本番の env-file を流用しない**。
- Cloudflare Tunnel の ingress は変更しない（Staging は公開しない）。公開が必要になった時点で別途人間ゲート。

## 5. 昇格フロー

```
1. build   : bin/release-build.sh --ref <sha>
             → ~/.claudeos/releases/<sha>/ + manifest.json
2. stage   : bin/release-promote.sh --env staging --release <sha>
             → staging-current を張り替え → stg unit restart → :3742/api/health 確認
3. verify  : scripts/e2e/staging-smoke.sh（成果物から起動し health / 主要 API / 状態分離を検査）
             ＋ 目視（Staging 画面）。ここで tree_sha256 と検証記録が残る
4. approve : Production 昇格は人間の Y/N（GITHUB_POLICY §10。本番配備は Human Gate）
5. promote : bin/release-promote.sh --env production --release <sha>
             → staging-current の tree_sha256 と一致することを要求
             → production-current を張り替え → 本番 unit restart → :3740/api/health 確認
6. verify  : 公開 URL 302 / terminal 200 / dashboard health / 監査ログ / promotions.jsonl を確認
7. rollback: bin/release-promote.sh --rollback --env production
             （自動ロールバックは health 失敗時に promote 内で実施）
```

不変条件:

- **Staging 未検証の artifact を Production に昇格できない**（同一 `tree_sha256` を要求。`--force` は用意しない）。
- manifest と実ファイルの sha256 が一致しない artifact は切替できない（`INTEGRITY_MISMATCH`）。
- 切替は symlink の原子的張り替え + unit restart。失敗時は旧 target へ戻して restart し `ROLLED_BACK` を記録する。
- すべての昇格は `~/.claudeos/releases/promotions.jsonl` に追記される（時刻・env・commit・tree_sha256・結果・unit・port）。

## 6. 第 1 バッチ 10 項目

| # | 項目 | 種別 | 担当 | 依存 | 受け入れ条件 |
|---|---|---|---|---|---|
| 1 | `bin/release-build.sh`（artifact + manifest） | 実装 | dev-release | — | bats 6+ / shellcheck 0 / manifest の sha256 が実ファイルと一致 / `--json` |
| 2 | `bin/web-startup-service.sh` の unit/env-file/root/home 引数化 + `--profile staging` | 実装 | dev-service | — | 既定挙動の回帰 / stg が本番 unit を書かない / bats 11+ |
| 3 | `scripts/dashboards/serve-dashboard.js` の `CLAUDEOS_HOME` 対応 | 実装 | dev-dashboard | — | 未設定時は従来パス / 設定時は全 6 箇所が配下 / node テスト |
| 4 | `bin/release-promote.sh`（昇格 + 自動ロールバック） | 実装 | dev-promote | #1 の契約 | bats 8+ / 整合性不一致で切替なし / staging 未検証の production 拒否 |
| 5 | `scripts/e2e/staging-smoke.sh` + CI `staging-smoke` ジョブ | 実装 | dev-smoke | #1 | 成果物から起動して health/API/状態分離を検査 / CI 追加が既存ジョブを壊さない |
| 6 | Staging 環境の実起動（3742 / `~/.claudeos-stg` / stg unit） | 運用 | lead | #1,#2,#3 | 4 点: stg health 200 / 本番 3740 不変 / 状態が `~/.claudeos-stg` のみ / 監査ログ分離 |
| 7 | 本番の artifact 化（Production unit を release dir 実行へ） | 運用 | lead | #1,#4,#6 | 同一 sha 起動 / `:3740/api/health` 200 / promotions.jsonl 記録 / rollback 手順実測 |
| 8 | 他リポジトリ連携の是正（中央 ruleset 未適用・参照ドリフト・CI 赤） | 是正 | lead + integration-auditor | 監査報告 | 是正対象の一覧と、適用済み／人の承認待ちの切り分け |
| 9 | registry/CMDB 整合（`config/linux-projects.json` と実在の照合 + 検証テスト） | 実装 | lead | #8 | 存在しない参照 0 件 / 検証がテストで回帰 |
| 10 | 文書・索引（本書 / README / `SOURCE_OF_TRUTH.md` / CHANGELOG） | 文書 | lead | #1–#7 | 索引から到達可能 / リンク切れ 0 / 状態と実装が一致 |

マージ順の目安: #1 → #2/#3 → #4 → #5 → （#6 実起動）→ #7 → #8/#9 → #10。
`strict=true` のため、各 PR はマージ前に `gh pr update-branch` で追従させる。

## 7. 本番構築の受け入れ条件（チェックリスト）

| # | 条件 | 検証コマンド（例） |
|---|---|---|
| 1 | Staging が同一 artifact で稼働 | `curl -s http://127.0.0.1:3742/api/health` / `systemctl --user show claudeos-web-startup-stg.service -p ExecStart,MainPID` |
| 2 | Staging の状態が本番と分離 | `ls ~/.claudeos-stg/logs` に当日の監査ログ / 本番 `~/.claudeos/logs` に stg 由来の追記が無い |
| 3 | 本番が release dir から起動 | `systemctl --user show claudeos-web-startup.service -p ExecStart` が `releases/production-current/...` |
| 4 | 本番の応答が正常 | `curl -s http://127.0.0.1:3740/api/health` = `ok:true` |
| 5 | 公開面が正常 | `curl -s -o /dev/null -w '%{http_code}' https://claude-startuptools.mirai-dx-platform.com/` = 302（Access） |
| 6 | terminal / dashboard が正常 | `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3741/terminal/` = 200 / `:3737/api/health` = 200 |
| 7 | 昇格が記録されている | `tail -1 ~/.claudeos/releases/promotions.jsonl` に commit / tree_sha256 / result |
| 8 | ロールバックが可能 | `bin/release-promote.sh --rollback --env production --dry-run` が旧 target を表示 |
| 9 | unit が安定 | 各 unit `NRestarts=0`（昇格直後 60 秒観察） |
| 10 | エラーログが無い | `journalctl --user -u claudeos-web-startup.service --since "10 min ago"` に error 0 |

## 8. ロールバック

| 層 | 操作 |
|---|---|
| アプリ（artifact） | `bin/release-promote.sh --rollback --env production`（symlink を previous へ戻し restart） |
| unit 定義 | 変更前の unit ファイルを `~/.config/systemd/user/*.service.bak-<ts>` から戻して `daemon-reload` + restart |
| 環境変数 | production で有効化した機能フラグを外して restart（`STARTUP_WEB_*`） |
| 即時退避 | `systemctl --user stop claudeos-web-startup.service`（公開面は Tunnel 側で 502 になる。最終手段） |

## 9. リスク・未確認

- Cloudflare Access の背後（302 の先）の画面は、認証情報なしでは確認できない。**人間の目視が必要**。
- 稼働中 3740 の実コードが `2cf0639` と一致するかは、再起動なしには照合できない（未確認）。
- `~/.config/claudeos-web-startup.env` の中身は secret を含むため確認していない（名前のみ）。
- Staging dashboard（3743）は #3 の修正後に成立する。ttyd の Staging（3744）は今回のスコープ外。
- Tunnel ingress は変更しない。Staging を公開する場合は別途 Access application と hostname の追加（人間ゲート）が必要。

## 10. 人間ゲート

- **Production 昇格（#7）の実行前**: Y/N。対象 sha・tree_sha256・変更点・ロールバック手順を提示する。
- Release 作成・secret 変更・Tunnel/DNS/Access 変更・不可逆削除: 従来どおり人間ゲート（GITHUB_POLICY §10）。
- コードのマージは Required Checks PASS 後に自動（本設計の範囲内）。
