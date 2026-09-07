# GitHub開発運用仕様

状態: v1（2026-09-07 制定、ClaudeOS v10）
正本: 中央 `GITHUB_POLICY.md`（Deep-Seek-Harness-Project 配布。本リポジトリのコピーは同一内容）> GitHub Rulesets > GitHub Actions / CI > 本ファイル > `CLAUDE.md` §15〜§17
旧仕様: `CloudflareNeonGitHub自動化仕様.md` §4〜§9 の GitHub 部分を分離したもの。

## 1. 標準フロー

```text
Issue / Intent
  → Branch（feat|fix|docs|chore/<slug>。自動生成は auto/<slug>）または Worktree
  → Implementation（Claude Code Native: subagent / --bg / --worktree）
  → Tests / Evals（npm test, npm run lint, bats, node --test）
  → PR（PR テンプレート必須項目）
  → Independent Review（CodeRabbit / /code-review / 対抗レビュー）
  → Required Checks（CI: linux-validate、Security Scan: secrets-scan）
  → Squash Merge（品質ゲート充足で自動、高リスクは Approval PR）
  → Branch cleanup（delete_branch_on_merge）
```

## 2. 禁止事項

- main / master への直接 push、force push、`--no-verify`
- CI 失敗 PR のマージ、`gh pr merge --admin` 等の保護規則迂回
- Secrets / credential / connection string のコミット
- 自己改善結果（skills / agents / workflow / routing / prompt の自動生成変更）を PR とレビューなしで main へ反映すること

## 3. 品質ゲート付き自動マージ

`CLAUDE.md` §16 に従う。要点:

1. Required Checks 全成功（`CI / linux-validate`、`Security Scan / secrets-scan`）
2. lint / test / build PASS、Critical / High 脆弱性ゼロ、Secrets 露出なし
3. merge conflict なし、head SHA と検証済み commit の一致
4. PR 本文完備（目的、変更、対象外、影響、テスト、セキュリティ、migration、deployment、rollback、preview、残課題、production-safe 判定）
5. 高リスク変更（§17）に非該当

実行は `gh pr merge --auto --squash`。Ruleset の必須チェック名は CI の job 名と完全一致させる（末尾空白・改行の混入に注意）。

## 4. Approval PR（人間 Y/N）

`CLAUDE.md` §17 の対象に加え、v10 で次を明示する。

- Local PostgreSQL の `DROP DATABASE` / `DROP ROLE` / production への `pg_restore --clean` / backup 削除 / retention 短縮
- `.github/workflows/` / Rulesets / branch protection の変更
- Security policy（permissions.deny、hooks の Security / Governance 系）の緩和
- 中央 GitHub Policy および本仕様自体の変更

## 5. CI 構成（本リポジトリ）

| Workflow | Job | 内容 |
|---|---|---|
| `ci.yml` | `linux-validate` | bats + node --test、shellcheck |
| `security-scan.yml` | `secrets-scan` | gitleaks（push / PR / 週次） |

ローカルの事前チェック: `npm test && npm run lint`、`bin/release-check.sh`。

## 6. コミット規約

- Conventional Commits（`feat:` / `fix:` / `docs:` / `chore:` / `test:` / `refactor:`）
- 論理単位で分割し、コード・テスト・文書を同じコミットで整合させる
- Claude Code が作成するコミットには `Co-Authored-By` trailer を付ける（`includeCoAuthoredBy`）。GitHub 上で「未帰属」にならないよう `user.email` は GitHub に紐づくアドレス（noreply 可）を使う

## 7. 中央ポリシーとの関係

中央 `GITHUB_POLICY.md` は GitHub 運用（branch / PR / merge）についてワークスペース記述に優先する。DB 運用（Neon 記述）については本リポジトリの `PostgreSQLデータ運用仕様.md` に従い、差異は CENTRAL_POLICY_CONFLICT として `MIGRATION_V9_TO_V10.md` に記録する。中央ファイルは本リポジトリから編集しない。
