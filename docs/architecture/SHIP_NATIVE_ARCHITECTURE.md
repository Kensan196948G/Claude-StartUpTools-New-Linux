# ClaudeOS v5.0 — Ship Native Autonomous Development Platform アーキテクチャ

状態: 2026-11-24 実装（Experimental）。正式運用は人間承認・ポリシー施行・GitHub 設定反映の後。

## 1. Claude Ship の公式仕様（2026-11-24 取得・実機確認）

出典: [Introducing Claude Ship](https://claude.com/ja/resources/articles/introducing-claude-ship)、
[Claude Ship 製品ページ](https://claude.com/product/claude-ship)、
[/ship と /steward](https://code.claude.com/docs/en/ship-command.md)、
[トラブルシューティング](https://code.claude.com/docs/en/ship-command-troubleshooting.md)、
[Claude Ship（組織向け）](https://code.claude.com/docs/en/claude-ship.md)

| 項目 | 公式仕様 | 本環境の実測 |
| --- | --- | --- |
| 提供形態 | 個人: `/ship`・`/steward`（Claude Code の**セッション内コマンド**）。組織: Code Review / PR Steward / Claude Approvals（Team / Enterprise のみ） | plan = **Max (max_20x)** → 組織版は**契約対象外** |
| 必要バージョン | Claude Code 2.1.330 以上、gh 2.63 以上、git 2.38 以上 | claude **2.1.330** ✅ / gh **2.45.0** ❌ / git 2.43.0 ✅ |
| 認証 | claude.ai ログイン（first-party）。third-party provider・`DISABLE_TELEMETRY` では出ない | claude.ai / firstParty ✅ |
| headless | **不可**。「`/ship` starts only from a line that you type, not from claude -p or a program」 | `claude -p "/ship terms"` → `Nothing started. ...` を実機確認 |
| cloud session | 不可 | — |
| バックグラウンド | セッションを background へ送ると watch は終了 | — |
| `--help` 表示 | セッション内コマンドのため表示されない | 表示されないことを確認（未対応の根拠にしない） |
| watch の範囲 | 修正 push、base 取り込み、失敗チェック対応・再実行、コメント返信、スレッド解決。merge / approve / auto-merge 有効化 / force-push は Claude Code がブロック | — |
| 停止 | `/ship stop`、Esc/Ctrl+C、ブランチ切替、7 日経過など | — |
| watch を止める設定 | bypassPermissions、`git push` の deny、**checkout の `.claude/settings.json` に Bash の PreToolUse / PermissionRequest hook**、PATH の空・相対・checkout 内エントリ | 本リポジトリは pre-commit-gate (PreToolUse/Bash) により **watch 不可（review のみ可）** |
| 課金 | `/ship` は通常の Claude Code 利用量。組織版は token 課金・usage credits | Max の利用量に計上（実測手段なし → UNKNOWN） |

### 設計上の帰結

- ClaudeOS は `/ship` を**呼び出さない・入力を代行しない**（tmux send-keys による模擬入力もしない）。公式が「人が入力した行からのみ」と定めているため。
- ClaudeOS が担うのは `/ship` の**前後**: ローカル品質（隔離・証跡封印）、AI Quality Gate、Human Gate、Merge Executor、監視、監査。
- `/ship` の結果は、実行した人間が `bin/ship-approve.sh ship-attest` で**署名して**品質判定に渡す（AI の自己申告を入力にしない）。
- 組織版 Claude Approvals は使えないため、**ClaudeOS AI Quality Gate（独自機能）**で品質判定する。公式 Claude Approvals とは称さない。

## 2. TO-BE 構成

```
人 ─(自然言語の開発指示)→ bin/ship-mode.sh SH2 ─→ run 作成 (DISCOVERY) ─→ 対話型 Claude Code (L1/T1 を再利用)
                                                                          │ 実装・テスト・commit・push・PR
                                                                          ▼
                              人がセッションで /ship 入力 ──→ /code-review → watch (修正 push)
                                                                          │
人 ─ bin/ship-approve.sh ship-attest (結果に署名) ─────────────────────────┤
                                                                          ▼
bin/ship.sh quality  ── Local Quality Engine (独立 clone @head, bwrap 隔離, 証跡 HMAC 封印) ─→ Commit Status claudeos/local-quality
bin/ship.sh gate     ── AI Quality Gate (PR 事実 + 品質証跡 + Ship 署名 + リスク R0..R4) ─→ PASS/CONDITIONAL/FAIL/UNKNOWN/BLOCKED
人 ─ bin/ship-approve.sh approve (パスフレーズ署名, head/base 固定) ─→ Commit Status claudeos/human-approval
bin/ship.sh merge    ── Merge Executor (全条件再照合 → nonce 消費 → gh pr merge --auto --squash --match-head-commit) ─→ API 再取得で MERGED 確認
bin/ship.sh monitor  ── head/base 変化で承認失効・auto-merge 解除、承認経路外マージの検出、バックオフ・サーキット
                     監査: ~/.claudeos/ship/audit.jsonl (hash 連鎖) → PostgreSQL 投影 (scripts/ship/project-to-db.js)
                     表示: Web コンソール /ship.html (Ship Control Center。承認ボタンは置かない)
```

## 3. AS-IS との差分

| AS-IS (v10 / v4.0.0-linux) | TO-BE (v5.0 Ship Native) |
| --- | --- |
| 品質ゲート = GitHub Actions `linux-validate` + gitleaks | 加えてローカル隔離品質（同等チェック + 証跡封印）。Actions は段階的に廃止 |
| マージ = Required Checks 成功で自動（承認 0） | 人間の署名承認（SHA 固定）を必須チェックに追加した後に自動マージ |
| `lib/github-pr-flow.sh` は判定のみ | 変更なし（後方互換）。Ship 系は `scripts/ship/` に分離 |
| `bin/cross-repo-automerge.sh` は dependabot/renovate のみ | 変更なし。本リポジトリの除外は承認事項 |
| Goal Router / `/goal` | 変更なし（後方互換） |
| L1 / T1 / S1 | 変更なし。SH1〜SH5 / QC / HG を追加（Experimental 表示） |
| AI レビュー: CodeRabbit / Codex 導入確認ツール、UltraReview | 標準 AI レビューは `/ship`（`/code-review`）。既存ツールは任意として残す（削除しない） |

## 4. 追加ファイル

| ファイル | 責務 |
| --- | --- |
| `config/ship-policy.json` | 品質・リスク・承認・マージ・上限のポリシー正本（R4） |
| `scripts/ship/lib/store.js` | 永続化契約・正規化 JSON・秘密除去・監査連鎖・ロック |
| `scripts/ship/lib/state-machine.js` | 22 状態の遷移と不変条件 |
| `scripts/ship/lib/capability.js` | Ship Capability Detection（公式前提条件の実機判定） |
| `scripts/ship/lib/quality.js` | Local Quality Engine |
| `scripts/ship/lib/risk.js` | R0〜R4 判定 |
| `scripts/ship/lib/quality-gate.js` | AI Quality Gate |
| `scripts/ship/lib/human-gate.js` | 署名承認・検証・取り消し・nonce・Ship 結果署名 |
| `scripts/ship/lib/github-app.js` | 人間専用 GitHub App による承認ステータス登録 |
| `scripts/ship/lib/merge.js` | Merge Executor |
| `scripts/ship/lib/github.js` | gh アダプタ |
| `scripts/ship/ship.js`・`bin/ship.sh` | エンジン CLI |
| `scripts/ship/approve.js`・`bin/ship-approve.sh` | Human Gate CLI（人間専用） |
| `bin/ship-mode.sh` | 起動モード SH1〜SH5 / QC / HG |
| `scripts/web/ship-api.js`・`public/ship.*` | Ship Control Center |
| `db/control/migrations/0006_ship_native.sql` | DB 投影 |
