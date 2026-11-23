# Staging / Production 昇格 Runbook（実測 2026-11-23）

対象: 本リポジトリの Web スタートアップコンソール（`scripts/web/startup-server.js`）。
設計の正本は `docs/architecture/STAGING_PRODUCTION_PROMOTION.md`。本書は**実際に実行した手順と実測値**を残す。

## 0. 前提（環境）

| 役割 | unit | port | root（起動対象） | 状態 |
|---|---|---|---|---|
| Staging コンソール | `claudeos-web-startup-stg.service` | 127.0.0.1:3742 | `~/.claudeos/releases/staging-current` → `<sha>/` | `~/.claudeos-stg` |
| Production コンソール | `claudeos-web-startup.service` | 127.0.0.1:3740 | （2026-11-23 時点: 作業ツリー直実行。§4 で artifact 化） | `~/.claudeos` |
| Production dashboard | `claude-startuptools-dashboard.service` | 127.0.0.1:3737 | 作業ツリー | `~/.claudeos` |
| Staging dashboard | `claude-startuptools-dashboard-stg.service` | 127.0.0.1:3743 | `~/.claudeos/releases/staging-current` | `~/.claudeos-stg` |
| Production terminal | `claude-startuptools-ttyd.service` | 127.0.0.1:3741 | — | — |

- 成果物（artifact）は `~/.claudeos/releases/<40桁commit>/`。`manifest.json` に per-file `sha256` と `tree_sha256` を持つ。
- Staging は**公開しない**（Cloudflare Tunnel の ingress に hostname を追加していない）。
- Staging dashboard は `bin/dashboard-service.sh --register --profile staging --root ~/.claudeos/releases/staging-current` で登録する（`HOST=127.0.0.1` / `CLAUDEOS_HOME=~/.claudeos-stg` を unit が持つ）。
- ttyd（端末ゲートウェイ）は環境非依存のため Staging には置かない（本番 3741 のみ）。
- 実機設定 `config/config.json` は git 管理外のため、成果物には含まれない。Staging は専用 env-file の `AI_STARTUP_CONFIG_PATH` で、本番と同じ実機設定を**読み取り専用**で参照する。

## 1. 成果物を作る

```bash
# 任意の worktree（origin/main を checkout したもの）で実行
git -C <worktree> checkout --detach origin/main
CLAUDEOS_HOME=$HOME/.claudeos bash <worktree>/bin/release-build.sh --ref origin/main --json
```

実測（2026-11-23 10:35 JST）:

```
{"ok":true,"commit":"1a96ace2f7a961c2076542716f87b35143c4ad69",
 "dir":"/home/kensan/.claudeos/releases/1a96ace2f7a961c2076542716f87b35143c4ad69",
 "tree_sha256":"68c1f61a1841d170a5e29314026398087ed028d1047d3032690219ee37fb7092",
 "file_count":1046}
```

## 2. Staging を起動する（初回）

初回は symlink が無いため、unit 登録 → 昇格の順に実行する（登録直後は unit が auto-restart になるが、直後の昇格で復帰する）。

```bash
# 2-1. unit を登録（bind は 127.0.0.1:3742 固定、CLAUDEOS_HOME=~/.claudeos-stg）
bash <worktree>/bin/web-startup-service.sh --register --profile staging \
  --root "$HOME/.claudeos/releases/staging-current"

# 2-2. symlink を張り替えて restart + health 確認
CLAUDEOS_HOME=$HOME/.claudeos bash <worktree>/bin/release-promote.sh \
  --env staging --release 1a96ace2f7a961c2076542716f87b35143c4ad69
```

実測（2026-11-23 10:35 JST）:

