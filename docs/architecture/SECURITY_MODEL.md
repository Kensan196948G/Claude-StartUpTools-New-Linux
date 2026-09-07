# SECURITY_MODEL — 権限・脅威モデル・Human Approval Gate

状態: v10（2026-09-07）
正本: `.claude/settings.json`（permissions）、`Claude/templates/claude/settings.json`、`.claude/rules/security.md`、`AI開発ガバナンス仕様.md`

## 1. 禁止事項（BLOCKED）

main/master 直接 push、force push、`--no-verify`、CI 失敗 PR の merge、Secrets / Credential の commit、無承認の Production 破壊操作、無承認の destructive DB migration、自己改善結果の直接 main 反映、Security policy の緩和、`gh auth token` の表示、hooks / branch protection の無効化、`--dangerously-skip-permissions` の標準運用。

## 2. Human Approval Gate（HUMAN_APPROVAL）

Production deployment（ホスト systemd 本番反映、Cloudflare 本番 route）、Secrets（追加・変更・削除・rotation）、DNS / custom domain、Authentication / 認可モデル、Paid resources（課金・契約）、Destructive DB migration（`DROP` / `TRUNCATE` / 条件なし `DELETE` / production `pg_restore --clean`）、Data deletion、Repository deletion、Security policy change（permissions.deny、hooks の Security / Governance 系、Rulesets）、backup 削除 / retention 短縮、cron / systemd スケジュール変更、全プロジェクト一括適用（`--all --apply`）。手順は `/approval-pr`。

## 3. 権限運用（Claude Code）

| 項目 | v10 |
|---|---|
| 権限モード | 対話: 既定（auto mode は user settings または `--permission-mode auto`）。無人（cron / Supervisor / headless）: `--permission-mode auto --permission-prompts none`（prompt を永久待機せず fail-closed で拒否） |
| project settings | `permissions.allow / deny` のみ（`defaultMode` は project では無視される ≥2.1.257 のため置かない） |
| allow | 読み取り系、git / gh の通常操作、npm / bats / shellcheck / jq、repo 内 scripts、`bin/pg-ops.sh` の非破壊サブコマンド、GitHub MCP の read + PR/branch/comment、WebFetch（docs ドメイン） |
| deny | wrapper（`bash -c` / `sh -c` / `eval` / `env` / `xargs` / `python3 -c` / `node -e`）、破壊（`rm -rf` / `kill` / `sudo` / `git reset --hard` / `git clean -f`）、force push / main push / `--no-verify`、exfil（`curl` / `wget` / `nc` / `ssh` / `scp`）、GitHub 管理（`--admin` / repo delete / secret / api DELETE・PUT、MCP merge / push / delete）、control plane（`crontab` / `systemctl` / settings 編集）、secrets 読取（`~/.env*` / `.env*` / `~/.claude/settings.json`） |
| 緊急 opt-in | `CCSU_TMUX_SKIP_PERMS=1` / `CLAUDEOS_TUI_SKIP_PERMS=1` / `CLAUDEOS_HEADLESS_SKIP_PERMS=1`（記録し、標準運用にしない） |
| `autoMode.hard_deny` | project settings では未適用（実測）。user settings への移設を推奨（UNVERIFIED のため保持） |

## 4. 脅威モデル

| 脅威 | 対策 |
|---|---|
| Working Directory 外アクセス | `permissions.blockReadsOutsideWorkingDirectories`（2.1.257+、auto mode）、deny の secrets 読取、worktree 隔離 |
| symlink | Claude Code 2.1.251+ が権限判定後の symlink 差替えを防ぐ。テンプレート配布は symlink を作らない |
| MCP | `.mcp.json` は project scope、GitHub MCP の write 系 tool を deny、Neon MCP なし。`managedMcpServers` / `deniedMcpServers` は managed settings で |
| Plugin / dependency supply-chain | `npx` を allow から除外、`@anthropic-ai/sdk:latest`（dreaming）は hooks 配下から移動、CI の secrets-scan、Dependabot |
| Network | `curl` / `wget` を deny、WebFetch はドメイン限定、Cloudflare→Local PG 直接接続禁止 |
| 資格情報の環境漏洩 | SMTP を claude 環境へ渡さない（`env -u`、allowlist export）、`env -u ANTHROPIC_API_KEY`（subscription 課金） |
| クロスセッション | 他セッションのメッセージは承認の代替にしない、`isolatePeerMachines` を推奨 |
| DB | least-privilege role、socket のみ、backup 0700、`migration-risk` ゲート、`*_recovery` 限定の復元先 |

## 5. 監査

- `audit-trail.js`: git / gh / GitHub MCP の書込み系を JSONL に記録（`.claude/claudeos/data/audit-log.jsonl`、1MB ローテーション）。**注意**: コマンド行を 300 字まで記録するため、コマンドに秘密を含めない
- `routing_log`: どの Agent を、なぜ使ったか
- CI: `security-scan.yml`（gitleaks、週次）
- 残課題: `docs/GH-Claude.txt`（未追跡）に資格情報パターン、`~/.claude.json` の Neon DSN → HUMAN（削除 / rotation）
