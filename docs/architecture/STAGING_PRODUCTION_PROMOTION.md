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

## 11. 実装状況（2026-11-23 10:40 JST 実測）

| # | 項目 | 状態 | 根拠（PR / 実測） |
|---|---|---|---|
| 1 | `bin/release-build.sh`（artifact + manifest） | **完了** | PR #175。1046 files・`tree_sha256` 独立再計算一致・argv 上限バグ修正済み（2000+ files 回帰テスト） |
| 2 | `bin/web-startup-service.sh` 引数化 + staging プロファイル | **完了** | PR #176。既定 unit 出力は変更前とバイト一致（回帰）・staging は本番 unit を拒否 |
| 3 | dashboard の `CLAUDEOS_HOME` 対応 | **完了** | PR #171。未設定時は従来パス（回帰）・設定時は 6 箇所すべて配下 |
| 4 | `bin/release-promote.sh`（昇格 + 自動ロールバック） | **完了** | PR #177。整合性不一致で切替なし・staging 未検証の production 拒否・health 失敗で ROLLED_BACK（実測） |
| 5 | `scripts/e2e/staging-smoke.sh` + CI ジョブ | **スクリプト完了 / CI ジョブ未適用** | PR #173（11 checks PASS 実測）。`.github/workflows/ci.yml` は policy gate（DEPLOY=critical）により人間の適用待ち |
| 6 | Staging 環境の実起動 | **完了** | 3742 稼働・`~/.claudeos-stg` 分離・本番 3740 不変・promotions.jsonl に PROMOTED/ROLLED_BACK |
| 7 | 本番の artifact 化 | **人間の Y/N 待ち** | 手順は `STAGING_PRODUCTION_RUNBOOK.md` §4 |
| 8 | 他リポジトリ連携の是正 | **一部完了** | 台帳是正は PR #174。中央 ruleset/CI の横断是正は第 2 バッチ（下記 §12） |
| 9 | registry/CMDB 整合 | **完了** | PR #174。linux 9/9・github 7 件（13 件を `_stale` へ退避）・チェッカ CLI と 10 tests |
| 10 | 文書・索引 | **完了** | 本書 + `STAGING_PRODUCTION_RUNBOOK.md` + `SOURCE_OF_TRUTH.md` 更新 |

## 12. 第 2 バッチ（次 10 項目・監査報告に基づく）

監査（release-auditor / integration-auditor）で確定した欠落を、次の 10 項目として扱う。

| # | 項目 | 根拠 | 種別 |
|---|---|---|---|
| 1 | `/api/health` に `commit` / `version` を返す（artifact 同一性の可観測化） | 実測: health に commit が無く、配備後にどのコードが動いているか確認できない | 実装 |
| 2 | 配備後スモーク `scripts/release/post-deploy-smoke.sh` | 配備後検証の経路が CI にも手順にも無い | 実装 |
| 3 | CI に `release-check` と `staging-smoke` を追加 | `.github/workflows` は人間ゲート。追加で「マージ前に成果物起動を検証」できる | Approval |
| 4 | `deploy-prep.sh` と runbook 生成のフラグ整合（D1/D2）+ placeholder 除去 | `runbook_generated=true` を書くだけで生成しない、生成側はフラグを書かない | 実装 |
| 5 | `state.deploy` の未書き込みフィールドを実装 or schema から削除 | `executed_at` / `executed_by` / `post_deploy_verified` は書き込みコード 0 件 | 実装 |
| 6 | リリース識別子の復活（tag が 174 commits 遅れ） | 最終 tag `v4.0.0-linux` は 2026-06-07 | 運用 |
| 7 | `run-audit-scan.js` を rulesets API へ切替 | legacy `/branches/main/protection` は ruleset 運用 repo で 404 → 常に「未保護」誤判定 | 実装 |
| 8 | 中央ポリシーの版統一と所在の明確化 | v1/v2/v3 混在・`bin/policy-pr.sh` 等は中央リポジトリ所在で本リポジトリには無い | 文書 + 人間判断 |
| 9 | auto-merge 実行器の定常運用（`github-controller.sh` の timer 化） | armed 0/9・CLEAN+green 4 件が 34〜98 日滞留・BEHIND 48 件 | 人間判断（横断） |
| 10 | テスト副作用の除去（`npm run test:node` が `.claude/claudeos/data/reasoning-bank.json` を書き換える） | 共有ツリーに意図しない差分が出る | 実装 |