| 項目 | 結果 |
|---|---|
| unit | `ActiveState=active` / `SubState=running` / `MainPID=2502750` / `NRestarts=3`（symlink 作成前の auto-restart 回数） |
| ExecStart | `node /home/kensan/.claudeos/releases/staging-current/scripts/web/startup-server.js --port 3742 --host 127.0.0.1` |
| WorkingDirectory | `/home/kensan/.claudeos/releases/staging-current` |
| Environment | `CLAUDEOS_HOME=/home/kensan/.claudeos-stg` |
| EnvironmentFiles | `/home/kensan/.config/claudeos-web-startup-stg.env`（ignore_errors=yes） |
| `/api/health` | `{"ok":true,"service":"claudeos-web-startup","dryRunOnly":false}` |
| `/api/startup/state` | 200 / 31186 bytes |
| `/` | 200 |
| listen | `127.0.0.1:3742` のみ（loopback） |
| 本番 3740 | health 不変・MainPID 3582989 不変 |
| 状態分離 | `~/.claudeos-stg/logs/web-startup-audit.log` が生成。本番 `~/.claudeos/logs/web-startup-audit.log` は 17942 bytes のまま不変 |
| Staging dashboard | `claude-startuptools-dashboard-stg.service` active / `127.0.0.1:3743` / `Environment=HOST=127.0.0.1 CLAUDEOS_HOME=~/.claudeos-stg` / ExecStart は `staging-current/scripts/dashboards/serve-dashboard.js`。本番 3737 は 200 のまま不変 |
| 状態分離の実測（dashboard） | `/api/mc-data` が 本番 `agentTeams=6` / `eventLog=15`、Staging `agentTeams=0` / `eventLog=0`（Staging は `~/.claudeos-stg` が空のため） |
| 昇格台帳 | `~/.claudeos/releases/promotions.jsonl` に `ROLLED_BACK`（health 失敗時の自動切戻し実測）と `PROMOTED` の 2 行 |

> 補足: 初回の `--no-restart` 実行は health 確認に失敗し、symlink を削除して `ROLLED_BACK` を記録した。**ロールバック経路が実環境で動作した実測例**である（意図した安全側の挙動）。

## 3. Staging の健康確認（毎回）

```bash
curl -s http://127.0.0.1:3742/api/health                     # ok:true
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3742/
systemctl --user show claudeos-web-startup-stg.service -p ActiveState,MainPID,NRestarts
tail -1 ~/.claudeos/releases/promotions.jsonl                # 直近の昇格/切戻し
bash <worktree>/scripts/e2e/staging-smoke.sh --json          # 成果物起動スモーク（11 checks）
```

`scripts/e2e/staging-smoke.sh` の実測（2026-11-23 10:23 JST・origin/main 1a96ace 以前の成果物）:

```
{"ok":true,"port":43213,"checks":11,"failed":0}
  [PASS] /api/health の service=claudeos-web-startup
  [PASS] GET / = 200 (成果物の静的 UI を配信)
  [PASS] 保護 API は認証設定どおりに応答 (code=200)
  [PASS] 不正な変更系リクエストを拒否 (code=415)
  [PASS] 監査ログが分離 CLAUDEOS_HOME 配下に作られる
  [PASS] 本番 3740 の health は起動前後で不変
```

## 4. Production を artifact 化する（人間の Y/N 後）

**現状の課題**: 本番 unit は作業ツリー直実行で commit pin が無い。起動後にコードが進んでも実態が変わらない（2026-11-23 実測: 起動 06:46:37 に対し HEAD 09:41:47、4 commit 先行）。

実行順序（記録と実体を一致させるため、この順で行う）:

