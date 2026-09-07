# Source of Truth Map — Claude StartUpTools New Linux

このリポジトリは Linux ローカル専用の Claude 起動・Supervisor 運用ツールです。
編集対象に迷った場合は、この分類を優先します。

## 分類

| 分類 | 意味 | 編集可否 |
|---|---|---|
| Source | 人間とCTO Claudeが編集する正本 | 編集可 |
| Deployed | Source から同期・展開される実行先コピー | 直接編集しない |
| Generated | 実行時に生成されるログ/状態/レポート | 直接編集しない |

## 正本

| パス | 分類 | 備考 |
|---|---|---|
| `README.md` | Source | Linux版の入口説明 |
| `bin/` | Source | 起動、監視、Supervisor、cron、運用メニュー |
| `lib/` | Source | 共通関数、設定、JSON、tmux、Supervisor補助 |
| `libexec/` | Source | 診断・補助実行スクリプト |
| `Claude/templates/claude/` | Source | 各プロジェクトへ適用する Claude 指示テンプレート |
| `Claude/templates/claudeos/` | Source | ClaudeOS カーネルテンプレート |
| `Claude/templates/linux/` | Source | Linux cron/systemd 用テンプレート |
| `config/config.json.template` | Source | 実機設定テンプレート |
| `config/README.md` | Source | 設定運用ガイド |
| `tests/bats/` | Source | bash 実装の検証 |
| `.github/workflows/ci.yml` | Source | Ubuntu CI |
| `config/claude-code-compat.json` | Source | Claude Code 互換性ポリシー（minimum / recommended / tested、Capability probe） |
| `config/agent-catalog.json` | Source | Lazy Agent Catalog（first-class / catalog / merge / remove-candidate） |
| `Claude/templates/claudeos/policy/` | Source | CLAUDE.md の詳細方針（逐語移設）。CLAUDE.md は要約 |
| `Claude/templates/claude/rules/` | Source | path-scoped rules（配布） |
| `Claude/templates/claude/skills/` | Source | frontmatter 付き実 skill（配布） |
| `Claude/templates/claudeos/sdlc/` | Source | AI-Native SDLC 成果物テンプレート |
| `tests/evals/` | Source | golden eval（Self-Improvement の回帰ゲート） |
| `lib/goal-router.sh`, `Claude/templates/claudeos/goals/*.md` | Source | 統合 Goal Router（判定ロジック唯一の実装）と Primary 5 / Specialized 6 の /goal 本文 |
| `Claude/templates/claude/claudeos/core/00-goal-system.md` | Source | Goal System 文書（`instructions/00-goal-system.md` は同一コピー） |
| `docs/architecture/*.md` | Source | v10 仕様・設計・移行記録 |

## 配備先・生成物

| パス | 分類 | 備考 |
|---|---|---|
| `.claude/claudeos/` | Deployed | `Claude/templates/claudeos/` から同期（hooks / policy / agents / sdlc / system） |
| `.claude/agents/`, `.claude/rules/`, `.claude/skills/` | Deployed | templates から配布（first-class agents / rules / 実 skill） |
| `CLAUDE.md`, `Claude/CLAUDE.md`, `Claude/templates/claudeos/examples/CLAUDE.md` | Deployed | `Claude/templates/claude/CLAUDE.md` の同一コピー |
| `config/config.json` | Deployed | 実機ローカル設定。コミットしない |
| `~/.claudeos/` | Deployed/Generated | Supervisor 状態、cron launcher、ログ |
| `logs/` | Generated | 実行ログ |
| `reports/` | Generated | レポート出力 |
| `.worktrees/` | Generated | 一時 worktree |

## 編集フロー

```text
bin/lib/libexec を変更
  -> bats テストを更新
  -> npm test
  -> npm run lint

Claude テンプレートを変更
  -> Claude/templates/claude または Claude/templates/claudeos を編集
  -> 適用先との差分を確認

設定を変更
  -> config/config.json.template を編集
  -> 実機では config/config.json へコピーして調整
```

## 運用境界

- SSH 接続、リモート配布、Windows Terminal、PowerShell/Pester は本Linux版の対象外です。
- Supervisor の全プロジェクト適用は、実行直前に人間の最終選択を必要とします。
- CTO Claude は実装、検証、レビュー、PR 準備、品質ゲート充足 PR の自動マージ（`gh pr merge --auto --squash`）まで自律実行できます。高リスク変更（DNS / Secrets / 認証 / 破壊的 DB 操作 / 課金 / 公開範囲 / security policy / 自己改善結果）は Approval PR で人間が最終判断します（`docs/architecture/AI開発ガバナンス仕様.md`）。
