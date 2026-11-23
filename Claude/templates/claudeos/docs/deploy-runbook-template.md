# デプロイ手順書 — {DATE}

**プロジェクト**: {PROJECT}
**対象環境**: {ENVIRONMENT}
**対象 commit**: `{GIT_COMMIT}`（short `{GIT_COMMIT_SHORT}` / branch `{GIT_BRANCH}` / tag `{GIT_TAG}`）
**現在の {ENVIRONMENT}-current の tree_sha256**: `{TREE_SHA256}`
**現在の {ENVIRONMENT}-current の commit**: `{CURRENT_MANIFEST_COMMIT}`
**STABLE状態**: {STABLE_STATUS}
**デプロイ期限**: {RELEASE_DEADLINE}
**生成日時**: {GENERATED_AT}
**作成者**: CTO（Claude Code 自動生成）

> **重要**: デプロイの実行は必ず人間（ユーザー）が行う。Claude Code は自動実行しない。
> 対象 unit: `{UNIT}` / health: `{HEALTH_URL}`

---

## Pre-Deploy チェックリスト（実行必須）

### CI/CD
- [ ] GitHub Actions CI 全ジョブ GREEN
- [ ] セキュリティスキャン（gitleaks / npm audit）: Critical/High 0件
- [ ] CodeRabbit / Codex レビュー: 未解決指摘 0件（Critical/High）

### STABLE確認
- [ ] `state.json` の `stable.stable_achieved = true`
- [ ] `state.json` の `stable.consecutive_success >= target_n`
- [ ] 最後の Verify フェーズ実行から 24 時間以内

### バックアップ・ロールバック準備
- [ ] データベースバックアップ取得（該当する場合）
- [ ] 現在のデプロイバージョンを記録（`{RELEASES_DIR}/promotions.jsonl` の最終行）
- [ ] ロールバック手順を確認（本書の「ロールバック手順」セクション参照）

### 事前通知
- [ ] 関係者への事前通知実施（本番デプロイの場合）
- [ ] メンテナンス時間帯の設定（必要な場合）

チェックリストを確認したら、次のコマンドで完了を記録する（`state.deploy.pre_deploy_checklist_done`）。

```bash
bash bin/deploy-prep.sh --env {ENVIRONMENT} --checklist-done
```

---

## デプロイ実行手順

リポジトリルートで実行する。`CLAUDEOS_HOME` の既定は `~/.claudeos`。

### 1. リリース成果物を作る（tracked files の不変スナップショット + manifest）

```bash
COMMIT=$(git rev-parse HEAD)
bash bin/release-build.sh --ref "$COMMIT" --json
# → $CLAUDEOS_HOME/releases/$COMMIT/manifest.json（commit / tree_sha256 / files[]）
```

### 2. staging で同一 artifact を検証する

```bash
bash bin/release-promote.sh --env staging --release "$COMMIT" --json
curl -fsS http://127.0.0.1:3742/api/health | jq -e '.ok == true'
```

### 3. production へ昇格する（staging と同一 tree_sha256 のみ許可）

```bash
bash bin/release-promote.sh --env production --release "$COMMIT" --json
```

`INTEGRITY_MISMATCH` / `STAGING_NOT_VERIFIED` で失敗した場合は昇格していない。
`gitleaks` 等の CI が赤い間は実行しない。

### 4. 配備後検証

```bash
bash scripts/release/post-deploy-smoke.sh --env {ENVIRONMENT} --json
curl -fsS {HEALTH_URL} | jq -e '.ok == true'
```

`post-deploy-smoke.sh` がまだ無い環境では、下の手動確認だけで代替する。

### 実行環境の値

| 項目 | 値 |
|---|---|
| 対象環境 | {ENVIRONMENT} |
| systemd unit | `{UNIT}` |
| health | `{HEALTH_URL}` |
| 期待 port | {PORT} |
| 昇格台帳 | `{RELEASES_DIR}/promotions.jsonl` |
| 現行 symlink | `{RELEASES_DIR}/{ENVIRONMENT}-current` |
| 旧版 symlink | `{RELEASES_DIR}/{ENVIRONMENT}-previous` |

---

## Post-Deploy 検証（Gate-3相当）

### 機能確認
- [ ] 主要機能の動作確認（手動）
- [ ] API エンドポイントの疎通確認
- [ ] 認証・認可の動作確認

### モニタリング確認（デプロイ後 30 分間）
- [ ] エラーレートがベースライン以下
- [ ] レスポンスタイムが閾値以内
- [ ] CPU/メモリ使用率が正常範囲
- [ ] 監視アラートが発火していない

### ログ確認
- [ ] アプリケーションログにエラーなし
- [ ] インフラログに異常なし
- [ ] 昇格台帳の最終行が `PROMOTED`（`tail -n 1 {RELEASES_DIR}/promotions.jsonl`）

---

## デプロイ完了後の必須操作

デプロイ・検証完了後、**メニューの [M] ボタン**（保守モードへ移行）を実行する。

または手動で `state.json` を以下のように更新する（`deploy` 配下のフラグは
`bin/deploy-prep.sh` と本書の生成元スクリプトが実体に基づいて更新する）。

```json
{
  "maintenance": {
    "phase_mode": "maintenance",
    "released_at": "<実行日時 ISO8601>"
  },
  "execution": {
    "phase": "Maintenance"
  }
}
```

---

## ロールバック手順

問題が発生した場合、以下の手順でロールバックを実施する。

```bash
# 1. 直前の target に戻す（previous が無い場合は exit 1）
bash bin/release-promote.sh --env {ENVIRONMENT} --rollback --json

# 2. health を確認する
curl -fsS {HEALTH_URL} | jq -e '.ok == true'

# 3. 台帳で結果を確認する（result=ROLLED_BACK）
tail -n 5 {RELEASES_DIR}/promotions.jsonl

# 4. インシデント起票（メニューの [I] ボタン）
```

production への昇格時は health 失敗で自動ロールバックが走る（`result=ROLLED_BACK`）。
ロールバック後、インシデントとして P1 で記録し Post-mortem を実施する。

---

## 完了記録

| 項目 | 値 |
|---|---|
| デプロイ実行日時 | |
| デプロイ実行者 | |
| デプロイした commit | `{GIT_COMMIT}` |
| デプロイした tree_sha256 | `{TREE_SHA256}` |
| 検証完了日時 | |
| 特記事項 | |