```bash
# 4-1. 本番 unit のバックアップ（必ず戻せる状態にする）
cp ~/.config/systemd/user/claudeos-web-startup.service \
   ~/.config/systemd/user/claudeos-web-startup.service.bak-$(date +%Y%m%d-%H%M%S)

# 4-2. production-current の symlink を用意する（restart しない。本番は今も作業ツリーで稼働中なので health は通る）
CLAUDEOS_HOME=$HOME/.claudeos bash <worktree>/bin/release-promote.sh \
  --env production --release <sha> --no-restart

# 4-3. 本番 unit を成果物起動へ差し替える（既定挙動は不変。--root と --env だけ追加）
bash <worktree>/bin/web-startup-service.sh --register --profile production \
  --root "$HOME/.claudeos/releases/production-current" \
  --env AI_STARTUP_CONFIG_PATH=/home/kensan/Projects/Claude-StartUpTools-New-Linux/config/config.json

# 4-4. 同じ sha で昇格を確定する（restart + health 確認 + promotions.jsonl に PROMOTED を記録）
CLAUDEOS_HOME=$HOME/.claudeos bash <worktree>/bin/release-promote.sh \
  --env production --release <sha>

# 4-5. 配備後確認（すべて PASS してから完了とする）
curl -s http://127.0.0.1:3740/api/health
curl -s -o /dev/null -w '%{http_code}\n' https://claude-startuptools.mirai-dx-platform.com/   # 302 (Access)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3741/terminal/                    # 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3737/api/health                   # 200
systemctl --user show claudeos-web-startup.service -p ActiveState,NRestarts,ExecStart
tail -1 ~/.claudeos/releases/promotions.jsonl
journalctl --user -u claudeos-web-startup.service --since "10 min ago" | grep -ci error      # 0
```

設計上の注意:

- `release-promote --env production` は **staging-current と同一 `tree_sha256`** を要求する（未検証は `STAGING_NOT_VERIFIED` で拒否、`--force` は無い）。
- `--no-restart` でも health 確認は行われ、失敗すれば切戻す。4-2 は「本番が今も作業ツリーで応答している」ため通る。
- 4-3 の登録で unit が restart され、**この時点から実体が成果物起動になる**。4-4 が最終的な検証記録になる。
- 失敗時の戻しは §5。unit のバックアップがあるため、成果物側の問題と unit 側の問題を切り分けられる。

### 4-6. 配備後確認の記録（実測欄）

| 項目 | 実測値 | 判定 |
|---|---|---|
| 本番 `/api/health` | （未実施） | — |
| 公開 URL | （未実施） | — |
| terminal / dashboard | （未実施） | — |
| unit `NRestarts`（昇格後 60 秒） | （未実施） | — |
| `promotions.jsonl` 最終行 | （未実施） | — |

> 2026-11-23 時点では **Production 昇格は人間の Y/N 待ち**のため未実施。実施後にこの表を埋める。

## 5. ロールバック

| 層 | 操作 |
|---|---|
| 成果物 | `CLAUDEOS_HOME=$HOME/.claudeos bash <worktree>/bin/release-promote.sh --env production --rollback` |
| unit 定義 | `cp` した `claudeos-web-startup.service.bak-<ts>` を戻し `systemctl --user daemon-reload && systemctl --user restart claudeos-web-startup.service` |
| 環境変数 | 追加した `--env` を外して unit を再登録（`--root` を外せば従来の作業ツリー起動に戻る） |
| 即時停止 | `systemctl --user stop claudeos-web-startup.service`（公開面は Tunnel 側で 502。最終手段） |

## 6. 既知の制約・未確認

- Cloudflare Access の背後（302 の先）の画面は認証情報なしでは確認できない。**人間の目視が必要**。
- Staging 用の公開 hostname / Access application は未作成（Tunnel ingress は 1 hostname のみ）。
- Staging dashboard（3743）は構築済み。Staging ttyd（3744）は意図的に未構築（端末ゲートウェイは環境非依存）。
- `scripts/e2e/staging-smoke.sh` の CI ジョブは未追加（`.github/workflows/ci.yml` の変更はセッションの self-evolution policy gate が `DEPLOY=critical` として拒否するため、人間の適用が必要）。
- `release-promote` の `--no-restart` は health 確認も行う（失敗すれば切戻す）。初回 bootstrap ではこの挙動を理解して使うこと。