## 13. 横断連携の実測結論（integration-auditor, 2026-11-23）

| 指標 | 実測 |
|---|---|
| Kensan196948G 配下 repo | 76 |
| `central-auto-merge` 保有 | 50（66%） |
| ruleset なし | 21（28%）・別名 5 |
| open PR | **213**（2026-11-23 11:5x 時点・増加中） |
| auto-merge armed | 0/9 サンプル（**実行器が定常稼働していない**） |
| CLEAN + green なのに未マージ | **33 件**（全 76 repo を `bin/repo-integration-status.sh` で実測。当初の「4 件」は上位 5 repo のサンプル値だった） |
| required check 名と CI 実報告名 | 4/4 一致（ゲート自体は機能） |

結論: **ゲート（fail-closed）は機能しているが、マージ自動化の実行体が回っておらず、滞留は当初の想定より大きい**。本リポジトリの PR は今回 `gh pr merge` を Lead が明示実行して自動マージを成立させた（armed 0 の実態を回避）。

## 14. 第2バッチ完了状況（2026-11-23 11:50 JST 実測）

| # | 項目 | 状態 / 根拠 |
|---|---|---|
| 1 | `/api/health` に `commit` / `version` | **完了** #182。Staging が `commit=45032a8e…` / `version=4.0.0-linux` を返すことを実測 |
| 2 | 配備後スモーク | **完了** #184（20 tests・読み取り専用を呼び出しログで検証） |
| 3 | CI へ release-check / staging-smoke 組込 | **未適用（人間ゲート）** |
| 4-5 | deploy フラグ整合 + runbook 実行可能化 | **完了** #183（書き手の無い 3 フィールドを schema から削除） |
| 6 | Release / tag | **未実施（人間ゲート）** |
| 7 | audit-scan の rulesets 対応 | **完了** #181（`protected=true` / `source=ruleset` / required 2 件） |
| 8 | 中央ポリシーの版統一 | **未実施（人間ゲート）** |
| 9 | auto-merge 実行器の定常化 | **未実施（人間ゲート・横断）** |
| 10 | テスト副作用の除去 | **完了** #180（原因を実測特定、`CLAUDEOS_DATA_DIR` で隔離） |

## 15. 第3バッチ（2026-11-23 11:50 時点）

| # | 項目 | 状態 | 備考 |
|---|---|---|---|
| 1 | flaky 修正（start-claude 端末タブ） | 実装中 | 本日 2 回 CI を落とした既存 flake |
| 2 | `test:dry-run` の既存バグ修正 | 完了 | 再帰の `m.filter` 取り違え + `mapping.filter` 未配線（44 体配布→9 体へ）で **1/33 → 33/33 PASS** |
| 3 | UI に build（commit/version）表示 | 完了 | `build: 45032a8 / v4.0.0-linux` を実ブラウザで確認、ポーリングなし |
| 4 | deploy-status CLI | 実装中 | 現行成果物・previous・health・台帳を 1 コマンドで |
| 5 | 監査ログのローテーション | **完了** #186 | 5 MiB × 3 世代（本体含め最大 20 MiB）、fail-open |
| 6 | repo-integration-status CLI | 実装中 | 横断の ruleset / open PR / CLEAN+green を 1 コマンドで |
| 7 | Staging dashboard（3743） | **完了** #185 + 実起動 | `claude-startuptools-dashboard-stg.service` が 127.0.0.1:3743 で稼働、`CLAUDEOS_HOME=~/.claudeos-stg` |
| 8 | Staging ttyd（3744） | **不採用** | ttyd は端末ゲートウェイで環境非依存。Staging に複製する意味がない（本番 3741 のみ） |
| 9 | 文書・索引の更新 | 本 PR | 本書 + Runbook + SOURCE_OF_TRUTH |
| 10 | 本番昇格の事前検証 | **完了（実測）** | unit バックアップ sha256 `7883f90c…`、promote/rollback の dry-run、計画 unit の dry-run を実測 |

## 16. 本番昇格の事前検証結果（Y/N 待ちの状態）

`release-promote --env production --release 45032a8e… --dry-run` の実測:

