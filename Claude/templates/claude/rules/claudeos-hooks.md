---
paths:
  - ".claude/claudeos/scripts/hooks/**"
  - "Claude/templates/claudeos/scripts/hooks/**"
  - ".claude/settings.json"
  - "Claude/templates/claude/settings.json"
---
# Claude Code hooks の規約

- 正本は `Claude/templates/claudeos/scripts/hooks/`。runtime `.claude/claudeos/scripts/hooks/` へ同期し、`node --test scripts/hooks-settings.test.js` で配線整合性を検証する。
- fail-soft: hook 自身の失敗でセッションを止めない。ブロックが必要な場合だけ exit 2（exit 1 は非ブロック）。
- state.json は atomic write（tmp + rename）。同一イベントで複数 hook が同じファイルを書かない。
- settings.json の command は `${CLAUDE_PROJECT_DIR}` 絶対パスを使う（worktree / team モードで相対パスは失敗する）。
- 毎ターン発火する Stop hook は `async: true` にし、gh / ネットワークを伴う処理は間引く（`CLAUDEOS_HEAVY_SYNC_INTERVAL_SEC`）。
- SessionStart の context 注入は `startup|resume|clear` に限定し、`compact` には要旨のみ（post-compact-reinject.js）。
- 存在しない CLI（例: `claude push-notify`）や廃止済みツール（TeamCreate）を前提にしない。追加前に `claude --help` で確認する。
- hooks の役割は Security / Governance / Audit / Quality Gate / Observability / Feedback Capture / Context Reload に限定する。
