---
paths:
  - "bin/**"
  - "lib/**"
  - "libexec/**"
  - "Claude/templates/linux/**"
---
# ClaudeOS 起動系スクリプトの規約

- bash は `set -euo pipefail` を実行エントリ（bin/*.sh）の冒頭でのみ宣言し、lib/*.sh（source される側）では宣言しない。
- `lib/common.sh` を最初に source し、`log_info / log_ok / log_warn / log_error`、`has_cmd / require_cmd` を使う。二重 source 防止ガードを入れる。
- 変更したら対応する `tests/bats/unit/<name>.bats` を同じコミットで更新し、`npm test && npm run lint`（shellcheck -S error）を通す。
- SSH / Windows / PowerShell 起動経路を復活させない。
- claude の起動フラグはバージョン固定ではなく Capability Detection（`lib/claude-capability.sh`、`claude --help` probe）で分岐する。
- 無人実行（cron / Supervisor / headless）は `--permission-mode auto --permission-prompts none`。`--dangerously-skip-permissions` は明示 opt-in の緊急用のみ。
- 秘密（SMTP / API key）を claude プロセス環境へ渡さない（`env -u`、allowlist export）。
- 全プロジェクト適用（`--all`）は必ず `--dry-run` で対象を確認してから行う。