| 項目 | 値 |
|---|---|
| release dir | `~/.claudeos/releases/45032a8ef1ad7570a860e3f09cbad7dd52a9dafc` |
| tree_sha256 | `e08b77cb400e085856f7fe544a4a91b9dc0fdb421ce04a44df59f8e65aa4ce3c` |
| staging 検証 | **一致**（staging-current が同一 tree_sha256）→ `STAGING_NOT_VERIFIED` を通過 |
| 現在の production-current | なし（初回） |
| ロールバック | 初回のため `previous` なし。**unit バックアップ `claudeos-web-startup.service.bak-<ts>` が必須** |
| 現在の本番 unit sha256 | `7883f90cfc3a882751a2616c3beb0ed1b44dbb161085d4f9180211ce01f82f00`（戻し先の同一性確認用） |
| 計画 unit の dry-run | `WorkingDirectory=~/.claudeos/releases/production-current` / `Environment=AI_STARTUP_CONFIG_PATH=…` / `ExecStart=node …/production-current/scripts/web/startup-server.js --port 3740 --host 127.0.0.1` |

## 17. 第4バッチ（2026-11-23 13:10 時点）

| # | 項目 | 状態 |
|---|---|---|
| 1 | 滞留 PR の分類（`--classify`） | 完了 #196。**33 件 = deps 22 / docs 3 / fix 4 / unknown 4**、経過 <7日 14 / 7-30日 4 / 30-90日 11 / >90日 4 |
| 2 | ruleset 適用可否（CI 有無） | 完了 #196。ruleset なし 21 = **CI あり 16 / CI なし 5** |
| 3 | 中央ポリシー v2→v3 差分 | 完了 #194。**v3 は v2 の上位互換**。除外は `mirai-construction-dx/Mirai-Platform-Infra` 限定で本リポジトリは対象外 |
| 4 | Staging 定期検証タイマー | 完了 #193（登録は lead が実行） |
| 5 | 監査ログ閲覧 CLI | 完了 #197 |
| 6 | promotions 台帳のローテーション | 完了 #198（1 MiB × 3 世代・fail-open） |
| 7 | artifact 独立検証 CLI | 完了 #199（実 artifact 4 世代すべて OK） |
| 8 | 本番昇格のリハーサル | **完了（実測）** Staging で rollback → 再 promote を実施し、health の commit が追従することを確認 |
| 9 | 文書・索引 | 本 PR |
| 10 | 昇格前ゲート CLI | 完了 #195（実環境で 7/7 PASS） |

## 18. 横断是正の判断材料（#196 実測）

- 滞留 33 件の内訳: **deps 22（メジャー 8 / マイナー・パッチ 14）/ docs 3 / fix 4 / unknown 4**。機能追加は 0 件。一方で**実バグ修正 `fix` が 4 件**（最長 55 日）滞留しており、一括クローズは危険。
- ruleset なし 21 repo のうち **CI なしは 5 件**（Cybersecurity-Sovereign-AgentOS / Construction-Public-Twin-Portal / Server-Disk-Management / BLB-Safe-Renamer / Codex-StartUpTools）。**CI が無い repo に ruleset を先に当てると全 PR が永久マージ不可**になる。
- 推奨順序: ①CI 整備（5 repo、または対象外の明示）→ ②ruleset 適用（CI あり 16 repo）→ ③滞留 PR 処理（`fix` 4 件とメジャー 8 件を除外してから）→ ④controller 定常化。
- 未検証: 16 repo の required check 名と実報告名の一致（適用前に 1 PR で突合が必要）。

## 19. ポリシーの位置づけ（#194 実測）

- 中央 `GITHUB_POLICY.md` は **v3**。本リポジトリのコピーは分析時点で **v2（stale mirror）** だったが、**#218 で v3 に追随済み**（差分はミラー行と R1 の参照修飾のみ）。差分は 3 箇所のみで v3 は上位互換。§10 の除外は特定リポジトリ限定で本リポジトリは対象外 → **現運用は v3 でも許容**。
- 本リポジトリが参照する `bin/policy-pr.sh` / `bin/github-controller.sh` / `docs/architecture/全リポジトリAutoMerge統一方針.md` は**中央リポジトリに存在**し、v3 でもリポジトリ名で修飾されていない。
- 推奨: 案 A（v3 へ追随し、参照をリポジトリ名で修飾）。決定は人間。

## 20. 第5バッチ: 本番 2 面（コンソール + dashboard）昇格と独立レビュー対応（2026-11-23 15:30）

