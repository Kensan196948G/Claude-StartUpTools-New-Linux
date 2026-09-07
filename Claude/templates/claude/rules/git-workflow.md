# Git ワークフロー（常時ロード）

- `main` / `master` へ直接 commit / push しない。作業 branch は `feat|fix|docs|chore/<slug>`（自動生成は `auto/<slug>`）。
- commit は論理単位で分割し、Conventional Commits（`feat:` `fix:` `docs:` `chore:` `test:` `refactor:`）で目的が分かるようにする。
- force push、履歴改変、`--no-verify`、`gh pr merge --admin` 等の保護規則迂回を行わない。
- 既存の未コミット変更・未追跡ファイルはユーザーの作業として保護し、無断で stash / reset / checkout / 削除しない。
- PR 本文は 目的 / 変更 / 対象外 / 影響 / テスト・CI / セキュリティ / migration / deployment / rollback / preview / 残課題 / production-safe を含める。
- head SHA が変わったら影響する検証を再実行する。
