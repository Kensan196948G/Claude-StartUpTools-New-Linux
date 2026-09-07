---
paths:
  - "Claude/templates/**"
---
# 配布テンプレートの規約

- `Claude/templates/claude/*` は各プロジェクトへ配布される（`lib/template-sync.sh`: START_PROMPT.md は毎回上書き、他は copy-if-missing。`scripts/setup/init-claudeos-project.js`: copy-if-missing + settings deep-merge）。配布範囲を意識して編集する。
- agents / skills は frontmatter 必須（`name`, `description`）。UTF-8 BOM を付けない。`.claude/agents` へは `config/agent-catalog.json` の first-class のみ配布する。
- `START_PROMPT.md` の `/goal` 本文は 4000 文字以内（引用符込み）。CLAUDE.md へ複製しない。
- Neon / managed DB を前提にした記述を新規に追加しない（Local PostgreSQL 正本）。旧記述は Deprecated として履歴保持する。
- テンプレート変更後は `npm test`（template-sync.bats / goal-inject.bats / init-claudeos-project.test.js）を通す。