| # | 項目 | PR |
|---|---|---|
| 1 | dashboard `/api/health` に `commit` / `version` | #207 |
| 2 | promote-production に本番 dashboard(3737) 切替 (3d)（既存 unit は不改変・systemd drop-in 方式） | #212 |
| 3 | pre-promote-check に検査 8（本番 dashboard）・退避 unit の sha256 照合 / post-deploy-smoke に dashboard と `--expect-commit` | #213 |
| 4 | release-promote: staging 昇格時に companion（dashboard-stg）も restart・health 確認 | #210 |
| 5 | deploy-status: dashboard とコンソール本体の `serving_from`（release / worktree） | #209 / #215 |
| 6 | 横断 段階①: CI なし repo の最小 CI 案・needs_manual 3 件の再分類 | #208 |
| 7 | web-startup-service `--state-file`（CCSU_STATE_FILE） | #211 |
| 8 | promote-production が (3) で `--state-file` を渡す（H3 解消） | #214 |
| 9 | 本番昇格経路の独立レビュー（実装者以外） | task-36 |
| 10 | 文書 | 本 PR |

### 20-1. 独立レビューの指摘と対応

| ID | 指摘 | 対応 |
|---|---|---|
| H1 | 初回昇格の自動復旧で `production-current` が新成果物を指したまま残る | previous 不在時は symlink を削除し台帳に `NO_PREVIOUS_REMOVED`（#212） |
| H2 | 中断（INT/TERM/HUP）時に復旧が走らない | (1)〜(5) 間は trap で自動復旧（#212） |
| H3 | 成果物起動後に state.json が成果物内へ書かれる | unit に `CCSU_STATE_FILE=<repo>/state.json`（#211 + #214） |
| M1 | `enable --now` は稼働中 unit を再起動しない（Runbook 記述と乖離） | Runbook 訂正: 稼働切替は (4)（#211 / #214） |
| M2 | 二重実行の排他なし | `flock`（exit 2）（#212） |
| M3 | 退避 unit は存在確認のみ | 最新 `.bak-*` と現行 unit の sha256 照合（#213） |
| M4 | 配備後スモークが期待 commit を検証しない | `--expect-commit`（#213） |
| M5 | dashboard の HOST が unit 側 Environment に依存 | drop-in に `Environment=HOST=127.0.0.1` を明示（#212） |
| M6 | Runbook に drop-in の扱いが無い | Runbook §4-A に (3d) を追加（#214） |
| L1/L3 | 台帳に dashboard 復旧結果が無い / node パスの焼き込み | 台帳に記録・現行 unit の node を抽出（#212） |
| L2 | dry-run はゲートを実行しない | 仕様（dry-run は計画表示）。実行時は (0) で必ずゲート |
| L4 | 実機設定を repo から読む（非自己完結） | 既知の制約（`CCSU_PROMOTE_CONFIG_PATH` を明示、(0b) で存在確認） |

本番 unit と生成 unit の差分は 4 点のみ（Documentation / WorkingDirectory / ExecStart / `AI_STARTUP_CONFIG_PATH` 追加）に `CCSU_STATE_FILE` が加わる。
**secret 入りの `EnvironmentFile=-~/.config/claudeos-web-startup.env` は同一行として維持**、port / bind 不変のため Cloudflare Tunnel への影響はない。

### 20-2. 本番昇格の直前状態（実測 2026-11-23 15:30、release `d2e36beb`）

| 確認 | 結果 |
|---|---|
| 成果物 | 1087 files / tree `4892fa1b…` / verify-artifact OK（missing 0・mismatched 0） |
| Staging | コンソール 3742・dashboard 3743 とも commit `d2e36beb`（companion 自動 restart） |
| post-deploy-smoke staging `--expect-commit` | 6 checks / 0 failed / 0 warnings |
| 日次スモーク（成果物から実行） | success |
| pre-promote-check | **8/8 PASS**（退避 unit sha256 一致・本番 dashboard 健全を含む） |
| promote-production dry-run | (0)〜(5) と (3d) を表示、`--state-file <repo>/state.json` 付き、書き込みなし |
| `--yes` 無し | exit 3（確認待ち） |
| 本番 | 3740 / 3737 とも 200、unit sha256 `7883f90c…` 不変、`production-current` 未作成、dashboard drop-in 未作成 |
| deploy-status | Staging = release / release、本番 = worktree / worktree |

